#!/usr/bin/env bash
# diagnostics.sh - health checks. Returns non-zero if any serious problem
# is detected. Never prints secrets (UUIDs of individual users are not
# considered secret; REALITY/TLS private keys are never printed).
# shellcheck disable=SC2319  # $? is captured immediately on the next line, deliberately, before _check runs

if [[ -n "${VLESS_DIAGNOSTICS_SH_LOADED:-}" ]]; then return 0; fi
VLESS_DIAGNOSTICS_SH_LOADED=1

diagnostics_run() {
    local problems=0
    local check_name ok

    _check() {
        check_name="$1"; ok="$2"
        if [[ "$ok" == "0" ]]; then
            log_ok "$check_name"
        else
            log_error "$check_name"
            problems=$((problems+1))
        fi
    }

    local rc

    os_detect >/dev/null 2>&1; rc=$?
    _check "Supported OS: ${OS_NAME:-unknown}" "$rc"

    arch_detect >/dev/null 2>&1; rc=$?
    _check "Architecture: ${ARCH_HUMAN:-unknown}" "$rc"

    [[ -x "$VLESS_XRAY_BIN" ]]; rc=$?
    _check "Xray binary present ($VLESS_XRAY_BIN)" "$rc"

    if [[ -x "$VLESS_XRAY_BIN" ]]; then
        local v; v="$(xray_installed_version)"
        [[ -n "$v" ]]; rc=$?
        _check "Xray version detected ($v)" "$rc"
    fi

    if [[ -f "$VLESS_XRAY_CONFIG" ]]; then
        xray_config_test "$VLESS_XRAY_CONFIG" >/dev/null 2>&1; rc=$?
        _check "Xray configuration is valid" "$rc"
    else
        _check "Xray configuration file exists" "1"
    fi

    if systemd_available; then
        [[ -f "$VLESS_SYSTEMD_UNIT" ]]; rc=$?
        _check "systemd unit installed" "$rc"

        systemctl is-active --quiet v2ray-vless-server 2>/dev/null; rc=$?
        _check "Xray service active" "$rc"
    else
        log_warn "systemd not available in this environment - skipping service checks"
    fi

    local ports
    ports="$(state_query -r '.profiles[] | select(.enabled==true) | .port' 2>/dev/null)"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if has_cmd ss; then
            { ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; } || { ss -lunH "sport = :$p" 2>/dev/null | grep -q .; }
            rc=$?
            _check "Port $p listening" "$rc"
        fi
    done <<<"$ports"

    if firewall_ufw_active; then
        log_ok "UFW active"
    else
        log_info "UFW inactive or not installed"
    fi

    { [[ -d "$VLESS_ETC" ]] && [[ "$(stat -c %a "$VLESS_ETC" 2>/dev/null)" =~ ^7[05]0$ ]]; }
    rc=$?
    _check "State directory permissions restrictive" "$rc"

    local free_kb
    free_kb="$(df -Pk "$VLESS_PREFIX" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "$free_kb" ]] && (( free_kb > 512000 )); then
        log_ok "Disk space OK ($((free_kb/1024)) MB free)"
    else
        log_warn "Low disk space or unable to determine (${free_kb:-unknown} KB free)"
    fi

    if safe_curl_stdout "https://api.github.com" >/dev/null 2>&1; then
        log_ok "Internet/DNS reachability OK"
    else
        log_warn "Could not reach the internet (github.com) - update checks will fail"
    fi

    if (( problems > 0 )); then
        log_error "$problems problem(s) detected"
        return 1
    fi
    log_ok "No problems detected"
    return 0
}
