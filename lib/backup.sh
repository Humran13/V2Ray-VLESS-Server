#!/usr/bin/env bash
# backup.sh - backup/restore of manager state (config, users, profiles,
# REALITY keys, TLS certs). Excludes the Xray binary itself (re-downloaded).

if [[ -n "${VLESS_BACKUP_SH_LOADED:-}" ]]; then return 0; fi
VLESS_BACKUP_SH_LOADED=1

backup_create() {
    mkdir -p "$VLESS_BACKUP_DIR"
    chmod 0700 "$VLESS_BACKUP_DIR"
    local stamp file
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    file="${VLESS_BACKUP_DIR}/vless-backup-${stamp}.tar.gz"

    local staging; staging="$(mk_tmp_dir)"
    mkdir -p "$staging/etc"
    [[ -d "$VLESS_ETC" ]] && cp -a "$VLESS_ETC/." "$staging/etc/" 2>/dev/null

    jq -n --arg v "$VLESS_MANAGER_VERSION" --arg t "$(now_iso)" '{manager_version:$v, created_at:$t}' > "$staging/manifest.json"

    tar -czf "$file" -C "$staging" .
    chmod 0600 "$file"
    log_ok "Backup created: $file"
    printf '%s' "$file"
}

# backup_validate <archive> - sanity checks before restoring.
backup_validate() {
    local archive="$1"
    [[ -f "$archive" ]] || { log_error "backup file not found: $archive"; return 1; }
    tar -tzf "$archive" >/dev/null 2>&1 || { log_error "backup archive is corrupt: $archive"; return 1; }
    tar -tzf "$archive" | grep -q '^./manifest.json$\|^manifest.json$' || { log_error "not a valid vless backup (missing manifest.json)"; return 1; }
    return 0
}

# backup_restore <archive> - restores with automatic rollback on failure.
backup_restore() {
    local archive="$1"
    backup_validate "$archive" || die "invalid backup archive"

    local pre_restore_backup
    pre_restore_backup="$(backup_create)"
    log_info "Safety snapshot of current state saved to $pre_restore_backup before restoring"

    local staging; staging="$(mk_tmp_dir)"
    tar -xzf "$archive" -C "$staging"
    [[ -d "$staging/etc" ]] || die "backup missing expected etc/ directory"

    rm -rf "${VLESS_ETC:?}"/*
    cp -a "$staging/etc/." "$VLESS_ETC/"
    chmod 0750 "$VLESS_ETC"
    [[ -f "$VLESS_STATE_FILE" ]] && chmod 0640 "$VLESS_STATE_FILE"

    if [[ ! -f "$VLESS_XRAY_CONFIG" ]] || ! xray_config_test "$VLESS_XRAY_CONFIG"; then
        log_error "restored configuration is invalid - rolling back to pre-restore snapshot"
        rm -rf "${VLESS_ETC:?}"/*
        local rb_staging; rb_staging="$(mk_tmp_dir)"
        tar -xzf "$pre_restore_backup" -C "$rb_staging"
        cp -a "$rb_staging/etc/." "$VLESS_ETC/"
        die "restore failed and was rolled back"
    fi

    if systemd_available; then
        xray_service_restart || true
        xray_health_check || log_warn "service did not report healthy after restore; check 'vless diagnostics'"
    fi
    log_ok "Restore complete from $archive"
}

backup_list() {
    [[ -d "$VLESS_BACKUP_DIR" ]] || return 0
    find "$VLESS_BACKUP_DIR" -maxdepth 1 -name 'vless-backup-*.tar.gz' -printf '%f\n' 2>/dev/null | sort
}
