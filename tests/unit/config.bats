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
    export VLESS_BIN_DIR="$tmpdir/bin"
    mkdir -p "$VLESS_BIN_DIR"
    cp "${root}/tests/fixtures/fake-xray" "$VLESS_BIN_DIR/xray"
    chmod +x "$VLESS_BIN_DIR/xray"
    export VLESS_XRAY_BIN="$VLESS_BIN_DIR/xray"

    for m in common validate os xray config profiles reality tls users; do
        source "${root}/lib/${m}.sh"
    done
    state_init
}
teardown() { rm -rf "$tmpdir"; }

@test "state_init creates state file with valid empty schema" {
    [ -f "$VLESS_STATE_FILE" ]
    run jq -e '.profiles==[] and .users==[]' "$VLESS_STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "state_mutate is atomic: file always valid JSON even after many writes" {
    for i in 1 2 3 4 5; do
        state_mutate '.profiles += [{id:$id}]' --arg id "p$i"
    done
    run jq -e '.profiles | length == 5' "$VLESS_STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "state_mutate rejects malformed jq filters without corrupting state" {
    cp "$VLESS_STATE_FILE" "$tmpdir/before.json"
    run state_mutate '.profiles += ['  # malformed
    [ "$status" -ne 0 ]
    diff "$tmpdir/before.json" "$VLESS_STATE_FILE"
}

@test "xray_config_apply writes candidate on success (no systemd in container)" {
    echo '{"log":{},"inbounds":[],"outbounds":[]}' > "$tmpdir/candidate.json"
    run xray_config_apply "$tmpdir/candidate.json"
    [ "$status" -eq 0 ]
    [ -f "$VLESS_XRAY_CONFIG" ]
}

@test "xray_config_apply rejects invalid JSON candidate and leaves nothing behind" {
    echo 'not json' > "$tmpdir/bad.json"
    run xray_config_apply "$tmpdir/bad.json"
    [ "$status" -ne 0 ]
    [ ! -f "$VLESS_XRAY_CONFIG" ]
}

@test "xray_config_apply preserves previous good config when new candidate is invalid" {
    echo '{"log":{},"inbounds":[],"outbounds":[]}' > "$tmpdir/good.json"
    xray_config_apply "$tmpdir/good.json"
    before="$(cat "$VLESS_XRAY_CONFIG")"

    echo 'not valid json at all' > "$tmpdir/bad.json"
    run xray_config_apply "$tmpdir/bad.json"
    [ "$status" -ne 0 ]

    after="$(cat "$VLESS_XRAY_CONFIG")"
    [ "$before" = "$after" ]
}
