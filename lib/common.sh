#!/usr/bin/env bash
# common.sh - shared helpers: logging, root checks, safe temp files, safe curl.
# Sourced by every other lib module; must not have side effects beyond defining
# functions/vars (except readonly path constants).
# shellcheck disable=SC2034  # several constants below are consumed by other sourced lib/*.sh files

if [[ -n "${VLESS_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
VLESS_COMMON_SH_LOADED=1

set -uo pipefail

# ---- Paths (overridable via env for testing) ---------------------------
VLESS_PREFIX="${VLESS_PREFIX:-/opt/v2ray-vless-server}"
VLESS_ETC="${VLESS_ETC:-/etc/v2ray-vless-server}"
VLESS_VAR="${VLESS_VAR:-/var/lib/v2ray-vless-server}"
VLESS_BACKUP_DIR="${VLESS_BACKUP_DIR:-${VLESS_VAR}/backups}"
VLESS_STATE_FILE="${VLESS_STATE_FILE:-${VLESS_ETC}/state.json}"
VLESS_XRAY_CONFIG="${VLESS_XRAY_CONFIG:-${VLESS_ETC}/xray/config.json}"
VLESS_REALITY_DIR="${VLESS_REALITY_DIR:-${VLESS_ETC}/reality}"
VLESS_TLS_DIR="${VLESS_TLS_DIR:-${VLESS_ETC}/tls}"
VLESS_BIN_DIR="${VLESS_BIN_DIR:-${VLESS_PREFIX}/bin}"
VLESS_XRAY_BIN="${VLESS_XRAY_BIN:-${VLESS_BIN_DIR}/xray}"
VLESS_MANAGER_BIN="${VLESS_MANAGER_BIN:-/usr/local/bin/vless}"
VLESS_SYSTEMD_UNIT="${VLESS_SYSTEMD_UNIT:-/etc/systemd/system/v2ray-vless-server.service}"
VLESS_UFW_COMMENT="v2ray-vless-server"

VLESS_MANAGER_VERSION="${VLESS_MANAGER_VERSION:-1.0.0}"

# ---- Colors (disabled when not a TTY or NO_COLOR is set) ---------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log_info()  { printf '%s[INFO]%s %s\n'  "$C_BLUE"  "$C_RESET" "$*" >&2; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[FAIL]%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ---- Root / privilege checks --------------------------------------------
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This command must be run as root (try: sudo $0 $*)"
    fi
}

# ---- Temp file / directory helpers with automatic cleanup ---------------
# (declared with += below rather than a fresh `declare -a x=()` so that a
# caller which already populated VLESS_TMP_PATHS before sourcing this file,
# e.g. install.sh's bootstrap fetch, doesn't get silently wiped)
declare -a VLESS_TMP_PATHS
VLESS_TMP_PATHS+=()

_vless_cleanup_tmp() {
    local p
    for p in "${VLESS_TMP_PATHS[@]:-}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p"
    done
}

# vless_register_cleanup_trap: installs the temp-file cleanup trap. Must be
# called explicitly by entrypoint scripts (install.sh, bin/vless) rather than
# automatically at source time, since an unconditional `trap ... EXIT` here
# would clobber the caller's own EXIT trap (e.g. the Bats test framework's)
# whenever this file is merely sourced as a library.
vless_register_cleanup_trap() {
    trap _vless_cleanup_tmp EXIT INT TERM
}

mk_tmp_file() {
    local t
    t="$(mktemp "${TMPDIR:-/tmp}/vless.XXXXXXXX")"
    VLESS_TMP_PATHS+=("$t")
    printf '%s' "$t"
}

mk_tmp_dir() {
    local t
    t="$(mktemp -d "${TMPDIR:-/tmp}/vless.XXXXXXXX")"
    VLESS_TMP_PATHS+=("$t")
    printf '%s' "$t"
}

# ---- Safe network fetch --------------------------------------------------
# safe_curl <url> <output_path> - fails closed, sane timeouts, no redirects to
# unexpected schemes, TLS verification always on.
safe_curl() {
    local url="$1" out="$2"
    [[ "$url" =~ ^https:// ]] || { log_error "refusing non-https URL: $url"; return 1; }
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
         --connect-timeout 10 --max-time 120 \
         --output "$out" -- "$url"
}

safe_curl_stdout() {
    local url="$1"
    [[ "$url" =~ ^https:// ]] || { log_error "refusing non-https URL: $url"; return 1; }
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
         --connect-timeout 10 --max-time 60 -- "$url"
}

# ---- Command existence ----------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    has_cmd "$1" || die "required command not found: $1"
}

# ---- Misc -------------------------------------------------------------
confirm() {
    local prompt="${1:-Are you sure?} [y/N] " reply
    read -r -p "$prompt" reply </dev/tty || return 1
    [[ "$reply" =~ ^[Yy]$ ]]
}

json_escape() {
    # Escapes a string for safe embedding inside a JSON string literal.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# gen_random_hex <bytes> - cryptographically secure random hex string.
gen_random_hex() {
    local n="${1:-8}"
    if has_cmd openssl; then
        openssl rand -hex "$n"
    else
        head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}
