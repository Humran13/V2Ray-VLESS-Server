#!/usr/bin/env bash
# update.sh - independent update flows for Xray-core and the manager itself.

if [[ -n "${VLESS_UPDATE_SH_LOADED:-}" ]]; then return 0; fi
VLESS_UPDATE_SH_LOADED=1

VLESS_GITHUB_REPO="Humran13/V2Ray-VLESS-Server"

update_xray() {
    local target="${1:-}"
    local latest current
    latest="${target:-$(xray_latest_stable_version)}"
    [[ -n "$latest" ]] || die "could not determine latest stable Xray version"
    current="$(xray_installed_version)"

    if [[ "$current" == "$latest" ]]; then
        log_ok "Xray is already up to date ($current)"
        return 0
    fi

    log_info "Updating Xray: ${current:-none} -> ${latest}"
    xray_install_version "$latest" || die "Xray update failed"

    if [[ -f "$VLESS_XRAY_CONFIG" ]] && ! xray_config_test "$VLESS_XRAY_CONFIG"; then
        die "new Xray binary rejects the existing configuration - investigate before restarting the service"
    fi

    if systemd_available; then
        xray_service_restart
        xray_health_check || die "service unhealthy after Xray update"
    fi
    log_ok "Xray updated to $latest"
}

update_manager() {
    local tmp_dir
    tmp_dir="$(mk_tmp_dir)"
    log_info "Downloading latest manager release from GitHub..."
    safe_curl "https://github.com/${VLESS_GITHUB_REPO}/archive/refs/heads/main.tar.gz" "${tmp_dir}/src.tar.gz" \
        || die "failed to download manager update"
    tar -xzf "${tmp_dir}/src.tar.gz" -C "$tmp_dir"
    local src_dir
    src_dir="$(find "$tmp_dir" -maxdepth 1 -type d -name 'V2Ray-VLESS-Server-*' | head -1)"
    [[ -d "$src_dir" ]] || die "unexpected archive layout from GitHub"

    cp -a "${src_dir}/lib/." "${VLESS_PREFIX}/lib/"
    install -m 0755 "${src_dir}/bin/vless" "$VLESS_MANAGER_BIN"
    cp -f "${src_dir}/VERSION" "${VLESS_PREFIX}/VERSION"
    log_ok "Manager updated to $(cat "${src_dir}/VERSION")"
}
