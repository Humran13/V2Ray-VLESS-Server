#!/usr/bin/env bats
setup() {
    root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    tmpdir="$(mktemp -d)"
    export VLESS_ETC="$tmpdir/etc"
    export VLESS_VAR="$tmpdir/var"
    export VLESS_BACKUP_DIR="$VLESS_VAR/backups"
    export VLESS_STATE_FILE="$VLESS_ETC/state.json"
    export VLESS_XRAY_CONFIG="$VLESS_ETC/xray/config.json"
    export VLESS_REALITY_DIR="$VLESS_ETC/reality"
    export VLESS_TLS_DIR="$VLESS_ETC/tls"
    export VLESS_PREFIX="$tmpdir/prefix"
    export VLESS_BIN_DIR="$tmpdir/bin"
    mkdir -p "$VLESS_BIN_DIR"
    cp "${root}/tests/fixtures/fake-xray" "$VLESS_BIN_DIR/xray"
    chmod +x "$VLESS_BIN_DIR/xray"
    export VLESS_XRAY_BIN="$VLESS_BIN_DIR/xray"

    for m in common validate os xray config profiles reality tls users backup; do
        source "${root}/lib/${m}.sh"
    done
    state_init
    profile_add p1 "P1" raw none 8080 "" '{}'
    user_add p1 alice
}
teardown() { rm -rf "$tmpdir"; }

@test "backup_create produces a valid archive" {
    archive="$(backup_create)"
    [ -f "$archive" ]
    run backup_validate "$archive"
    [ "$status" -eq 0 ]
}

@test "backup archive has restrictive permissions" {
    archive="$(backup_create)"
    perm="$(stat -c %a "$archive")"
    [ "$perm" = "600" ]
}

@test "backup_validate rejects corrupt archive" {
    echo "not a tarball" > "$tmpdir/bad.tar.gz"
    run backup_validate "$tmpdir/bad.tar.gz"
    [ "$status" -ne 0 ]
}

@test "backup_restore round-trips state (users survive)" {
    archive="$(backup_create)"
    user_delete alice
    [ "$(state_query '.users | length')" = "0" ]

    backup_restore "$archive"
    [ "$(state_query '.users | length')" = "1" ]
    [ "$(state_query -r '.users[0].name')" = "alice" ]
}
