#!/usr/bin/env bash
# xray.sh - download, verify, install and control the Xray-core binary.

if [[ -n "${VLESS_XRAY_SH_LOADED:-}" ]]; then return 0; fi
VLESS_XRAY_SH_LOADED=1

VLESS_XRAY_REPO="XTLS/Xray-core"
VLESS_XRAY_API="https://api.github.com/repos/${VLESS_XRAY_REPO}/releases"

# xray_latest_stable_version: echoes tag (e.g. v26.3.27) of the latest
# non-prerelease release.
xray_latest_stable_version() {
    local json
    json="$(safe_curl_stdout "${VLESS_XRAY_API}/latest")" || return 1
    grep -m1 -oE '"tag_name": *"[^"]+"' <<<"$json" | cut -d'"' -f4
}

# xray_installed_version: echoes version reported by installed binary, or
# empty string if not installed.
xray_installed_version() {
    if [[ -x "$VLESS_XRAY_BIN" ]]; then
        "$VLESS_XRAY_BIN" version 2>/dev/null | grep -m1 -oE 'Xray [0-9]+\.[0-9]+\.[0-9]+' | awk '{print "v"$2}'
    fi
}

# xray_asset_name: maps ARCH (set by arch_detect) to release zip filename.
xray_asset_name() {
    printf 'Xray-linux-%s.zip' "$ARCH"
}

# xray_download_and_verify <version> <dest_dir>
# Downloads the release zip + .dgst digest file, verifies SHA2-256, and
# leaves the extracted binary at <dest_dir>/xray.
xray_download_and_verify() {
    local version="$1" dest_dir="$2"
    local asset base_url zip_url dgst_url tmp_zip tmp_dgst expected actual

    asset="$(xray_asset_name)"
    base_url="https://github.com/${VLESS_XRAY_REPO}/releases/download/${version}"
    zip_url="${base_url}/${asset}"
    dgst_url="${zip_url}.dgst"

    tmp_zip="$(mk_tmp_file)"
    tmp_dgst="$(mk_tmp_file)"

    log_info "Downloading Xray ${version} (${asset})..."
    safe_curl "$zip_url" "$tmp_zip" || { log_error "download failed: $zip_url"; return 1; }
    safe_curl "$dgst_url" "$tmp_dgst" || { log_error "download failed: $dgst_url"; return 1; }

    expected="$(grep -m1 '^SHA2-256=' "$tmp_dgst" | cut -d= -f2 | tr -d ' \r\n')"
    [[ -n "$expected" ]] || { log_error "could not parse expected checksum from $dgst_url"; return 1; }

    if has_cmd sha256sum; then
        actual="$(sha256sum "$tmp_zip" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$tmp_zip" | awk '{print $1}')"
    fi

    if [[ "${actual,,}" != "${expected,,}" ]]; then
        log_error "checksum mismatch for $asset (expected $expected, got $actual)"
        return 1
    fi
    log_ok "Checksum verified (SHA2-256)"

    require_cmd unzip
    local extract_dir
    extract_dir="$(mk_tmp_dir)"
    unzip -q -o "$tmp_zip" -d "$extract_dir" xray || { log_error "failed to extract xray binary"; return 1; }
    [[ -f "$extract_dir/xray" ]] || { log_error "xray binary missing from archive"; return 1; }

    mkdir -p "$dest_dir"
    install -m 0755 "$extract_dir/xray" "$dest_dir/xray"
    log_ok "Installed xray binary to $dest_dir/xray"
}

# xray_install_version <version> - downloads+verifies+installs, with
# automatic rollback of the previous binary if anything fails afterward.
xray_install_version() {
    local version="$1"
    local backup=""
    if [[ -x "$VLESS_XRAY_BIN" ]]; then
        backup="$(mk_tmp_file)"
        cp -f "$VLESS_XRAY_BIN" "$backup"
    fi

    if ! xray_download_and_verify "$version" "$VLESS_BIN_DIR"; then
        if [[ -n "$backup" ]]; then
            log_warn "install failed, restoring previous xray binary"
            install -m 0755 "$backup" "$VLESS_XRAY_BIN"
        fi
        return 1
    fi
    return 0
}

# xray_config_test <config_path> - validates a config file using Xray's own
# `xray -test` facility. This is the authoritative check: no config is ever
# applied without passing this.
xray_config_test() {
    local config="$1"
    [[ -x "$VLESS_XRAY_BIN" ]] || die "xray binary not found at $VLESS_XRAY_BIN"
    "$VLESS_XRAY_BIN" run -test -format json -config "$config" >/tmp/vless-xray-test.log 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Xray config validation failed:"
        cat /tmp/vless-xray-test.log >&2
    fi
    return $rc
}

xray_service_status() {
    systemctl is-active v2ray-vless-server 2>/dev/null || echo "unknown"
}

xray_service_restart() {
    systemctl restart v2ray-vless-server
}

xray_service_reload_or_restart() {
    if systemctl reload-or-restart v2ray-vless-server 2>/dev/null; then
        return 0
    fi
    systemctl restart v2ray-vless-server
}

# xray_health_check: after (re)starting, confirm the service is actually up
# and listening, not just that systemd reports "active".
xray_health_check() {
    local tries=0
    while (( tries < 10 )); do
        if systemctl is-active --quiet v2ray-vless-server; then
            return 0
        fi
        sleep 0.5
        (( tries++ ))
    done
    return 1
}
