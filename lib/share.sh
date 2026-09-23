#!/usr/bin/env bash
# share.sh - VLESS share-URI, QR code and client-JSON generation.
#
# URI convention follows the de-facto standard used by modern VLESS clients
# (v2rayN/v2rayNG, NekoBox, sing-box, Shadowrocket):
#   vless://<uuid>@<host>:<port>?encryption=none&security=..&type=..&<transport-params>&flow=..#<remark>

if [[ -n "${VLESS_SHARE_SH_LOADED:-}" ]]; then return 0; fi
VLESS_SHARE_SH_LOADED=1

detect_public_ip() {
    local ip
    ip="$(safe_curl_stdout "https://api.ipify.org" 2>/dev/null)"
    if [[ -z "$ip" ]]; then
        ip="$(safe_curl_stdout "https://ifconfig.me" 2>/dev/null)"
    fi
    printf '%s' "$ip"
}

_urlencode() {
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# share_build_uri <profile_id> <user_name> <host> - prints the vless:// URI.
share_build_uri() {
    local profile_id="$1" user_name="$2" host="$3"
    local profile_json user_json
    profile_json="$(profile_get_json "$profile_id")"
    user_json="$(user_get_json "$user_name")"
    [[ -n "$profile_json" && -n "$user_json" ]] || die "profile or user not found"

    local uuid port transport security flow
    uuid="$(jq -r '.id' <<<"$user_json")"
    port="$(jq -r '.port' <<<"$profile_json")"
    transport="$(jq -r '.transport' <<<"$profile_json")"
    security="$(jq -r '.security' <<<"$profile_json")"
    flow="$(jq -r '.flow // empty' <<<"$profile_json")"

    local type_param="$transport"
    [[ "$transport" == "raw" ]] && type_param="tcp"
    [[ "$transport" == "mkcp" ]] && type_param="kcp"

    local params="encryption=none&security=${security}&type=${type_param}"

    case "$security" in
        reality)
            local sni fp pbk sid
            sni="$(jq -r '.extra.serverNames[0]' <<<"$profile_json")"
            fp="$(jq -r '.extra.fingerprint // "chrome"' <<<"$profile_json")"
            pbk="$(reality_read_public_key "$profile_id")"
            sid="$(jq -r '.extra.shortIds[0] // ""' <<<"$profile_json")"
            params+="&sni=$(_urlencode "$sni")&fp=${fp}&pbk=$(_urlencode "$pbk")&sid=${sid}"
            ;;
        tls)
            local domain; domain="$(jq -r '.extra.domain // ""' <<<"$profile_json")"
            params+="&sni=$(_urlencode "$domain")&fp=chrome&alpn=h2%2Chttp%2F1.1"
            ;;
    esac

    [[ -n "$flow" ]] && params+="&flow=${flow}"

    case "$transport" in
        xhttp|websocket|httpupgrade)
            local path hosth
            path="$(jq -r '.extra.path // "/vless"' <<<"$profile_json")"
            hosth="$(jq -r '.extra.host // .extra.domain // ""' <<<"$profile_json")"
            params+="&path=$(_urlencode "$path")"
            [[ -n "$hosth" ]] && params+="&host=$(_urlencode "$hosth")"
            ;;
        grpc)
            local svc; svc="$(jq -r '.extra.serviceName // "vlessgrpc"' <<<"$profile_json")"
            params+="&serviceName=$(_urlencode "$svc")"
            ;;
        mkcp)
            local header; header="$(jq -r '.extra.header // "none"' <<<"$profile_json")"
            params+="&headerType=${header}"
            ;;
        hysteria)
            local hyauth; hyauth="$(jq -r '.extra.hysteriaAuth // ""' <<<"$profile_json")"
            params+="&auth=$(_urlencode "$hyauth")"
            ;;
    esac

    local remark; remark="$(_urlencode "${profile_id}-${user_name}")"
    printf 'vless://%s@%s:%s?%s#%s\n' "$uuid" "$host" "$port" "$params" "$remark"
}

share_print_qr() {
    local uri="$1"
    if has_cmd qrencode; then
        qrencode -t ANSIUTF8 -- "$uri"
    else
        log_warn "qrencode not installed - skipping QR rendering (URI still valid above)"
    fi
}

# share_client_json <profile_id> <user_name> <host> - a ready-to-use Xray
# client outbound JSON snippet for the given user/profile.
share_client_json() {
    local profile_id="$1" user_name="$2" host="$3"
    local profile_json user_json
    profile_json="$(profile_get_json "$profile_id")"
    user_json="$(user_get_json "$user_name")"

    local uuid port transport security flow
    uuid="$(jq -r '.id' <<<"$user_json")"
    port="$(jq -r '.port' <<<"$profile_json")"
    transport="$(jq -r '.transport' <<<"$profile_json")"
    security="$(jq -r '.security' <<<"$profile_json")"
    flow="$(jq -r '.flow // ""' <<<"$profile_json")"

    local stream; stream="$(_transport_settings_json "$profile_json")"
    local sec_client="{}"
    case "$security" in
        reality)
            local sni fp pbk sid
            sni="$(jq -r '.extra.serverNames[0]' <<<"$profile_json")"
            fp="$(jq -r '.extra.fingerprint // "chrome"' <<<"$profile_json")"
            pbk="$(reality_read_public_key "$profile_id")"
            sid="$(jq -r '.extra.shortIds[0] // ""' <<<"$profile_json")"
            sec_client="$(jq -n --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                '{security:"reality", realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:""}}')"
            ;;
        tls)
            local domain; domain="$(jq -r '.extra.domain // ""' <<<"$profile_json")"
            sec_client="$(jq -n --arg sni "$domain" '{security:"tls", tlsSettings:{serverName:$sni}}')"
            ;;
        none)
            sec_client='{"security":"none"}'
            ;;
    esac

    jq -n --arg host "$host" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" \
          --argjson stream "$stream" --argjson sec "$sec_client" \
        '{protocol:"vless", tag:"proxy",
          settings:{vnext:[{address:$host, port:$port, users:[
              {id:$uuid, encryption:"none"} + (if $flow!="" then {flow:$flow} else {} end)
          ]}]},
          streamSettings: ($stream + $sec)}'
}
