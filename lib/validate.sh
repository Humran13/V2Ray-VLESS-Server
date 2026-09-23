#!/usr/bin/env bash
# validate.sh - pure input-validation helpers. No side effects, easy to unit test.

if [[ -n "${VLESS_VALIDATE_SH_LOADED:-}" ]]; then return 0; fi
VLESS_VALIDATE_SH_LOADED=1

is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# RFC 1123-ish hostname/domain validation (no scheme, no trailing dot required).
is_valid_domain() {
    local d="$1"
    [[ ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

is_valid_username() {
    # display names: letters, numbers, dash, underscore, dot; 1-64 chars.
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

is_valid_profile_id() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$|^[a-z0-9]$ ]]
}

# gRPC serviceName / generic path-ish token: no control chars, no whitespace.
is_valid_service_name() {
    local s="$1"
    [[ -n "$s" && ${#s} -le 128 ]] || return 1
    [[ "$s" =~ ^[A-Za-z0-9._~-]+$ ]]
}

# HTTP path used by WebSocket/HTTPUpgrade/XHTTP: must start with / and
# contain only safe URL path characters.
is_valid_http_path() {
    local p="$1"
    [[ -n "$p" && ${#p} -le 256 ]] || return 1
    [[ "$p" == /* ]] || return 1
    [[ "$p" =~ ^/[A-Za-z0-9._~/-]*$ ]]
}

is_valid_short_id() {
    # REALITY shortId: 0-16 hex chars (even length).
    [[ "$1" =~ ^[0-9a-fA-F]{0,16}$ ]] || return 1
    (( ${#1} % 2 == 0 ))
}

is_valid_sni() {
    is_valid_domain "$1"
}

# version_ge A B -> true if semver-ish A >= B. Handles plain "vMAJOR.MINOR.PATCH".
version_ge() {
    local a="${1#v}" b="${2#v}"
    [[ "$a" == "$b" ]] && return 0
    local higher
    higher="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
    [[ "$higher" == "$a" ]]
}

is_valid_transport() {
    case "$1" in
        raw|xhttp|grpc|websocket|httpupgrade|mkcp|hysteria) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_security() {
    case "$1" in
        reality|tls|none) return 0 ;;
        *) return 1 ;;
    esac
}

# transport_security_compatible <transport> <security> - enforces the
# compatibility matrix documented in README.md / profiles.sh.
transport_security_compatible() {
    local transport="$1" security="$2"
    case "$transport" in
        raw)
            case "$security" in reality|tls|none) return 0 ;; *) return 1 ;; esac ;;
        xhttp)
            case "$security" in reality|tls|none) return 0 ;; *) return 1 ;; esac ;;
        grpc)
            case "$security" in reality|tls|none) return 0 ;; *) return 1 ;; esac ;;
        websocket)
            case "$security" in tls|none) return 0 ;; *) return 1 ;; esac ;;
        httpupgrade)
            case "$security" in tls|none) return 0 ;; *) return 1 ;; esac ;;
        mkcp)
            case "$security" in tls|none) return 0 ;; *) return 1 ;; esac ;;
        hysteria)
            [[ "$security" == "tls" ]] ;;
        *) return 1 ;;
    esac
}

# flow_compatible <transport> <security> - XTLS Vision only applies to
# RAW with TLS or REALITY.
flow_compatible() {
    local transport="$1" security="$2"
    [[ "$transport" == "raw" && ( "$security" == "tls" || "$security" == "reality" ) ]]
}
