#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.bash"

setup() {
    reset_test_runtime
}

@test "validate_domain accepts a normal FQDN" {
    validate_domain "example.com"
}

@test "validate_domain rejects invalid input" {
    ! validate_domain "bad_domain"
}

@test "write_file_atomic replaces file content" {
    target="$(mktemp /tmp/dnstm-write.XXXXXX)"
    printf 'before\n' >"$target"

    write_file_atomic "$target" 0644 <<'EOF'
after
EOF

    run cat "$target"
    [ "$status" -eq 0 ]
    [ "$output" = "after" ]
}

@test "dry-run mkdir wrapper does not create directories" {
    target="/tmp/dnstm-dry-run-$$"
    rm -rf "$target"
    DRY_RUN=true

    mkdir -p "$target"

    [ ! -d "$target" ]
}
