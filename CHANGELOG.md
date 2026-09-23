# Changelog

## v1.0.0 - 2026-09-23

Initial release.

- Interactive `install.sh` for Ubuntu 18.04-26.04 (amd64/arm64), backed by official Xray-core releases with checksum verification.
- 11 VLESS connection profile templates covering REALITY (RAW/XHTTP/gRPC), TLS (XHTTP/WebSocket/HTTPUpgrade/gRPC/RAW/mKCP/Hysteria transport), and an advanced no-security mode.
- `vless` management CLI/TUI: users, profiles, status, diagnostics, backup/restore, update, repair, uninstall.
- Atomic, validated Xray configuration changes with automatic rollback on failure.
- UFW-aware firewall management, ACME (acme.sh) TLS issuance/renewal, REALITY key management.
- VLESS share URI + QR code + client JSON generation.
