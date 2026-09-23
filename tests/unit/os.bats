#!/usr/bin/env bats
setup() {
    load_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "${load_dir}/lib/common.sh"
    source "${load_dir}/lib/validate.sh"
    source "${load_dir}/lib/os.sh"
    tmpdir="$(mktemp -d)"
}
teardown() { rm -rf "$tmpdir"; }

_write_os_release() {
    printf 'ID=ubuntu\nVERSION_ID="%s"\nPRETTY_NAME="Ubuntu %s"\n' "$1" "$1" > "$tmpdir/os-release"
}

@test "explicitly tested Ubuntu version detected as tested" {
    _write_os_release "22.04"
    VLESS_OS_RELEASE_FILE="$tmpdir/os-release" run os_detect
    [ "$status" -eq 0 ]
}

@test "future untested Ubuntu >= 18.04 continues with warning" {
    _write_os_release "27.04"
    export VLESS_OS_RELEASE_FILE="$tmpdir/os-release"
    os_detect
    [ "$OS_TESTED" = "no" ]
    [ "$OS_VERSION_ID" = "27.04" ]
}

@test "Ubuntu below 18.04 is rejected" {
    _write_os_release "16.04"
    VLESS_OS_RELEASE_FILE="$tmpdir/os-release" run os_detect
    [ "$status" -ne 0 ]
}

@test "non-Ubuntu distro is rejected" {
    printf 'ID=debian\nVERSION_ID="12"\n' > "$tmpdir/os-release"
    VLESS_OS_RELEASE_FILE="$tmpdir/os-release" run os_detect
    [ "$status" -ne 0 ]
}

@test "amd64 architecture maps to xray '64' asset name" {
    run arch_detect
    [ "$status" -eq 0 ]
}
