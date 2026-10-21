---
name: portbar
description: Manage local PortBar SSH hosts, local port forwards and SOCKS5 tunnels through its CLI; inspect connection state and diagnose tunnel failures. Use when the user wants to operate PortBar on their Mac.
---

# PortBar

Use the `portbar` CLI to operate the running menu bar application. It owns the configuration and SSH processes; do not edit its config JSON or create parallel SSH processes to perform a PortBar task.

## Discover

Run `portbar --version`, `portbar capabilities --json` and, when needed, `portbar --help` or `portbar schema --json`. If `portbar` is not on PATH, check `/Applications/PortBar.app/Contents/Helpers/portbar`; for another installation, use the command copied from PortBar Settings.

`APP_NOT_RUNNING` means the application must be opened by the user or under the user's authorization. Opening it may start mappings with autoStart enabled. `PERMISSION_DENIED` requires changing CLI access in the application's Settings. Do not change its preferences or permissions through another mechanism.

## Operate

- Request `--json`; check both the exit status and `ok`. Read `error.code` on failure.
- Find hosts or mappings using `hosts list --search TEXT --json` or `mappings list --search TEXT --json`. Lists default to 100 items and support `--limit 1..500`. Act on UUIDs; clarify ambiguous matches rather than selecting arbitrarily.
- Start or stop using `tunnels start|stop --mapping-id UUID --wait --timeout 15 --json`. Report the resulting state. `connected` means local listener readiness; it does not prove that the remote database, website or other service is healthy.
- Use `tunnels diagnose --mapping-id UUID --json` and `logs list --mapping-id UUID --limit 30 --json` for failures. Do not loop on authentication failures or host key changes. Do not bypass SSH host key verification. A port conflict does not authorize killing another process.
- `TIMEOUT` does not cancel an operation. Query `tunnels status --mapping-id UUID --json` before retrying. `OPERATION_SUPERSEDED` means another action changed the tunnel; re-read state before taking further action.

## Edit configuration

Use a JSON file or stdin with `--file -`. `portbar schema --json` lists accepted fields. Updates patch supplied fields; nulls and unknown fields are rejected. Passwords cannot be supplied or read through the CLI; credentials remain managed in the application.

Preview a create, update or delete with `--dry-run --json`. Review `before`, `after` and `affectedMappingIds`. For a subsequent commit, pass the returned top-level `revision` as `--if-revision VALUE` and use the same inputs. A preview of creation has a provisional UUID; use the committed response's UUID for subsequent actions.

Running tunnels and pending reconnects must be stopped before editing or deleting their configuration. Stopping a tunnel disables its pending reconnect. Saving a mapping does not start it immediately; autoStart takes effect at the next application launch. A host delete with associated mappings requires explicit `--cascade`; ensure that deletion of those mappings is within the user's request.

Example database mapping input:

```json
{
  "name": "dev-db",
  "hostId": "HOST_UUID",
  "forwardType": "local_port",
  "portRules": [
    { "localPort": 13306, "remoteHost": "127.0.0.1", "remotePort": 3306 }
  ]
}
```

After a successful connection, return the actual local address and port. Never infer an application protocol solely from the port number or claim remote service health based on tunnel state.
