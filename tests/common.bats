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

@test "validate_port enforces numeric range" {
    validate_port "1"
    validate_port "65535"
    ! validate_port "0"
    ! validate_port "65536"
    ! validate_port "not-a-port"
}

@test "validate_positive_int_range enforces bounds" {
    validate_positive_int_range "1232" 512 1400
    ! validate_positive_int_range "511" 512 1400
    ! validate_positive_int_range "1401" 512 1400
}

@test "username and password validators reject pipe characters" {
    validate_username "good-user"
    validate_password_no_pipe "safe-password"
    ! validate_username "bad|user"
    ! validate_password_no_pipe "bad|password"
}

@test "validate_log_file accepts ordinary paths" {
    validate_log_file "/var/log/dnstm-setup.log"
    validate_log_file "logs/dnstm-setup.log"
}

@test "validate_log_file rejects newline characters" {
    ! validate_log_file $'bad\npath.log'
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

@test "write_file_atomic skips rewriting unchanged content" {
    target="$(mktemp /tmp/dnstm-write.XXXXXX)"
    printf 'stable\n' >"$target"
    before_hash="$(sha256sum "$target" | awk '{print $1}')"

    write_file_atomic "$target" 0644 <<'EOF'
stable
EOF

    after_hash="$(sha256sum "$target" | awk '{print $1}')"
    [ "$before_hash" = "$after_hash" ]
}

@test "write_file_atomic respects dry-run mode" {
    target="/tmp/dnstm-dry-run-write-$$"
    rm -f "$target"
    DRY_RUN=true

    write_file_atomic "$target" 0644 <<'EOF'
dry-run
EOF

    [ ! -e "$target" ]
}

@test "dry-run mkdir wrapper does not create directories" {
    target="/tmp/dnstm-dry-run-$$"
    rm -rf "$target"
    DRY_RUN=true

    mkdir -p "$target"

    [ ! -d "$target" ]
}

@test "parse_tunnel_tags extracts both tagged and bare output formats" {
    sample_output=$'transport=dnstt tag=dnstt2 domain=d.example.com\nslip1 running domain=t.example.com\nnoise words'

    run parse_tunnel_tags "$sample_output"

    [ "$status" -eq 0 ]
    [ "$output" = $'dnstt2\nslip1' ]
}

@test "detect_next_tunnel_num increments from current tunnel list" {
    dnstm() {
        if [[ "$1" == "tunnel" && "$2" == "list" ]]; then
            printf 'tag=slip1\ntag=dnstt4\n'
            return 0
        fi
        return 1
    }

    run detect_next_tunnel_num

    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}
