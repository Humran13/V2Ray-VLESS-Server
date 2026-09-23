#!/usr/bin/env bash
# reality.sh - REALITY key/shortId generation and helpers.
# Private keys never leave this host and are never printed to normal
# client-facing output (only reality_public_key is shown to users).

# shellcheck disable=SC2034  # defaults below are consumed by install.sh
if [[ -n "${VLESS_REALITY_SH_LOADED:-}" ]]; then return 0; fi
VLESS_REALITY_SH_LOADED=1

VLESS_REALITY_DEFAULT_DEST="www.microsoft.com:443"
VLESS_REALITY_DEFAULT_FINGERPRINT="chrome"

# reality_generate_keypair: sets REALITY_PRIVATE_KEY and REALITY_PUBLIC_KEY
# using Xray's own x25519 key generator (authoritative, avoids reimplementing
# curve25519 in bash).
reality_generate_keypair() {
    [[ -x "$VLESS_XRAY_BIN" ]] || die "xray binary not found at $VLESS_XRAY_BIN"
    local out
    out="$("$VLESS_XRAY_BIN" x25519)" || die "failed to generate REALITY x25519 keypair"
    REALITY_PRIVATE_KEY="$(grep -m1 -iE 'Private ?key' <<<"$out" | awk '{print $NF}')"
    REALITY_PUBLIC_KEY="$(grep -m1 -iE 'Public ?key' <<<"$out" | awk '{print $NF}')"
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "could not parse xray x25519 output"
}

# reality_generate_short_id: 8 random hex chars (4 bytes).
reality_generate_short_id() {
    gen_random_hex 4
}

# reality_store_keys <profile_id> <private_key> <public_key>
# Stores the private key root-only (0600), owned by root, under
# $VLESS_REALITY_DIR. Never write private keys into $VLESS_STATE_FILE.
reality_store_keys() {
    local profile_id="$1" priv="$2" pub="$3"
    mkdir -p "$VLESS_REALITY_DIR"
    chmod 0700 "$VLESS_REALITY_DIR"
    local priv_file="${VLESS_REALITY_DIR}/${profile_id}.key"
    local pub_file="${VLESS_REALITY_DIR}/${profile_id}.pub"
    umask 077
    printf '%s' "$priv" > "$priv_file"
    chmod 0600 "$priv_file"
    printf '%s' "$pub" > "$pub_file"
    chmod 0600 "$pub_file"
}

reality_read_private_key() {
    local profile_id="$1"
    cat "${VLESS_REALITY_DIR}/${profile_id}.key" 2>/dev/null
}

reality_read_public_key() {
    local profile_id="$1"
    cat "${VLESS_REALITY_DIR}/${profile_id}.pub" 2>/dev/null
}

reality_delete_keys() {
    local profile_id="$1"
    rm -f -- "${VLESS_REALITY_DIR}/${profile_id}.key" "${VLESS_REALITY_DIR}/${profile_id}.pub"
}

# reality_validate_dest <host:port> - must be host:port with a plausible TLS
# port; we can't fully verify reachability/TLS1.3 support offline but we can
# reject obviously malformed values.
reality_validate_dest() {
    local dest="$1" host port
    [[ "$dest" == *:* ]] || return 1
    host="${dest%:*}"
    port="${dest##*:}"
    is_valid_domain "$host" || return 1
    is_valid_port "$port" || return 1
    return 0
}
