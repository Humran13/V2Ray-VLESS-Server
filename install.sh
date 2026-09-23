#!/usr/bin/env bash
# install.sh - V2Ray VLESS Server Manager installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Humran13/V2Ray-VLESS-Server/main/install.sh | sudo bash
#
# Non-interactive mode (used by CI/automation): set VLESS_NONINTERACTIVE=1
# and VLESS_PROFILE=<id> (see PROFILE ids below), plus VLESS_PORT and,
# for TLS profiles, VLESS_DOMAIN + VLESS_ACME_EMAIL.
# shellcheck disable=SC2016  # jq filter is intentionally single-quoted
set -uo pipefail

SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLESS_REPO_RAW_BASE="https://raw.githubusercontent.com/Humran13/V2Ray-VLESS-Server/main"
declare -a VLESS_TMP_PATHS=()

# ---- Bootstrap: locate or fetch lib/ -------------------------------------
if [[ -d "${SCRIPT_SOURCE_DIR}/lib" ]]; then
    LIB_SRC_DIR="${SCRIPT_SOURCE_DIR}/lib"
else
    # Running via `curl | bash` - fetch the rest of the repo into a temp dir.
    TMP_BOOTSTRAP="$(mktemp -d)"
    VLESS_TMP_PATHS+=("$TMP_BOOTSTRAP")
    echo "[INFO] Fetching V2Ray-VLESS-Server sources..." >&2
    curl -fsSL "${VLESS_REPO_RAW_BASE}/archive/refs/heads/main.tar.gz" -o "${TMP_BOOTSTRAP}/src.tar.gz"
    tar -xzf "${TMP_BOOTSTRAP}/src.tar.gz" -C "$TMP_BOOTSTRAP"
    SCRIPT_SOURCE_DIR="$(find "$TMP_BOOTSTRAP" -maxdepth 1 -type d -name 'V2Ray-VLESS-Server-*' | head -1)"
    LIB_SRC_DIR="${SCRIPT_SOURCE_DIR}/lib"
fi

for m in common os validate xray config profiles users reality tls firewall share backup diagnostics; do
    # shellcheck source=/dev/null
    source "${LIB_SRC_DIR}/${m}.sh"
done
vless_register_cleanup_trap

NONINTERACTIVE="${VLESS_NONINTERACTIVE:-0}"

ask() {
    local prompt="$1" default="${2:-}" var
    if [[ "$NONINTERACTIVE" == "1" ]]; then printf '%s' "$default"; return; fi
    read -r -p "$prompt" var </dev/tty
    printf '%s' "${var:-$default}"
}

step() { log_info "==> $*"; }

# ---- 1. root check --------------------------------------------------------
step "Checking privileges"
require_root

# ---- 2/3. Ubuntu detection -------------------------------------------------
step "Detecting operating system"
os_detect

# ---- 4. architecture ------------------------------------------------------
step "Detecting architecture"
arch_detect

# ---- 5. internet/DNS --------------------------------------------------------
step "Checking internet connectivity"
if ! safe_curl_stdout "https://api.github.com" >/dev/null 2>&1; then
    die "no internet connectivity to github.com - required to download Xray"
fi
log_ok "Internet OK"

# ---- 6. dependencies --------------------------------------------------------
step "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || log_warn "apt-get update reported issues, continuing"
DEPS=(curl jq unzip openssl ca-certificates qrencode iproute2)
apt-get install -y -qq "${DEPS[@]}" >/dev/null || die "failed to install required packages: ${DEPS[*]}"
log_ok "Dependencies installed"

# ---- Install project files -------------------------------------------------
step "Installing program files to ${VLESS_PREFIX}"
mkdir -p "$VLESS_PREFIX"
cp -a "${LIB_SRC_DIR}" "${VLESS_PREFIX}/lib"
cp -f "${SCRIPT_SOURCE_DIR}/VERSION" "${VLESS_PREFIX}/VERSION" 2>/dev/null || echo "1.0.0" > "${VLESS_PREFIX}/VERSION"
mkdir -p "$VLESS_BIN_DIR"
install -m 0755 "${SCRIPT_SOURCE_DIR}/bin/vless" "$VLESS_MANAGER_BIN"

state_init

# ---- 8. detect existing installation --------------------------------------
step "Checking for existing installation"
PROFILE_ID="default"
if [[ -f /usr/local/etc/xray/config.json || -f /etc/xray/config.json ]] && [[ ! -x "$VLESS_XRAY_BIN" ]]; then
    log_warn "A foreign Xray installation was detected (not managed by this project)."
    log_warn "It will NOT be modified. This installer only manages ${VLESS_ETC} and ${VLESS_SYSTEMD_UNIT}."
fi

if profile_exists "$PROFILE_ID"; then
    log_warn "An existing v2ray-vless-server installation was found (profile '$PROFILE_ID' already configured)."
    action="repair"
    if [[ "$NONINTERACTIVE" != "1" ]]; then
        echo "1) Repair/reconfigure (recommended) - validates and re-applies the existing configuration"
        echo "2) Exit without changes"
        choice="$(ask "Select [1/2]: " "1")"
        [[ "$choice" == "2" ]] && action="exit"
    fi
    if [[ "$action" == "exit" ]]; then
        log_info "No changes made."
        exit 0
    fi

    backup_create >/dev/null || true
    log_info "Existing state backed up. Repairing/reapplying existing configuration..."
    if [[ ! -x "$VLESS_XRAY_BIN" ]]; then
        XRAY_VERSION="${VLESS_XRAY_VERSION:-$(xray_latest_stable_version)}"
        [[ -n "$XRAY_VERSION" ]] || die "could not determine latest stable Xray version"
        xray_install_version "$XRAY_VERSION" || die "Xray installation failed"
    fi
    candidate_config="$(mk_tmp_file)"
    xray_full_config_build > "$candidate_config"
    if systemd_available; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable v2ray-vless-server >/dev/null 2>&1 || true
    fi
    xray_config_apply "$candidate_config" || die "existing configuration failed validation - run 'sudo vless diagnostics' for details"
    firewall_sync_all_profiles
    log_ok "Existing installation repaired and verified."
    echo "Manage this server anytime with:   sudo vless"
    exit 0
fi

# ---- 7. port availability helper -------------------------------------------
port_free() {
    local p="$1"
    ! system_port_in_use "$p"
}

# ---- 9. profile selection ---------------------------------------------------
step "Selecting connection profile"
PROFILE_MENU=(
    "reality-vision:VLESS + REALITY + RAW + XTLS Vision (Recommended)"
    "reality-xhttp:VLESS + REALITY + XHTTP"
    "reality-grpc:VLESS + REALITY + gRPC"
    "tls-xhttp:VLESS + TLS + XHTTP"
    "tls-ws:VLESS + TLS + WebSocket"
    "tls-httpupgrade:VLESS + TLS + HTTPUpgrade"
    "tls-grpc:VLESS + TLS + gRPC"
    "tls-raw:VLESS + TLS + RAW + XTLS Vision"
    "tls-mkcp:VLESS + TLS + mKCP"
    "tls-hysteria:VLESS + TLS + Hysteria transport"
    "none-xhttp:ADVANCED/NOT RECOMMENDED FOR PUBLIC INTERNET - VLESS + none + XHTTP (LAN/reverse-proxy only)"
)

if [[ "$NONINTERACTIVE" == "1" ]]; then
    SELECTED_PROFILE="${VLESS_PROFILE:-reality-vision}"
else
    echo ""
    i=1
    for entry in "${PROFILE_MENU[@]}"; do
        echo "  $i) ${entry#*:}"
        i=$((i+1))
    done
    idx="$(ask "Select a connection profile [1]: " "1")"
    [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#PROFILE_MENU[@]} )) || idx=1
    SELECTED_PROFILE="${PROFILE_MENU[$((idx-1))]%%:*}"
fi
log_info "Selected profile template: $SELECTED_PROFILE"

case "$SELECTED_PROFILE" in
    reality-vision) TRANSPORT=raw; SECURITY=reality; FLOW="xtls-rprx-vision"; DEFAULT_PORT=443 ;;
    reality-xhttp)  TRANSPORT=xhttp; SECURITY=reality; FLOW=""; DEFAULT_PORT=443 ;;
    reality-grpc)   TRANSPORT=grpc; SECURITY=reality; FLOW=""; DEFAULT_PORT=443 ;;
    tls-xhttp)      TRANSPORT=xhttp; SECURITY=tls; FLOW=""; DEFAULT_PORT=443 ;;
    tls-ws)         TRANSPORT=websocket; SECURITY=tls; FLOW=""; DEFAULT_PORT=443 ;;
    tls-httpupgrade) TRANSPORT=httpupgrade; SECURITY=tls; FLOW=""; DEFAULT_PORT=443 ;;
    tls-grpc)       TRANSPORT=grpc; SECURITY=tls; FLOW=""; DEFAULT_PORT=443 ;;
    tls-raw)        TRANSPORT=raw; SECURITY=tls; FLOW="xtls-rprx-vision"; DEFAULT_PORT=443 ;;
    tls-mkcp)       TRANSPORT=mkcp; SECURITY=tls; FLOW=""; DEFAULT_PORT=8443 ;;
    tls-hysteria)   TRANSPORT=hysteria; SECURITY=tls; FLOW=""; DEFAULT_PORT=8443 ;;
    none-xhttp)     TRANSPORT=xhttp; SECURITY=none; FLOW=""; DEFAULT_PORT=8080 ;;
    *) die "unknown profile template: $SELECTED_PROFILE" ;;
esac

# ---- 10. questions required by the profile ---------------------------------
PORT="$(ask "Port [$DEFAULT_PORT]: " "${VLESS_PORT:-$DEFAULT_PORT}")"
is_valid_port "$PORT" || die "invalid port: $PORT"
if ! port_free "$PORT"; then
    log_warn "Port $PORT appears to be in use by another process."
    [[ "$NONINTERACTIVE" == "1" ]] || confirm "Continue anyway?" || die "aborted: port in use"
fi

EXTRA_JSON="{}"
DOMAIN=""
if [[ "$SECURITY" == "tls" ]]; then
    DOMAIN="$(ask "Domain name pointing at this server (required for TLS): " "${VLESS_DOMAIN:-}")"
    is_valid_domain "$DOMAIN" || die "TLS requires a valid domain name. Re-run and choose a REALITY profile if you don't have one."
    if ! tls_dns_resolves "$DOMAIN"; then
        log_warn "DNS lookup for $DOMAIN did not resolve. Certificate issuance will likely fail until DNS is configured."
        [[ "$NONINTERACTIVE" == "1" ]] || confirm "Continue anyway?" || die "aborted: DNS not ready"
    fi
    EMAIL="$(ask "Email for certificate notices (optional): " "${VLESS_ACME_EMAIL:-}")"
fi

case "$TRANSPORT" in
    xhttp|websocket|httpupgrade)
        PATH_VAL="$(ask "Request path [/vless]: " "/vless")"
        is_valid_http_path "$PATH_VAL" || die "invalid path: $PATH_VAL"
        EXTRA_JSON="$(jq -n --arg p "$PATH_VAL" --arg h "$DOMAIN" '{path:$p, host:$h, domain:$h}')"
        ;;
    grpc)
        SVC="$(ask "gRPC serviceName [vlessgrpc]: " "vlessgrpc")"
        is_valid_service_name "$SVC" || die "invalid serviceName: $SVC"
        EXTRA_JSON="$(jq -n --arg s "$SVC" --arg h "$DOMAIN" '{serviceName:$s, domain:$h}')"
        ;;
    mkcp)
        EXTRA_JSON="$(jq -n --arg h "$DOMAIN" '{header:"none", domain:$h}')"
        ;;
    hysteria)
        HY_AUTH="$(gen_random_hex 16)"
        EXTRA_JSON="$(jq -n --arg h "$DOMAIN" --arg a "$HY_AUTH" '{domain:$h, hysteriaAuth:$a}')"
        ;;
    raw)
        EXTRA_JSON="$(jq -n --arg h "$DOMAIN" '{domain:$h}')"
        ;;
esac

if [[ "$SECURITY" == "reality" ]]; then
    REALITY_DEST="$(ask "REALITY destination [www.microsoft.com:443]: " "$VLESS_REALITY_DEFAULT_DEST")"
    reality_validate_dest "$REALITY_DEST" || die "invalid REALITY destination: $REALITY_DEST"
    REALITY_SNI="${REALITY_DEST%%:*}"
    SHORT_ID="$(reality_generate_short_id)"
    EXTRA_JSON="$(jq -n --arg dest "$REALITY_DEST" --arg sni "$REALITY_SNI" --arg sid "$SHORT_ID" --arg fp "$VLESS_REALITY_DEFAULT_FINGERPRINT" \
        '{dest:$dest, serverNames:[$sni], shortIds:[$sid], fingerprint:$fp}')"
fi

# ---- 11. install stable Xray -------------------------------------------------
step "Installing Xray-core"
XRAY_VERSION="${VLESS_XRAY_VERSION:-$(xray_latest_stable_version)}"
[[ -n "$XRAY_VERSION" ]] || die "could not determine latest stable Xray version"
if [[ "$(xray_installed_version)" != "$XRAY_VERSION" ]]; then
    xray_install_version "$XRAY_VERSION" || die "Xray installation failed"
fi
log_ok "Xray $XRAY_VERSION installed"

# ---- REALITY keys / TLS cert ------------------------------------------------
if [[ "$SECURITY" == "reality" ]]; then
    step "Generating REALITY keys"
    reality_generate_keypair
    reality_store_keys "$PROFILE_ID" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"
fi

if [[ "$SECURITY" == "tls" ]]; then
    step "Issuing TLS certificate for $DOMAIN"
    if [[ "${VLESS_SKIP_ACME:-0}" == "1" ]]; then
        log_warn "VLESS_SKIP_ACME=1 - generating a temporary self-signed certificate (TEST ONLY, replace before production use)"
        tls_generate_self_signed "$DOMAIN" "${VLESS_TLS_DIR}/${DOMAIN}"
    else
        tls_issue_cert "$DOMAIN" "${EMAIL:-}" || die "certificate issuance failed - check DNS and port 80 availability"
    fi
fi

# ---- 12. generate credentials + validated config ----------------------------
step "Creating connection profile and first user"
profile_add "$PROFILE_ID" "Default" "$TRANSPORT" "$SECURITY" "$PORT" "$FLOW" "$EXTRA_JSON"

FIRST_USER="${VLESS_FIRST_USER:-user1}"
uuid="$(gen_uuid)"
state_mutate '.users += [{id:$id, name:$name, profile_id:$pid, enabled:true, created_at:$now}]' \
    --arg id "$uuid" --arg name "$FIRST_USER" --arg pid "$PROFILE_ID" --arg now "$(now_iso)"

# ---- 13/14/16. systemd service ----------------------------------------------
step "Configuring systemd service"
cat > "$VLESS_SYSTEMD_UNIT" <<EOF
[Unit]
Description=V2Ray VLESS Server (Xray-core)
Documentation=https://github.com/Humran13/V2Ray-VLESS-Server
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${VLESS_XRAY_BIN} run -config ${VLESS_XRAY_CONFIG}
Restart=on-failure
RestartSec=3
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

candidate_config="$(mk_tmp_file)"
xray_full_config_build > "$candidate_config"

if systemd_available; then
    systemctl daemon-reload
    systemctl enable v2ray-vless-server >/dev/null 2>&1 || true
fi

xray_config_apply "$candidate_config" || die "generated configuration failed validation - installation aborted"

# ---- 15. firewall -------------------------------------------------------------
step "Configuring firewall"
proto="$(firewall_proto_for_transport "$TRANSPORT")"
firewall_allow_port "$PORT" "$proto"

# ---- 17/18. health check ------------------------------------------------------
if systemd_available; then
    step "Verifying service health"
    xray_health_check || log_warn "service did not report active immediately; check 'vless diagnostics'"
fi

# ---- 19-21. connection info ---------------------------------------------------
HOST="$(detect_public_ip 2>/dev/null || echo "YOUR_SERVER_IP")"
URI="$(share_build_uri "$PROFILE_ID" "$FIRST_USER" "$HOST")"

echo ""
log_ok "Installation complete"
echo "----------------------------------------------------------------------"
echo " Server:      $HOST"
echo " Port:        $PORT"
echo " Transport:   $TRANSPORT"
echo " Security:    $SECURITY"
echo " User:        $FIRST_USER"
echo " VLESS URI:"
echo "   $URI"
echo "----------------------------------------------------------------------"
share_print_qr "$URI"
echo ""
echo " Manage this server anytime with:   sudo vless"
echo "----------------------------------------------------------------------"
