#!/usr/bin/env bash
# tls.sh - ACME certificate issuance/renewal for TLS profiles, via acme.sh
# (chosen over certbot for consistent behavior across Ubuntu 18.04-26.04
# without depending on snapd or distro-specific python versions).

if [[ -n "${VLESS_TLS_SH_LOADED:-}" ]]; then return 0; fi
VLESS_TLS_SH_LOADED=1

VLESS_ACME_HOME="${VLESS_ACME_HOME:-${VLESS_VAR}/acme.sh}"
VLESS_ACME_BIN="${VLESS_ACME_BIN:-${VLESS_ACME_HOME}/acme.sh}"
VLESS_ACME_INSTALL_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"

tls_acme_installed() {
    [[ -x "$VLESS_ACME_BIN" ]]
}

tls_install_acme() {
    if tls_acme_installed; then return 0; fi
    require_cmd curl
    local tmp
    tmp="$(mk_tmp_file)"
    safe_curl "$VLESS_ACME_INSTALL_URL" "$tmp" || die "failed to download acme.sh installer"
    mkdir -p "$VLESS_ACME_HOME"
    HOME="$VLESS_VAR" sh "$tmp" --home "$VLESS_ACME_HOME" --nocron --accountemail "admin@${1:-example.invalid}" \
        >/dev/null 2>&1 || die "acme.sh installation failed"
    tls_acme_installed || die "acme.sh installation reported success but binary is missing"
}

# tls_dns_resolves <domain> - checks the domain resolves to an A/AAAA record
# at all (does not verify it points at this host, since that's the user's
# responsibility and may involve CDNs/NAT).
tls_dns_resolves() {
    local domain="$1"
    if has_cmd getent; then
        getent hosts "$domain" >/dev/null 2>&1 && return 0
    fi
    if has_cmd dig; then
        [[ -n "$(dig +short "$domain" 2>/dev/null)" ]] && return 0
    fi
    return 1
}

# tls_issue_cert <domain> <email> - standalone HTTP-01 issuance. Requires
# port 80 to be free during issuance.
tls_issue_cert() {
    local domain="$1" email="${2:-}"
    is_valid_domain "$domain" || die "invalid domain: $domain"
    tls_install_acme "$domain"

    local out_dir="${VLESS_TLS_DIR}/${domain}"
    mkdir -p "$out_dir"

    log_info "Requesting Let's Encrypt certificate for $domain (standalone mode, port 80)..."
    HOME="$VLESS_VAR" "$VLESS_ACME_BIN" --home "$VLESS_ACME_HOME" --issue \
        -d "$domain" --standalone --keylength ec-256 \
        ${email:+--accountemail "$email"} \
        >/tmp/vless-acme.log 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "certificate issuance failed, see /tmp/vless-acme.log"
        return 1
    fi

    HOME="$VLESS_VAR" "$VLESS_ACME_BIN" --home "$VLESS_ACME_HOME" --install-cert -d "$domain" --ecc \
        --fullchain-file "${out_dir}/fullchain.pem" \
        --key-file "${out_dir}/privkey.pem" \
        --reloadcmd "systemctl reload-or-restart v2ray-vless-server || true" \
        >>/tmp/vless-acme.log 2>&1

    chmod 0750 "$out_dir"
    chmod 0640 "${out_dir}/privkey.pem" 2>/dev/null
    log_ok "Certificate installed at $out_dir"
}

tls_cert_paths() {
    local domain="$1"
    TLS_CERT_FILE="${VLESS_TLS_DIR}/${domain}/fullchain.pem"
    TLS_KEY_FILE="${VLESS_TLS_DIR}/${domain}/privkey.pem"
}

tls_cert_exists() {
    local domain="$1"
    tls_cert_paths "$domain"
    [[ -f "$TLS_CERT_FILE" && -f "$TLS_KEY_FILE" ]]
}

# tls_cert_expiry_epoch <domain> - epoch seconds of certificate expiry.
tls_cert_expiry_epoch() {
    local domain="$1"
    tls_cert_paths "$domain"
    [[ -f "$TLS_CERT_FILE" ]] || return 1
    local end
    end="$(openssl x509 -enddate -noout -in "$TLS_CERT_FILE" 2>/dev/null | cut -d= -f2)"
    [[ -n "$end" ]] || return 1
    date -d "$end" +%s 2>/dev/null
}

# tls_generate_self_signed <domain> <out_dir> - used ONLY by the test suite
# to stand in for a real ACME cert (never used for real installs).
tls_generate_self_signed() {
    local domain="$1" out_dir="$2"
    mkdir -p "$out_dir"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${out_dir}/privkey.pem" -out "${out_dir}/fullchain.pem" \
        -days 1 -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" \
        >/dev/null 2>&1
}
