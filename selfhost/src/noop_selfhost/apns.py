"""Silent ("background") Apple push notifications that wake the phone so it uploads now.

The payload carries no data: `content-available` lets iOS run the app for ~30 s, and the app answers by
uploading through the normal push protocol. iOS rate-limits these and never wakes an app the user
force-quit, so a wake is a request, not a guarantee. Token-based auth (an APNs `.p8` key) over HTTP/2.
"""
from __future__ import annotations

import os
import stat
import threading
import time
from dataclasses import dataclass

import httpx
import jwt

HOSTS = {"production": "https://api.push.apple.com", "development": "https://api.sandbox.push.apple.com"}
JWT_LIFETIME_S = 50 * 60  # Apple refuses tokens older than an hour and throttles refreshing more than every 20 min
PAYLOAD = {"aps": {"content-available": 1}, "noop": "sync"}


class ApnsError(Exception):
    """Apple refused the notification; `reason` is Apple's machine code (e.g. BadDeviceToken)."""

    def __init__(self, status: int, reason: str) -> None:
        super().__init__(f"APNs refused the wake (HTTP {status}: {reason})")
        self.status = status
        self.reason = reason


@dataclass(frozen=True)
class ApnsConfig:
    key_pem: str
    key_id: str
    team_id: str

    @staticmethod
    def load(key_path: str, key_id: str, team_id: str) -> "ApnsConfig":
        if os.stat(key_path).st_mode & (stat.S_IRWXO):
            raise PermissionError(f"{key_path} must not be readable by others (chmod 640 or 600)")
        pem = open(key_path, encoding="utf-8").read()
        if "PRIVATE KEY" not in pem:
            raise ValueError(f"{key_path} is not a .p8 private key")
        for name, value in (("key id", key_id), ("team id", team_id)):
            if not (len(value) == 10 and value.isalnum() and value.upper() == value):
                raise ValueError(f"APNs {name} must be the 10-character id from the developer portal, got {value!r}")
        return ApnsConfig(pem, key_id, team_id)


class ApnsClient:
    def __init__(self, config: ApnsConfig, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.config = config
        self._transport = transport
        self._jwt: tuple[str, float] | None = None
        self._lock = threading.Lock()

    def bearer(self, now: float | None = None) -> str:
        t = time.time() if now is None else now
        with self._lock:
            if self._jwt is None or t - self._jwt[1] >= JWT_LIFETIME_S:
                token = jwt.encode({"iss": self.config.team_id, "iat": int(t)}, self.config.key_pem,
                                   algorithm="ES256", headers={"kid": self.config.key_id})
                self._jwt = (token, t)
            return self._jwt[0]

    async def _post(self, environment: str, device_token: str, topic: str) -> httpx.Response:
        kw = {"transport": self._transport} if self._transport is not None else {"http2": True}
        async with httpx.AsyncClient(timeout=15, **kw) as client:
            return await client.post(
                f"{HOSTS[environment]}/3/device/{device_token}", json=PAYLOAD,
                headers={"authorization": f"bearer {self.bearer()}", "apns-push-type": "background",
                         "apns-priority": "5", "apns-topic": topic, "apns-expiration": "0"})

    async def wake(self, device_token: str, topic: str, environment: str) -> str:
        """Send one silent wake. Returns the environment that accepted it.

        A development (Xcode) build only has a sandbox token and a distributed build only a production one,
        so a `BadDeviceToken` from the registered environment is retried once against the other."""
        order = [environment] + [e for e in HOSTS if e != environment]
        last: ApnsError | None = None
        for env in order:
            r = await self._post(env, device_token, topic)
            if r.status_code == 200:
                return env
            try:
                reason = str(r.json().get("reason", "unknown"))
            except ValueError:
                reason = "unknown"
            last = ApnsError(r.status_code, reason)
            if reason != "BadDeviceToken":
                break
        assert last is not None
        raise last
