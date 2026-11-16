import json
import pathlib
import re

DEPLOY = pathlib.Path(__file__).resolve().parents[1] / "deploy"


def read(name: str) -> str:
    return (DEPLOY / name).read_text()


def test_systemd_unit_binds_loopback_only_and_is_hardened():
    unit = read("noop-receiver.service")
    assert "--listen 127.0.0.1:8787" in unit
    assert "0.0.0.0" not in unit
    for must in ("NoNewPrivileges=true", "ProtectSystem=strict", "Restart=always", "ReadWritePaths="):
        assert must in unit
    assert "User=noop" in unit and "--token-file /etc/noop-selfhost/token" in unit


def test_mcp_example_is_valid_json_with_read_only_command():
    cfg = json.loads(read("noop-mcp.example.json"))
    srv = cfg["mcpServers"]["noop"]
    assert srv["command"].endswith("noop-mcp") and "--db" in srv["args"]


def test_readme_documents_tailnet_only_serve_and_never_funnel():
    text = read("README.md")
    assert "tailscale serve --bg --https=443 http://127.0.0.1:8787" in text
    assert "https://server.tailfb9ed9.ts.net/push" in text
    assert not re.search(r"tailscale funnel (?!.*never)", text.replace("never Funnel", "")), "funnel must not be advised"
    assert "chmod 600" in text and "openssl rand -hex 32" in text


def test_backup_script_uses_sqlite_backup_not_cp():
    s = read("noop-backup.sh")
    assert ".backup" in s and "cp " not in s


def test_backup_instructions_let_the_noop_user_run_the_script_and_write_the_directory():
    text = read("README.md")
    assert "install -m 755 deploy/noop-backup.sh" in text
    assert "install -d -o noop -g noop -m 750 /var/backups/noop-selfhost" in text
