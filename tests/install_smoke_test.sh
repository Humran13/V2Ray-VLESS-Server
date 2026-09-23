#!/usr/bin/env bash
# install_smoke_test.sh - runs install.sh fully non-interactively inside
# a container, then exercises the manager (status/user add/list/diagnostics)
# and reruns the installer to check idempotency. Meant to be invoked as
# root inside a fresh Ubuntu container with /workspace mounted at the repo.
set -uo pipefail

REPO_DIR="${1:-/workspace}"
cd "$REPO_DIR" || exit 1

echo "== apt-get update/install baseline tools =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null

echo "== Running install.sh (non-interactive, REALITY profile) =="
export VLESS_NONINTERACTIVE=1
export VLESS_PROFILE=reality-vision
export VLESS_PORT=443
bash "${REPO_DIR}/install.sh"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "SMOKE TEST FAILED: install.sh exited $rc"
    exit 1
fi

echo "== Verifying installed artifacts =="
[[ -x /usr/local/bin/vless ]] || { echo "FAIL: vless not installed"; exit 1; }
[[ -x /opt/v2ray-vless-server/bin/xray ]] || { echo "FAIL: xray binary not installed"; exit 1; }
[[ -f /etc/v2ray-vless-server/xray/config.json ]] || { echo "FAIL: xray config not written"; exit 1; }
jq empty /etc/v2ray-vless-server/xray/config.json || { echo "FAIL: xray config not valid JSON"; exit 1; }

echo "== vless status =="
/usr/local/bin/vless status

echo "== vless user add/list/show/delete =="
/usr/local/bin/vless user add default smoketest
user_list_out="$(/usr/local/bin/vless user list)"
[[ "$user_list_out" == *smoketest* ]] || { echo "FAIL: user not listed"; exit 1; }
user_show_out="$(/usr/local/bin/vless user show smoketest)"
[[ "$user_show_out" == *"vless://"* ]] || { echo "FAIL: no URI shown"; exit 1; }
/usr/local/bin/vless user disable smoketest
/usr/local/bin/vless user enable smoketest
/usr/local/bin/vless user delete smoketest

echo "== vless diagnostics =="
/usr/local/bin/vless diagnostics || echo "diagnostics reported issues (expected: no real systemd in plain container)"

echo "== vless backup =="
/usr/local/bin/vless backup

echo "== Re-running install.sh to verify idempotency (repair path) =="
VLESS_NONINTERACTIVE=1 bash "${REPO_DIR}/install.sh" <<<"1" || { echo "FAIL: second install run failed"; exit 1; }

echo "== vless uninstall (keep-data) =="
/usr/local/bin/vless uninstall --keep-data
[[ -x /usr/local/bin/vless ]] && { echo "FAIL: vless binary still present after uninstall"; exit 1; }
[[ -d /etc/v2ray-vless-server ]] || { echo "FAIL: config should be kept after non-purge uninstall"; exit 1; }

echo "SMOKE TEST PASSED"
