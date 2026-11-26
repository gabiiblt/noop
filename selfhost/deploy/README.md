# Deploying the receiver and the MCP server (Ubuntu + Tailscale)

Personal setup. Health data never leaves your tailnet: the receiver listens on **loopback only**
and `tailscale serve` publishes it, with a real HTTPS certificate, to your tailnet and nowhere else.
Never use Tailscale Funnel for this (it publishes to the public internet).

## 1. Prerequisites (once)

In the Tailscale admin console enable **MagicDNS** and **HTTPS Certificates**. The server's name is
`server.tailfb9ed9.ts.net`. The iPhone must be signed in to the same tailnet (Tailscale app on, ideally
with "VPN On Demand" so background uploads can reach the server).

## 2. Install

```bash
sudo useradd --system --home /var/lib/noop-selfhost --shell /usr/sbin/nologin noop
sudo python3 -m venv /opt/noop-selfhost/venv
sudo /opt/noop-selfhost/venv/bin/pip install /path/to/noop/selfhost
sudo apt-get install -y sqlite3
```

## 3. Token (shared secret between the phone and the receiver)

```bash
sudo mkdir -p /etc/noop-selfhost
openssl rand -hex 32 | sudo tee /etc/noop-selfhost/token >/dev/null
sudo chown noop:noop /etc/noop-selfhost/token && sudo chmod 600 /etc/noop-selfhost/token
sudo cat /etc/noop-selfhost/token   # paste this into NOOP's settings; do not store it anywhere else
```

The receiver refuses to start if the token file is readable by group/others, and refuses any listen
address that is not loopback.

## 4. Run the receiver

```bash
sudo cp deploy/noop-receiver.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now noop-receiver
sudo systemctl status noop-receiver --no-pager
```

## 5. Publish to the tailnet (HTTPS, tailnet-only)

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:8787
tailscale serve status
```

The endpoint to enter in NOOP is **`https://server.tailfb9ed9.ts.net/push`**. Check it from any device on the
tailnet (expect a `capabilities` JSON; without the header you get 401):

```bash
curl -s -H "Authorization: Bearer $(sudo cat /etc/noop-selfhost/token)" \
     -H "NOOP-Push-Accept-Version: 1.100,1.0" https://server.tailfb9ed9.ts.net/push
```

## 6. Try it before the iPhone is ready (optional)

Copy `whoop.sqlite` from a backup/Mac to the server, then replay it through the real wire format:

```bash
sudo -u noop /opt/noop-selfhost/venv/bin/noop-push-simulator --db /tmp/whoop-copy.sqlite \
  --endpoint https://server.tailfb9ed9.ts.net/push --token-file /etc/noop-selfhost/token
```

## 7. MCP server for your agents

Same machine as the database. The agent's user needs read access to the database file
(`sudo usermod -aG noop <agent-user>`; the directory is `0750 noop:noop`). Register
`deploy/noop-mcp.example.json` in your agent's MCP configuration (stdio transport). The server is
read-only, offers thirteen tools and no free-form SQL. For an agent running elsewhere you may instead run
`noop-mcp --db ... --http 127.0.0.1:8788` and publish it the same way with `tailscale serve`;
that is not enabled by default.
The HTTP server only accepts requests addressed to `127.0.0.1`/`localhost` (a DNS-rebinding guard), so
add each address a client really uses with `--allow-host`, for example
`--allow-host server.<tailnet>.ts.net:8443` behind `tailscale serve`, or `--allow-host 172.21.0.1:8789`
behind a relay on a Docker bridge (a containerised agent cannot reach `tailscale serve`). Without it the
client gets `421 Invalid Host header`.

## 8. Let agents wake the phone (optional, paid Apple developer account)

`request_phone_sync` sends the iPhone a silent notification so it uploads now, then waits for the upload.
It needs an APNs key and an app built with the Push Notifications capability (`aps-environment` in
`project.yml`). Without it everything else works and `get_sync_status` still reports how fresh the data is.

1. developer.apple.com, Certificates, Identifiers & Profiles, **Keys**, **+**: tick **Apple Push
   Notifications service (APNs)**, download `AuthKey_<KEYID>.p8` (downloadable once) and note the
   **Key ID**. Your **Team ID** is under Membership details.
2. Copy the key to the server, readable by the `noop` user only:

   ```bash
   sudo install -o root -g noop -m 640 AuthKey_KEYID.p8 /etc/noop-selfhost/apns.p8
   ```

3. Add the three flags to the `noop-mcp` command (systemd unit or MCP config) and restart it:

   ```
   --apns-key /etc/noop-selfhost/apns.p8 --apns-key-id KEYID --apns-team-id TEAMID
   ```

4. Rebuild and run the app from Xcode, then open NOOP once with Self-hosted Export on: the phone registers
   its device token with the receiver (`POST /push/wake-token`). `get_sync_status` then reports
   `phone_wake.available: true`.

The server must reach `api.push.apple.com` / `api.sandbox.push.apple.com` (outbound HTTPS). iOS
rate-limits silent notifications and never wakes an app the user force-quit, so a wake can go
unanswered; the tool then says so instead of waiting forever.

## 9. Backups

```bash
sudo install -m 755 deploy/noop-backup.sh /usr/local/bin/noop-backup
sudo install -d -o noop -g noop -m 750 /var/backups/noop-selfhost
echo '17 3 * * * noop /usr/local/bin/noop-backup' | sudo tee /etc/cron.d/noop-backup
```

## Operations notes

- If you restore the database from a backup older than what the phone already uploaded, rotate the
  receiver's state id so the phone re-sends everything: stop the service and run
  `sudo -u noop /opt/noop-selfhost/venv/bin/python -c "from noop_selfhost.db import Store; print(Store('/var/lib/noop-selfhost/selfhost.sqlite').rotate_receiver_state_id())"`.
- Logs: `journalctl -u noop-receiver`. The receiver never logs request bodies.
