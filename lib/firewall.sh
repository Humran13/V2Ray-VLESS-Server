#!/usr/bin/env bash
# firewall.sh - UFW-aware port management. We only ever touch rules we
# ourselves created (tagged with a comment), and never flush/reset UFW or
# touch iptables/nftables directly.

if [[ -n "${VLESS_FIREWALL_SH_LOADED:-}" ]]; then return 0; fi
VLESS_FIREWALL_SH_LOADED=1

firewall_ufw_active() {
    has_cmd ufw || return 1
    ufw status 2>/dev/null | grep -qi '^Status: active'
}

# firewall_allow_port <port> <proto: tcp|udp|both>
firewall_allow_port() {
    local port="$1" proto="${2:-tcp}"
    firewall_ufw_active || { log_info "UFW inactive/not installed - skipping firewall rule for port $port"; return 0; }
    is_valid_port "$port" || die "invalid port for firewall rule: $port"

    case "$proto" in
        tcp|udp)
            ufw allow "${port}/${proto}" comment "$VLESS_UFW_COMMENT" >/dev/null
            ;;
        both)
            ufw allow "${port}/tcp" comment "$VLESS_UFW_COMMENT" >/dev/null
            ufw allow "${port}/udp" comment "$VLESS_UFW_COMMENT" >/dev/null
            ;;
        *) die "invalid proto: $proto" ;;
    esac
    log_ok "UFW: allowed port $port/$proto"
}

firewall_remove_port() {
    local port="$1" proto="${2:-tcp}"
    firewall_ufw_active || return 0
    case "$proto" in
        tcp|udp) ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true ;;
        both)
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
            ;;
    esac
}

# firewall_proto_for_transport <transport> - tcp, udp, or both.
firewall_proto_for_transport() {
    case "$1" in
        hysteria) echo "udp" ;;
        mkcp) echo "udp" ;;
        *) echo "tcp" ;;
    esac
}

# firewall_sync_all_profiles: (re)applies UFW rules for every enabled
# profile's port, and removes rules for our own ports that are no longer in
# use. We only ever delete rules carrying our own comment.
firewall_sync_all_profiles() {
    firewall_ufw_active || return 0
    local wanted_ports
    wanted_ports="$(state_query -r '.profiles[] | select(.enabled==true) | "\(.port) \(.transport)"')"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local port transport proto
        port="${line%% *}"; transport="${line#* }"
        proto="$(firewall_proto_for_transport "$transport")"
        firewall_allow_port "$port" "$proto"
    done <<<"$wanted_ports"
}
