#!/usr/bin/env bats
setup() {
    load_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "${load_dir}/lib/common.sh"
    source "${load_dir}/lib/validate.sh"
}

@test "valid uuid accepted" {
    run is_valid_uuid "550e8400-e29b-41d4-a716-446655440000"
    [ "$status" -eq 0 ]
}

@test "invalid uuid rejected" {
    run is_valid_uuid "not-a-uuid"
    [ "$status" -ne 0 ]
}

@test "uuid with wrong segment length rejected" {
    run is_valid_uuid "550e8400-e29b-41d4-a716-44665544000"
    [ "$status" -ne 0 ]
}

@test "valid ports accepted" {
    run is_valid_port "443"; [ "$status" -eq 0 ]
    run is_valid_port "1"; [ "$status" -eq 0 ]
    run is_valid_port "65535"; [ "$status" -eq 0 ]
}

@test "invalid ports rejected" {
    run is_valid_port "0"; [ "$status" -ne 0 ]
    run is_valid_port "65536"; [ "$status" -ne 0 ]
    run is_valid_port "abc"; [ "$status" -ne 0 ]
    run is_valid_port "-1"; [ "$status" -ne 0 ]
    run is_valid_port "443; rm -rf /"; [ "$status" -ne 0 ]
}

@test "valid domains accepted" {
    run is_valid_domain "example.com"; [ "$status" -eq 0 ]
    run is_valid_domain "sub.example.co.uk"; [ "$status" -eq 0 ]
    run is_valid_domain "www.microsoft.com"; [ "$status" -eq 0 ]
}

@test "invalid domains rejected" {
    run is_valid_domain ""; [ "$status" -ne 0 ]
    run is_valid_domain "-bad.com"; [ "$status" -ne 0 ]
    run is_valid_domain "no_tld"; [ "$status" -ne 0 ]
    run is_valid_domain "evil.com; rm -rf /"; [ "$status" -ne 0 ]
    run is_valid_domain "\$(whoami).com"; [ "$status" -ne 0 ]
}

@test "username validation" {
    run is_valid_username "alice"; [ "$status" -eq 0 ]
    run is_valid_username "alice.smith-01"; [ "$status" -eq 0 ]
    run is_valid_username "bad name"; [ "$status" -ne 0 ]
    run is_valid_username "bad;rm -rf"; [ "$status" -ne 0 ]
    run is_valid_username ""; [ "$status" -ne 0 ]
}

@test "http path validation" {
    run is_valid_http_path "/vless"; [ "$status" -eq 0 ]
    run is_valid_http_path "/a/b/c-1_2.3"; [ "$status" -eq 0 ]
    run is_valid_http_path "no-leading-slash"; [ "$status" -ne 0 ]
    run is_valid_http_path "/path with space"; [ "$status" -ne 0 ]
    run is_valid_http_path '/path"; DROP TABLE'; [ "$status" -ne 0 ]
}

@test "grpc service name validation" {
    run is_valid_service_name "vlessgrpc"; [ "$status" -eq 0 ]
    run is_valid_service_name "my.service-1"; [ "$status" -eq 0 ]
    run is_valid_service_name "bad name"; [ "$status" -ne 0 ]
    run is_valid_service_name ""; [ "$status" -ne 0 ]
}

@test "short id validation" {
    run is_valid_short_id ""; [ "$status" -eq 0 ]
    run is_valid_short_id "ab"; [ "$status" -eq 0 ]
    run is_valid_short_id "0123456789abcdef"; [ "$status" -eq 0 ]
    run is_valid_short_id "abc"; [ "$status" -ne 0 ]
    run is_valid_short_id "zz"; [ "$status" -ne 0 ]
}

@test "version_ge semver comparisons" {
    run version_ge "v26.3.27" "v26.3.27"; [ "$status" -eq 0 ]
    run version_ge "v26.3.28" "v26.3.27"; [ "$status" -eq 0 ]
    run version_ge "v26.3.27" "v26.3.28"; [ "$status" -ne 0 ]
    run version_ge "v2.0.0" "v1.9.9"; [ "$status" -eq 0 ]
}

@test "transport_security_compatible matrix" {
    run transport_security_compatible raw reality; [ "$status" -eq 0 ]
    run transport_security_compatible raw tls; [ "$status" -eq 0 ]
    run transport_security_compatible raw none; [ "$status" -eq 0 ]
    run transport_security_compatible xhttp reality; [ "$status" -eq 0 ]
    run transport_security_compatible grpc reality; [ "$status" -eq 0 ]
    run transport_security_compatible websocket reality; [ "$status" -ne 0 ]
    run transport_security_compatible httpupgrade reality; [ "$status" -ne 0 ]
    run transport_security_compatible mkcp reality; [ "$status" -ne 0 ]
    run transport_security_compatible websocket tls; [ "$status" -eq 0 ]
    run transport_security_compatible hysteria tls; [ "$status" -eq 0 ]
    run transport_security_compatible hysteria none; [ "$status" -ne 0 ]
    run transport_security_compatible hysteria reality; [ "$status" -ne 0 ]
}

@test "flow only compatible with raw+tls or raw+reality" {
    run flow_compatible raw tls; [ "$status" -eq 0 ]
    run flow_compatible raw reality; [ "$status" -eq 0 ]
    run flow_compatible raw none; [ "$status" -ne 0 ]
    run flow_compatible websocket tls; [ "$status" -ne 0 ]
    run flow_compatible xhttp reality; [ "$status" -ne 0 ]
    run flow_compatible grpc reality; [ "$status" -ne 0 ]
}
