#!/usr/bin/env bash
# uninstall.sh - clean removal of only this project's files/services/rules.

if [[ -n "${VLESS_UNINSTALL_SH_LOADED:-}" ]]; then return 0; fi
VLESS_UNINSTALL_SH_LOADED=1

# uninstall_run <mode: purge|keep-data>
uninstall_run() {
    local mode="${1:-keep-data}"

    if systemd_available; then
        systemctl stop v2ray-vless-server 2>/dev/null || true
        systemctl disable v2ray-vless-server 2>/dev/null || true
        rm -f "$VLESS_SYSTEMD_UNIT"
        systemctl daemon-reload 2>/dev/null || true
    fi

    if firewall_ufw_active; then
        local ports
        ports="$(state_query -r '.profiles[] | .port' 2>/dev/null)"
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            firewall_remove_port "$p" both
        done <<<"$ports"
    fi

    rm -rf "$VLESS_PREFIX"
    rm -f "$VLESS_MANAGER_BIN"

    if [[ "$mode" == "purge" ]]; then
        rm -rf "$VLESS_ETC" "$VLESS_VAR"
        log_ok "Complete removal finished (state, backups, certs and keys deleted)"
    else
        log_ok "Program removed. Configuration and backups preserved at $VLESS_ETC and $VLESS_BACKUP_DIR"
    fi
}
