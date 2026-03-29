#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.bash"

setup() {
    reset_test_runtime
}

@test "binary_matches_checksum succeeds for matching file content" {
    target="$(mktemp /tmp/dnstm-sha.XXXXXX)"
    printf 'checksum-test' >"$target"
    checksum="$(sha256sum "$target" | awk '{print $1}')"

    binary_matches_checksum "$target" "$checksum"
}

@test "binary_matches_checksum fails for mismatched checksum" {
    target="$(mktemp /tmp/dnstm-sha.XXXXXX)"
    printf 'checksum-test' >"$target"

    ! binary_matches_checksum "$target" "deadbeef"
}

@test "ensure_dnstt_server_binary reports unsupported arch cleanly" {
    ! ensure_dnstt_server_binary "armv7"
}
