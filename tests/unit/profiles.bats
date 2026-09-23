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

    for m in common validate os xray config profiles reality tls users; do
        source "${root}/lib/${m}.sh"
    done
    state_init
}
teardown() { rm -rf "$tmpdir"; }

@test "profile_add creates a valid profile" {
    profile_add default "Default" raw reality 443 "xtls-rprx-vision" '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12"],"fingerprint":"chrome"}'
    [ "$(state_query '.profiles | length')" = "1" ]
}

@test "profile_add rejects duplicate id" {
    profile_add p1 "P1" raw none 8080 "" '{}'
    run profile_add p1 "P1b" raw none 8081 "" '{}'
    [ "$status" -ne 0 ]
}

@test "profile_add rejects port conflict" {
    profile_add p1 "P1" raw none 8080 "" '{}'
    run profile_add p2 "P2" websocket tls 8080 "" '{"domain":"example.com"}'
    [ "$status" -ne 0 ]
}

@test "profile_add rejects incompatible transport+security (reality+websocket)" {
    run profile_add p1 "P1" websocket reality 443 "" '{}'
    [ "$status" -ne 0 ]
}

@test "profile_add rejects flow on non-raw transport" {
    run profile_add p1 "P1" xhttp reality 443 "xtls-rprx-vision" '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12"]}'
    [ "$status" -ne 0 ]
}

@test "profile_add rejects hysteria without tls" {
    run profile_add p1 "P1" hysteria none 8443 "" '{}'
    [ "$status" -ne 0 ]
}

@test "profile_build_inbound: raw+reality has correct network and security" {
    profile_add default "Default" raw reality 443 "xtls-rprx-vision" '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12"],"fingerprint":"chrome"}'
    reality_generate_keypair
    reality_store_keys default "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"
    run profile_build_inbound default
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.streamSettings.network=="tcp"'
    echo "$output" | jq -e '.streamSettings.security=="reality"'
    echo "$output" | jq -e '.streamSettings.realitySettings.privateKey | length > 0'
}

@test "profile_build_inbound: xhttp+tls has correct network" {
    mkdir -p "$VLESS_TLS_DIR/example.com"
    touch "$VLESS_TLS_DIR/example.com/fullchain.pem" "$VLESS_TLS_DIR/example.com/privkey.pem"
    profile_add p1 "P1" xhttp tls 443 "" '{"path":"/vless","host":"example.com","domain":"example.com"}'
    run profile_build_inbound p1
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.streamSettings.network=="xhttp"'
    echo "$output" | jq -e '.streamSettings.security=="tls"'
    echo "$output" | jq -e '.streamSettings.xhttpSettings.path=="/vless"'
}

@test "profile_build_inbound: grpc has serviceName" {
    mkdir -p "$VLESS_TLS_DIR/example.com"
    touch "$VLESS_TLS_DIR/example.com/fullchain.pem" "$VLESS_TLS_DIR/example.com/privkey.pem"
    profile_add p1 "P1" grpc tls 443 "" '{"serviceName":"mysvc","domain":"example.com"}'
    run profile_build_inbound p1
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.streamSettings.grpcSettings.serviceName=="mysvc"'
}

@test "profile_build_inbound: mkcp uses kcp network" {
    profile_add p1 "P1" mkcp none 8443 "" '{"header":"none"}'
    run profile_build_inbound p1
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.streamSettings.network=="kcp"'
}

@test "xray_full_config_build produces valid json with all enabled profiles" {
    profile_add p1 "P1" raw none 8080 "" '{}'
    profile_add p2 "P2" mkcp none 8081 "" '{"header":"none"}'
    run xray_full_config_build
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.inbounds | length == 2'
}

@test "disabled profiles excluded from full config" {
    profile_add p1 "P1" raw none 8080 "" '{}'
    profile_set_enabled p1 false
    run xray_full_config_build
    echo "$output" | jq -e '.inbounds | length == 0'
}

@test "profile_remove cascades to delete its users" {
    profile_add p1 "P1" raw none 8080 "" '{}'
    user_add p1 alice
    profile_remove p1
    [ "$(state_query '.users | length')" = "0" ]
}
