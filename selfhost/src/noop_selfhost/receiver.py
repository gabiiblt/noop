"""HTTP receiver for the NOOP self-hosted push protocol. Binds loopback only (see `parse_listen`);
expose it to the tailnet with `tailscale serve`, never Funnel."""
from __future__ import annotations

import argparse
import hmac
import json
import ipaddress
import os
import re
import sqlite3
import stat
import sys

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from .batch import MAX_WIRE, ProtocolError, parse_batch
from .db import Store
from .registry import REGISTRY, V1, VERSIONS, streams_for


# APNs device tokens are hex (32 bytes today; Apple documents them as variable length). The topic is the
# app's bundle id. Both are validated so the MCP server only ever sends what a phone really registered.
DEVICE_TOKEN_RE = re.compile(r"^[0-9a-f]{64,200}$")
TOPIC_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$")
APNS_ENVIRONMENTS = ("development", "production")
MAX_WAKE_BODY = 2048


def create_app(store: Store, token: str, enabled_streams: set[str] | None = None) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    allowed = set(enabled_streams) if enabled_streams is not None else set(REGISTRY)
    expected = token.encode()

    def err(status: int, code: str, version: str = V1, headers: dict | None = None) -> JSONResponse:
        return JSONResponse({"type": "error", "protocolVersion": version, "code": code},
                            status_code=status, headers=headers)

    def authorized(request: Request) -> bool:
        auth = request.headers.get("authorization", "")
        scheme, _, given = auth.partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(given.strip().encode(), expected)

    unauthorized = lambda: err(401, "unauthorized", headers={"WWW-Authenticate": "Bearer"})  # noqa: E731

    @app.get("/push")
    def capabilities(request: Request):
        if not authorized(request):
            return unauthorized()
        offered = [v.strip() for v in request.headers.get("noop-push-accept-version", "").split(",") if v.strip()]
        chosen = next((v for v in offered if v in VERSIONS), None)
        if chosen is None:
            return err(406, "no_common_version")
        names = [s.name for s in streams_for(chosen) if s.name in allowed]
        return {"type": "capabilities", "protocolVersion": chosen,
                "receiverStateId": store.receiver_state_id(), "streams": names}

    @app.post("/push")
    async def push(request: Request):
        if not authorized(request):
            return unauthorized()
        try:
            declared = int(request.headers.get("content-length", "0"))
        except ValueError:
            declared = 0
        if declared > MAX_WIRE:
            return err(413, "payload_too_large")
        body = await request.body()
        version = V1
        try:
            batch = parse_batch(body, request.headers.get("content-encoding"), None, allowed)
            version = batch.header["protocolVersion"]
            accept = store.accept_append if batch.stream.delivery == "append" else store.accept_window_part
            ack = await run_in_threadpool(accept, batch)
            return JSONResponse(ack)
        except ProtocolError as e:
            return err(e.status, e.code, version)
        except sqlite3.OperationalError:
            return err(503, "receiver_busy", version)

    @app.post("/push/wake-token")
    async def wake_token(request: Request):
        """The phone's APNs registration, so `request_phone_sync` can wake it. Health data never travels here."""
        if not authorized(request):
            return unauthorized()
        body = await request.body()
        if len(body) > MAX_WAKE_BODY:
            return err(413, "payload_too_large")
        try:
            doc = json.loads(body)
        except ValueError:
            return err(400, "invalid_json")
        if not isinstance(doc, dict):
            return err(400, "invalid_json")
        token, env, topic = doc.get("deviceToken"), doc.get("environment"), doc.get("topic")
        if not (isinstance(token, str) and DEVICE_TOKEN_RE.match(token)):
            return err(422, "invalid_device_token")
        if env not in APNS_ENVIRONMENTS:
            return err(422, "invalid_environment")
        if not (isinstance(topic, str) and TOPIC_RE.match(topic)):
            return err(422, "invalid_topic")
        try:
            await run_in_threadpool(store.set_wake_device, token, env, topic)
        except sqlite3.OperationalError:
            return err(503, "receiver_busy")
        return {"type": "wakeToken", "status": "stored"}

    return app


def parse_listen(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep or not host:
        raise ValueError("listen address must be host:port")
    host = host.strip("[]")
    if host == "localhost":
        host = "127.0.0.1"
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = False
    if not loopback:
        raise ValueError("receiver only binds loopback; publish it with `tailscale serve`")
    return host, int(port)


def load_token(path: str) -> str:
    if os.stat(path).st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise PermissionError(f"{path} must not be accessible by group/others (chmod 600)")
    token = open(path, encoding="utf-8").read().strip()
    if not token:
        raise ValueError(f"{path} is empty")
    return token


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="noop-receiver")
    ap.add_argument("--db", required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--listen", default="127.0.0.1:8787")
    ap.add_argument("--decline", action="append", default=[], metavar="STREAM",
                    help="stream the receiver does not want (repeatable)")
    a = ap.parse_args(argv)
    try:
        host, port = parse_listen(a.listen)
        token = load_token(a.token_file)
    except (ValueError, PermissionError, OSError) as e:
        sys.exit(f"noop-receiver: {e}")
    unknown = set(a.decline) - set(REGISTRY)
    if unknown:
        sys.exit(f"noop-receiver: unknown stream(s): {', '.join(sorted(unknown))}")
    import uvicorn
    app = create_app(Store(a.db), token, set(REGISTRY) - set(a.decline))
    uvicorn.run(app, host=host, port=port, access_log=False, server_header=False)


if __name__ == "__main__":
    main()
