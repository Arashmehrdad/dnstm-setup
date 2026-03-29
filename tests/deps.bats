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

@test "detect_architecture maps common machine values" {
    uname() {
        printf 'x86_64\n'
    }
    run detect_architecture
    [ "$status" -eq 0 ]
    [ "$output" = "amd64" ]

    uname() {
        printf 'armv7l\n'
    }
    run detect_architecture
    [ "$status" -eq 0 ]
    [ "$output" = "armv7" ]
}

@test "detect_architecture falls back to amd64 for unknown values" {
    uname() {
        printf 'mips64\n'
    }

    run detect_architecture

    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "amd64" ]
}

@test "download_and_verify is side-effect free in dry-run mode" {
    target="/tmp/dnstm-download-dry-run-$$"
    rm -f "$target"
    DRY_RUN=true

    download_and_verify "https://example.invalid/file" "deadbeef" "$target" "demo-binary"

    [ ! -e "$target" ]
}

@test "ensure_dnstt_server_binary reports unsupported arch cleanly" {
    ! ensure_dnstt_server_binary "armv7"
}
