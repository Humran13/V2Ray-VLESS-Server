# V2Ray VLESS Server Manager

A production-ready installer and management CLI for running a [VLESS](https://xtls.github.io/) server on top of the official [XTLS/Xray-core](https://github.com/XTLS/Xray-core), built for Ubuntu VPS deployments.

## Features

- One-command interactive installer with 11 VLESS connection profile templates (REALITY, TLS, and an advanced no-security mode)
- Official Xray-core releases only, checksum-verified before install
- `vless` management CLI/TUI: users, profiles, status, diagnostics, backup/restore, updates, repair, uninstall
- Atomic configuration changes - every change is validated with `xray -test` before being applied, with automatic rollback on failure
- Multiple simultaneous connection profiles (e.g. REALITY on 443, WebSocket+TLS on 8443) on one server
- UFW-aware firewall management (only touches ports/rules this project created)
- ACME (Let's Encrypt via acme.sh) certificate issuance, renewal and reload
- VLESS share-link (URI), QR code, and client JSON generation

## Supported platforms

| | |
|---|---|
| **Ubuntu** | 18.04, 20.04, 22.04, 24.04, 26.04 LTS (explicitly tested); newer releases >= 18.04 are auto-detected and run with a "not explicitly tested" notice rather than being blocked |
| **Architectures** | amd64/x86_64, arm64/aarch64 |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/V2Ray-VLESS-Server/main/install.sh | sudo bash
```

Then manage your server anytime with:

```bash
sudo vless
```

## Connection modes

| # | Profile | Transport | Security | Flow | Notes |
|---|---------|-----------|----------|------|-------|
| 1 | REALITY + RAW + Vision | raw | reality | xtls-rprx-vision | **Recommended default** |
| 2 | REALITY + XHTTP | xhttp | reality | - | |
| 3 | REALITY + gRPC | grpc | reality | - | |
| 4 | TLS + XHTTP | xhttp | tls | - | Requires a domain |
| 5 | TLS + WebSocket | websocket | tls | - | Requires a domain |
| 6 | TLS + HTTPUpgrade | httpupgrade | tls | - | Requires a domain |
| 7 | TLS + gRPC | grpc | tls | - | Requires a domain |
| 8 | TLS + RAW + Vision | raw | tls | xtls-rprx-vision | Requires a domain |
| 9 | TLS + mKCP | mkcp | tls | - | Requires a domain |
| 10 | TLS + Hysteria transport | hysteria | tls | - | Requires a domain. Xray's own Hysteria2-protocol transport, not a standalone Hysteria2 server - needs a client that supports Xray's `hysteria` streamSettings, not the generic Hysteria2 apps |
| 11 | none + XHTTP | xhttp | none | - | **ADVANCED / NOT RECOMMENDED FOR PUBLIC INTERNET** - unencrypted transport, for LAN/reverse-proxy use only |

Compatibility matrix enforced by the installer/manager (invalid combinations, e.g. REALITY + WebSocket, are never offered):

|              | REALITY | TLS | none |
|--------------|:-------:|:---:|:----:|
| RAW          | ✅ (Vision) | ✅ (Vision) | ✅ (advanced) |
| XHTTP        | ✅ | ✅ | ✅ (advanced) |
| gRPC         | ✅ | ✅ | ✅ (advanced) |
| WebSocket    | ❌ | ✅ | ✅ (advanced) |
| HTTPUpgrade  | ❌ | ✅ | ✅ (advanced) |
| mKCP         | ❌ | ✅ | ✅ (advanced) |
| Hysteria     | ❌ | ✅ required | ❌ |

XTLS Vision flow only applies to RAW transport with TLS or REALITY security.

## Managing users

```bash
sudo vless user add <profile-id> <name>   # add a user, prints their VLESS URI
sudo vless user list                      # list all users
sudo vless user show <name>               # show connection info + QR code
sudo vless user delete <name>
sudo vless user enable|disable <name>
```

Every VLESS URI and QR code is generated on demand from the server's live state - nothing sensitive is pre-rendered to disk.

## Firewall

If UFW is active, the installer/manager opens only the ports used by enabled profiles (TCP for RAW/XHTTP/WebSocket/HTTPUpgrade/gRPC, UDP for mKCP/Hysteria), tagged with a `v2ray-vless-server` comment. If UFW is inactive, it is left untouched. Uninstalling removes only the rules this project created.

## Domain requirement for TLS

TLS profiles require a domain name that already resolves to your server (an A/AAAA record). If you don't have one, choose a REALITY profile instead - REALITY does not require a domain or a certificate.

## REALITY

REALITY lets the server present a real, uncontrolled TLS destination's certificate (e.g. `www.microsoft.com`) to anyone without the correct key, while legitimate clients holding the private key's paired public key/shortId connect normally. The installer generates a fresh X25519 keypair and short ID per REALITY profile; the private key is stored root-only (`0600`) under `/etc/v2ray-vless-server/reality/` and is never printed, logged, or included in backups' plaintext client output.

## Updating

```bash
sudo vless update xray      # update Xray-core to the latest stable release
sudo vless update manager   # update this manager from GitHub
```

Both preserve your existing users/profiles and roll back automatically if the update produces a broken/unhealthy service.

## Backup / restore

```bash
sudo vless backup
sudo vless restore /var/lib/v2ray-vless-server/backups/vless-backup-<timestamp>.tar.gz
```

Restores validate the archive, snapshot current state first, and automatically roll back if the restored configuration fails validation.

## Uninstalling

```bash
sudo vless uninstall              # interactive: choose keep-data or full purge
sudo vless uninstall --keep-data  # remove program, keep config/backups/certs
sudo vless uninstall --purge      # remove everything this project created
```

Only files, systemd units, and firewall rules owned by this project are ever touched.

## Troubleshooting

```bash
sudo vless diagnostics   # OS/arch/binary/config/service/ports/firewall/TLS/disk/internet checks
sudo vless status        # quick health/version/port summary
sudo journalctl -u v2ray-vless-server -e   # service logs
sudo vless repair        # regenerate and re-validate config from current state
```

## Security notes

- All downloads are verified against Xray-core's published SHA2-256 digests before use; nothing is executed unverified.
- No `eval` on untrusted input; all shell variables are quoted; all JSON is built with `jq`, never string-concatenated.
- Configuration changes are atomic: validated with `xray -test`, applied, health-checked, and rolled back automatically on failure.
- REALITY/TLS private keys are stored with `0600` permissions, never logged, and excluded from client-facing output.
- No telemetry, no hidden network calls beyond GitHub (releases/updates) and the ACME CA you choose for TLS.

## License

MIT - see [LICENSE](LICENSE).
