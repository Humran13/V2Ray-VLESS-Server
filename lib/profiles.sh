#!/usr/bin/env bash
# profiles.sh - VLESS connection profile CRUD and Xray inbound generation.
#
# Compatibility matrix enforced here (see also validate.sh):
#   raw         + reality|tls|none   (flow xtls-rprx-vision only w/ tls|reality)
#   xhttp       + reality|tls|none
#   grpc        + reality|tls|none
#   websocket   + tls|none
#   httpupgrade + tls|none
#   mkcp        + tls|none
#   hysteria    + tls (mandatory)
# shellcheck disable=SC2016  # jq filters are intentionally single-quoted (no bash expansion wanted)

if [[ -n "${VLESS_PROFILES_SH_LOADED:-}" ]]; then return 0; fi
VLESS_PROFILES_SH_LOADED=1

profile_exists() {
    local id="$1"
    [[ "$(state_query --arg id "$id" '[.profiles[] | select(.id==$id)] | length')" != "0" ]]
}

profile_port_in_use() {
    local port="$1" exclude_id="${2:-}"
    local hits
    hits="$(state_query --arg port "$port" --arg ex "$exclude_id" \
        '[.profiles[] | select(.port==($port|tonumber) and .id!=$ex)] | length')"
    [[ "$hits" != "0" ]]
}

# system_port_in_use <port> - checks if something OTHER than our own xray
# process is already listening (best-effort; requires ss).
system_port_in_use() {
    local port="$1"
    has_cmd ss || return 1
    ss -ltnH "sport = :$port" 2>/dev/null | grep -q . && return 0
    ss -lunH "sport = :$port" 2>/dev/null | grep -q .
}

# profile_add <id> <name> <transport> <security> <port> <flow> <extra_json>
# extra_json carries transport/security-specific settings, e.g.:
#   reality: {"dest":"...","serverNames":["..."],"shortIds":["..."],"fingerprint":"chrome","privateKey":"...","publicKey":"..."}
#   tls:     {"domain":"..."}
#   ws/httpupgrade/xhttp: {"path":"...","host":"..."}
#   grpc:    {"serviceName":"..."}
#   mkcp:    {"header":"none"}
#   hysteria:{"domain":"...","up_mbps":100,"down_mbps":100}
profile_add() {
    local id="$1" name="$2" transport="$3" security="$4" port="$5" flow="${6:-}" extra="${7:-\{\}}"

    is_valid_profile_id "$id" || die "invalid profile id: $id"
    profile_exists "$id" && die "profile already exists: $id"
    is_valid_transport "$transport" || die "invalid transport: $transport"
    is_valid_security "$security" || die "invalid security: $security"
    transport_security_compatible "$transport" "$security" || \
        die "unsupported combination: $transport + $security"
    is_valid_port "$port" || die "invalid port: $port"
    profile_port_in_use "$port" && die "port $port is already used by another profile"

    if [[ -n "$flow" ]]; then
        flow_compatible "$transport" "$security" || die "flow '$flow' is not valid for $transport+$security"
    fi

    echo "$extra" | jq empty 2>/dev/null || die "invalid JSON in profile extra settings"

    state_mutate '.profiles += [{
            id: $id, name: $name, transport: $transport, security: $security,
            port: ($port|tonumber), flow: $flow, extra: $extra,
            enabled: true, created_at: $now
        }]' \
        --arg id "$id" --arg name "$name" --arg transport "$transport" \
        --arg security "$security" --arg port "$port" --arg flow "$flow" \
        --argjson extra "$extra" --arg now "$(now_iso)"

    log_ok "Profile '$id' added ($transport + $security on port $port)"
}

profile_remove() {
    local id="$1"
    profile_exists "$id" || die "no such profile: $id"
    state_mutate '.profiles |= map(select(.id != $id)) | .users |= map(select(.profile_id != $id))' --arg id "$id"
    reality_delete_keys "$id" 2>/dev/null || true
    log_ok "Profile '$id' removed"
}

profile_set_enabled() {
    local id="$1" enabled="$2"
    profile_exists "$id" || die "no such profile: $id"
    state_mutate '.profiles |= map(if .id == $id then .enabled = $enabled else . end)' \
        --arg id "$id" --argjson enabled "$enabled"
}

profile_list() {
    state_query -c '.profiles[] | {id,name,transport,security,port,enabled,users: ([$u[] | select(.profile_id==.id)] | length)}' \
        --slurpfile u <(state_query -c '.users')
}

profile_get_json() {
    local id="$1"
    state_query --arg id "$id" -c '.profiles[] | select(.id==$id)'
}

# ---- Xray inbound builders (one per transport) --------------------------

_stream_security_json() {
    local profile_json="$1"
    local security transport
    security="$(jq -r '.security' <<<"$profile_json")"
    transport="$(jq -r '.transport' <<<"$profile_json")"

    case "$security" in
        none)
            jq -n '{security:"none"}'
            ;;
        reality)
            local id dest sni shortids fp priv
            id="$(jq -r '.id' <<<"$profile_json")"
            dest="$(jq -r '.extra.dest' <<<"$profile_json")"
            sni="$(jq -c '.extra.serverNames' <<<"$profile_json")"
            shortids="$(jq -c '.extra.shortIds' <<<"$profile_json")"
            fp="$(jq -r '.extra.fingerprint // "chrome"' <<<"$profile_json")"
            priv="$(reality_read_private_key "$id")"
            [[ -n "$priv" ]] || die "REALITY private key missing for profile $id"
            jq -n --arg dest "$dest" --argjson sni "$sni" --argjson sid "$shortids" \
                  --arg priv "$priv" --arg fp "$fp" \
                '{security:"reality", realitySettings:{show:false, dest:$dest, xver:0,
                    serverNames:$sni, privateKey:$priv, shortIds:$sid, fingerprint:$fp}}'
            ;;
        tls)
            local domain
            domain="$(jq -r '.extra.domain // empty' <<<"$profile_json")"
            tls_cert_paths "$domain"
            local alpn='["h2","http/1.1"]'
            [[ "$transport" == "xhttp" ]] && alpn='["h3","h2","http/1.1"]'
            jq -n --arg sni "$domain" --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" --argjson alpn "$alpn" \
                '{security:"tls", tlsSettings:{serverName:$sni, alpn:$alpn,
                    certificates:[{certificateFile:$cert, keyFile:$key}]}}'
            ;;
    esac
}

_transport_settings_json() {
    local profile_json="$1"
    local transport; transport="$(jq -r '.transport' <<<"$profile_json")"
    case "$transport" in
        raw)
            jq -n '{network:"tcp"}'
            ;;
        xhttp)
            local path host
            path="$(jq -r '.extra.path // "/vless"' <<<"$profile_json")"
            host="$(jq -r '.extra.host // .extra.domain // ""' <<<"$profile_json")"
            jq -n --arg path "$path" --arg host "$host" \
                '{network:"xhttp", xhttpSettings:({path:$path} + (if $host!="" then {host:$host} else {} end))}'
            ;;
        grpc)
            local svc
            svc="$(jq -r '.extra.serviceName // "vlessgrpc"' <<<"$profile_json")"
            jq -n --arg svc "$svc" '{network:"grpc", grpcSettings:{serviceName:$svc, multiMode:false}}'
            ;;
        websocket)
            local path host
            path="$(jq -r '.extra.path // "/vless"' <<<"$profile_json")"
            host="$(jq -r '.extra.host // .extra.domain // ""' <<<"$profile_json")"
            jq -n --arg path "$path" --arg host "$host" \
                '{network:"ws", wsSettings:({path:$path} + (if $host!="" then {headers:{Host:$host}} else {} end))}'
            ;;
        httpupgrade)
            local path host
            path="$(jq -r '.extra.path // "/vless"' <<<"$profile_json")"
            host="$(jq -r '.extra.host // .extra.domain // ""' <<<"$profile_json")"
            jq -n --arg path "$path" --arg host "$host" \
                '{network:"httpupgrade", httpupgradeSettings:({path:$path} + (if $host!="" then {host:$host} else {} end))}'
            ;;
        mkcp)
            # Current Xray (>=26.x) removed the legacy kcpSettings.header/seed
            # obfuscation fields in favor of a separate "finalmask" layer; we
            # ship plain mKCP (no legacy header obfuscation) as the safe default.
            jq -n '{network:"kcp", kcpSettings:{congestion:false}}'
            ;;
        hysteria)
            # Xray's Hysteria transport follows the Hysteria2 wire protocol:
            # a QUIC-layer "auth" secret gates the handshake, independent of
            # the VLESS per-user UUID auth carried inside it.
            local auth
            auth="$(jq -r '.extra.hysteriaAuth // ""' <<<"$profile_json")"
            jq -n --arg auth "$auth" '{network:"hysteria", hysteriaSettings:{version:2, auth:$auth, udpIdleTimeout:60}}'
            ;;
    esac
}

# profile_build_inbound <profile_id> - full inbound object incl. clients.
profile_build_inbound() {
    local id="$1"
    local profile_json; profile_json="$(profile_get_json "$id")"
    [[ -n "$profile_json" ]] || die "no such profile: $id"

    local port flow transport
    port="$(jq -r '.port' <<<"$profile_json")"
    flow="$(jq -r '.flow // empty' <<<"$profile_json")"
    transport="$(jq -r '.transport' <<<"$profile_json")"

    local clients
    clients="$(state_query --arg pid "$id" --arg flow "$flow" -c \
        '[.users[] | select(.profile_id==$pid and .enabled==true) | {id:.id, email:.name} + (if $flow!="" then {flow:$flow} else {} end)]')"

    local stream_security transport_settings
    stream_security="$(_stream_security_json "$profile_json")"
    transport_settings="$(_transport_settings_json "$profile_json")"

    local proto="tcp"
    [[ "$transport" == "hysteria" ]] && proto="udp"

    jq -n --arg id "$id" --argjson port "$port" --argjson clients "$clients" \
          --argjson stream "$stream_security" --argjson tset "$transport_settings" --arg proto "$proto" \
        '{
            tag:$id, listen:"0.0.0.0", port:$port, protocol:"vless",
            settings:{clients:$clients, decryption:"none"},
            streamSettings: ($tset + $stream),
            sniffing:{enabled:true, destOverride:["http","tls"]}
        } + (if $proto=="udp" then {} else {} end)'
}

# xray_full_config_build: assembles the complete xray config.json from all
# enabled profiles in current state.
xray_full_config_build() {
    local ids inbounds="[]"
    ids="$(state_query -r '.profiles[] | select(.enabled==true) | .id')"
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        local ib; ib="$(profile_build_inbound "$id")"
        inbounds="$(jq -c --argjson ib "$ib" '. + [$ib]' <<<"$inbounds")"
    done <<<"$ids"

    jq -n --argjson inbounds "$inbounds" \
        '{log:{loglevel:"warning"}, inbounds:$inbounds,
          outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}]}'
}
