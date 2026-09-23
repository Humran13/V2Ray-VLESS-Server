#!/usr/bin/env bash
# validate_all_profiles.sh - Stage C: for every advertised connection profile
# template (see install.sh PROFILE_MENU), generate a representative Xray
# config and validate it against the REAL xray -test facility. No profile is
# allowed to ship if its config fails here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export VLESS_ETC; VLESS_ETC="$(mktemp -d)/etc"
export VLESS_VAR; VLESS_VAR="$(mktemp -d)/var"
export VLESS_BACKUP_DIR="${VLESS_VAR}/backups"
export VLESS_STATE_FILE="${VLESS_ETC}/state.json"
export VLESS_XRAY_CONFIG="${VLESS_ETC}/xray/config.json"
export VLESS_REALITY_DIR="${VLESS_ETC}/reality"
export VLESS_TLS_DIR="${VLESS_ETC}/tls"
export VLESS_BIN_DIR="${VLESS_XRAY_TEST_DIR:?set VLESS_XRAY_TEST_DIR to dir containing real xray binary}"
export VLESS_XRAY_BIN="${VLESS_BIN_DIR}/xray"

for m in common validate os xray config profiles reality tls users; do
    # shellcheck source=/dev/null
    source "${ROOT}/lib/${m}.sh"
done
state_init

pass=0
fail=0

check_profile() {
    local id="$1" name="$2" transport="$3" security="$4" port="$5" flow="$6" extra="$7"
    echo "---- $name ($transport + $security) ----"

    if [[ "$security" == "tls" ]]; then
        tls_generate_self_signed "test.example.com" "${VLESS_TLS_DIR}/test.example.com"
    fi

    if ! profile_add "$id" "$name" "$transport" "$security" "$port" "$flow" "$extra"; then
        echo "FAIL: profile_add rejected a supposedly-valid combination"
        fail=$((fail+1))
        return
    fi

    if [[ "$security" == "reality" ]]; then
        reality_generate_keypair
        reality_store_keys "$id" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"
    fi

    user_add "$id" "testuser" >/dev/null

    local cfg; cfg="$(mktemp)"
    xray_full_config_build > "$cfg"

    if xray_config_test "$cfg"; then
        echo "PASS: $name"
        pass=$((pass+1))
    else
        echo "FAIL: $name - xray -test rejected the generated config"
        cat "$cfg"
        fail=$((fail+1))
    fi
    rm -f "$cfg"
}

# The 11 profile templates offered by install.sh, using distinct ports to
# avoid conflicts since we add them all to the same state.
check_profile reality-vision "REALITY+RAW+Vision"  raw         reality 10001 "xtls-rprx-vision" \
    '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12cd34"],"fingerprint":"chrome"}'
check_profile reality-xhttp  "REALITY+XHTTP"        xhttp       reality 10002 "" \
    '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12cd34"],"fingerprint":"chrome","path":"/vless"}'
check_profile reality-grpc   "REALITY+gRPC"         grpc        reality 10003 "" \
    '{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"shortIds":["ab12cd34"],"fingerprint":"chrome","serviceName":"vlessgrpc"}'
check_profile tls-xhttp      "TLS+XHTTP"            xhttp       tls     10004 "" \
    '{"domain":"test.example.com","path":"/vless","host":"test.example.com"}'
check_profile tls-ws         "TLS+WebSocket"        websocket   tls     10005 "" \
    '{"domain":"test.example.com","path":"/vless","host":"test.example.com"}'
check_profile tls-httpupgrade "TLS+HTTPUpgrade"     httpupgrade tls     10006 "" \
    '{"domain":"test.example.com","path":"/vless","host":"test.example.com"}'
check_profile tls-grpc       "TLS+gRPC"             grpc        tls     10007 "" \
    '{"domain":"test.example.com","serviceName":"vlessgrpc"}'
check_profile tls-raw        "TLS+RAW+Vision"       raw         tls     10008 "xtls-rprx-vision" \
    '{"domain":"test.example.com"}'
check_profile tls-mkcp       "TLS+mKCP"             mkcp        tls     10009 "" \
    '{"domain":"test.example.com","header":"none"}'
check_profile tls-hysteria   "TLS+Hysteria"         hysteria    tls     10010 "" \
    '{"domain":"test.example.com","up_mbps":100,"down_mbps":100}'
check_profile none-xhttp     "none+XHTTP (advanced)" xhttp      none    10011 "" \
    '{"path":"/vless"}'

echo ""
echo "===================================================="
echo " Xray config validation: $pass passed, $fail failed"
echo "===================================================="
[[ $fail -eq 0 ]]
