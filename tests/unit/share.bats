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

    for m in common validate os xray config profiles reality tls users share; do
        source "${root}/lib/${m}.sh"
    done
    state_init
}
teardown() { rm -rf "$tmpdir"; }

@test "share_build_uri for REALITY+RAW+Vision contains required params" {
    profile_add default "Default" raw reality 443 "xtls-rprx-vision" '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12"],"fingerprint":"chrome"}'
    reality_generate_keypair
    reality_store_keys default "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"
    user_add default alice
    uri="$(share_build_uri default alice 203.0.113.5)"
    [[ "$uri" == vless://*@203.0.113.5:443?* ]]
    [[ "$uri" == *security=reality* ]]
    [[ "$uri" == *type=tcp* ]]
    [[ "$uri" == *flow=xtls-rprx-vision* ]]
    [[ "$uri" == *pbk=* ]]
    [[ "$uri" == *sid=ab12* ]]
}

@test "share_build_uri never leaks the REALITY private key" {
    profile_add default "Default" raw reality 443 "xtls-rprx-vision" '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12"],"fingerprint":"chrome"}'
    reality_generate_keypair
    reality_store_keys default "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"
    user_add default alice
    uri="$(share_build_uri default alice 203.0.113.5)"
    [[ "$uri" != *"$REALITY_PRIVATE_KEY"* ]]
}

@test "share_build_uri for xhttp includes path and host" {
    mkdir -p "$VLESS_TLS_DIR/example.com"
    touch "$VLESS_TLS_DIR/example.com/fullchain.pem" "$VLESS_TLS_DIR/example.com/privkey.pem"
    profile_add p1 "P1" xhttp tls 443 "" '{"path":"/vless","host":"example.com","domain":"example.com"}'
    user_add p1 bob
    uri="$(share_build_uri p1 bob example.com)"
    [[ "$uri" == *type=xhttp* ]]
    [[ "$uri" == *path=%2Fvless* ]]
    [[ "$uri" == *host=example.com* ]]
}

@test "share_build_uri for grpc includes serviceName" {
    mkdir -p "$VLESS_TLS_DIR/example.com"
    touch "$VLESS_TLS_DIR/example.com/fullchain.pem" "$VLESS_TLS_DIR/example.com/privkey.pem"
    profile_add p1 "P1" grpc tls 443 "" '{"serviceName":"mysvc","domain":"example.com"}'
    user_add p1 carol
    uri="$(share_build_uri p1 carol example.com)"
    [[ "$uri" == *serviceName=mysvc* ]]
}
