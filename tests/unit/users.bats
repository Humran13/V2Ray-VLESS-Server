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
    export VLESS_XRAY_BIN="${root}/tests/fixtures/fake-xray"
    export VLESS_BIN_DIR="$tmpdir/bin"
    chmod +x "$VLESS_XRAY_BIN"

    for m in common validate os config profiles reality tls xray users; do
        source "${root}/lib/${m}.sh"
    done
    state_init
    profile_add p1 "P1" raw none 8080 "" '{}'
}
teardown() { rm -rf "$tmpdir"; }

@test "user_add creates a user with valid uuid" {
    user_add p1 alice
    uuid="$(state_query -r '.users[0].id')"
    run is_valid_uuid "$uuid"
    [ "$status" -eq 0 ]
}

@test "user_add rejects duplicate name on same profile" {
    user_add p1 alice
    run user_add p1 alice
    [ "$status" -ne 0 ]
}

@test "user_add rejects invalid username" {
    run user_add p1 "bad name!"
    [ "$status" -ne 0 ]
}

@test "user_add rejects unknown profile" {
    run user_add nope alice
    [ "$status" -ne 0 ]
}

@test "user_delete removes the user" {
    user_add p1 alice
    user_delete alice
    [ "$(state_query '.users | length')" = "0" ]
}

@test "user_set_enabled toggles state" {
    user_add p1 alice
    user_set_enabled alice false
    [ "$(state_query -r '.users[0].enabled')" = "false" ]
}

@test "two users on same profile get distinct uuids" {
    user_add p1 alice
    user_add p1 bob
    u1="$(state_query -r '.users[0].id')"
    u2="$(state_query -r '.users[1].id')"
    [ "$u1" != "$u2" ]
}
