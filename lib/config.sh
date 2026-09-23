#!/usr/bin/env bash
# config.sh - manager state store (JSON via jq) and atomic Xray config
# apply/rollback. This is the safety-critical module: no change ever
# reaches the live Xray config without passing `xray -test` first.

if [[ -n "${VLESS_CONFIG_SH_LOADED:-}" ]]; then return 0; fi
VLESS_CONFIG_SH_LOADED=1

VLESS_STATE_LOCK="${VLESS_STATE_LOCK:-${VLESS_ETC}/.state.lock}"

state_init() {
    mkdir -p "$VLESS_ETC" "$(dirname "$VLESS_XRAY_CONFIG")" "$VLESS_REALITY_DIR" "$VLESS_TLS_DIR"
    chmod 0750 "$VLESS_ETC"
    if [[ ! -f "$VLESS_STATE_FILE" ]]; then
        jq -n --arg v "$VLESS_MANAGER_VERSION" \
            '{manager_version:$v, profiles:[], users:[]}' > "$VLESS_STATE_FILE"
        chmod 0640 "$VLESS_STATE_FILE"
    fi
}

# state_read: prints the whole state JSON to stdout.
state_read() {
    [[ -f "$VLESS_STATE_FILE" ]] || state_init
    cat "$VLESS_STATE_FILE"
}

# state_query <jq_filter> [args...]: runs a read-only jq filter over state.
state_query() {
    local filter="$1"; shift
    jq -r "$filter" "$@" "$VLESS_STATE_FILE"
}

# state_mutate <jq_filter> [--argjson name val | --arg name val ...]:
# applies a jq transform to state.json atomically (write to temp, validate
# JSON, then rename over the original). Takes an flock to serialize
# concurrent manager invocations.
state_mutate() {
    local filter="$1"; shift
    [[ -f "$VLESS_STATE_FILE" ]] || state_init
    mkdir -p "$(dirname "$VLESS_STATE_LOCK")"
    exec {lock_fd}>"$VLESS_STATE_LOCK"
    flock "$lock_fd"

    local tmp
    tmp="$(mk_tmp_file)"
    if ! jq "$@" "$filter" "$VLESS_STATE_FILE" > "$tmp"; then
        flock -u "$lock_fd"
        die "internal error: state mutation failed to produce valid JSON"
    fi
    jq empty "$tmp" || { flock -u "$lock_fd"; die "internal error: mutated state is not valid JSON"; }
    chmod 0640 "$tmp"
    mv -f "$tmp" "$VLESS_STATE_FILE"
    flock -u "$lock_fd"
}

# ---- Atomic Xray config apply -------------------------------------------

# xray_config_apply <candidate_config_path>
# 1. validates JSON syntax
# 2. runs `xray -test`
# 3. backs up current live config
# 4. atomically installs candidate
# 5. reloads the service
# 6. health-checks
# 7. rolls back + restarts on any failure
xray_config_apply() {
    local candidate="$1"
    jq empty "$candidate" 2>/dev/null || { log_error "candidate config is not valid JSON"; return 1; }
    xray_config_test "$candidate" || { log_error "candidate config failed xray -test"; return 1; }

    mkdir -p "$(dirname "$VLESS_XRAY_CONFIG")"
    local backup=""
    if [[ -f "$VLESS_XRAY_CONFIG" ]]; then
        backup="$(mk_tmp_file)"
        cp -f "$VLESS_XRAY_CONFIG" "$backup"
    fi

    local tmp_live
    tmp_live="$(mk_tmp_file)"
    cp -f "$candidate" "$tmp_live"
    chmod 0640 "$tmp_live"
    mv -f "$tmp_live" "$VLESS_XRAY_CONFIG"

    if ! systemd_available || [[ ! -f "$VLESS_SYSTEMD_UNIT" ]]; then
        log_warn "systemd/service unit not available yet; skipping service reload (config file written)"
        return 0
    fi

    if xray_service_reload_or_restart && xray_health_check; then
        log_ok "Xray configuration applied and service healthy"
        return 0
    fi

    log_error "service failed health check after config change - rolling back"
    if [[ -n "$backup" ]]; then
        cp -f "$backup" "$VLESS_XRAY_CONFIG"
        xray_service_restart || true
        if xray_health_check; then
            log_warn "rolled back to previous working configuration"
        else
            log_error "rollback restart also failed - manual intervention required"
        fi
    fi
    return 1
}
