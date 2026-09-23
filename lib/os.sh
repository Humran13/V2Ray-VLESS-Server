#!/usr/bin/env bash
# os.sh - OS/architecture detection and compatibility checks.

if [[ -n "${VLESS_OS_SH_LOADED:-}" ]]; then return 0; fi
VLESS_OS_SH_LOADED=1

# Officially tested Ubuntu releases (VERSION_ID values).
VLESS_TESTED_UBUNTU=("18.04" "20.04" "22.04" "24.04" "26.04")
VLESS_MIN_UBUNTU_MAJOR=18

# os_detect: populates OS_ID, OS_VERSION_ID, OS_NAME, OS_TESTED from
# /etc/os-release (or $VLESS_OS_RELEASE_FILE for tests).
os_detect() {
    local f="${VLESS_OS_RELEASE_FILE:-/etc/os-release}"
    [[ -r "$f" ]] || die "cannot read $f - unsupported/unrecognized operating system"

    OS_ID=""; OS_VERSION_ID=""; OS_NAME=""
    # shellcheck disable=SC1090
    local id version_id name
    id=$(grep -E '^ID=' "$f" | head -1 | cut -d= -f2- | tr -d '"')
    version_id=$(grep -E '^VERSION_ID=' "$f" | head -1 | cut -d= -f2- | tr -d '"')
    name=$(grep -E '^PRETTY_NAME=' "$f" | head -1 | cut -d= -f2- | tr -d '"')
    OS_ID="$id"
    OS_VERSION_ID="$version_id"
    OS_NAME="${name:-$id $version_id}"

    [[ "$OS_ID" == "ubuntu" ]] || die "unsupported OS '$OS_ID' - this installer supports Ubuntu >= ${VLESS_MIN_UBUNTU_MAJOR}.04 only"
    [[ -n "$OS_VERSION_ID" ]] || die "could not determine Ubuntu version from $f"

    local major="${OS_VERSION_ID%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || die "unrecognized Ubuntu VERSION_ID: $OS_VERSION_ID"
    (( major >= VLESS_MIN_UBUNTU_MAJOR )) || die "Ubuntu $OS_VERSION_ID is not supported (minimum: ${VLESS_MIN_UBUNTU_MAJOR}.04)"

    OS_TESTED="no"
    local v
    for v in "${VLESS_TESTED_UBUNTU[@]}"; do
        [[ "$v" == "$OS_VERSION_ID" ]] && OS_TESTED="yes"
    done

    if [[ "$OS_TESTED" == "yes" ]]; then
        log_info "Detected $OS_NAME (explicitly tested)"
    else
        log_warn "Detected $OS_NAME - not explicitly tested, continuing since it is Ubuntu >= ${VLESS_MIN_UBUNTU_MAJOR}.04"
    fi
}

# arch_detect: sets ARCH to the Xray release asset arch name (amd64/arm64/...)
arch_detect() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   ARCH="64" ;;
        aarch64|arm64)  ARCH="arm64-v8a" ;;
        armv7l|armhf)   ARCH="arm32-v7a" ;;
        i386|i686)      ARCH="32" ;;
        *) die "unsupported CPU architecture: $m" ;;
    esac
    ARCH_HUMAN="$m"
    log_info "Detected architecture: $ARCH_HUMAN (xray asset: $ARCH)"
}

# systemd_available: true if this host actually runs systemd as PID 1 /
# init manager (as opposed to running inside a plain container).
systemd_available() {
    [[ -d /run/systemd/system ]]
}
