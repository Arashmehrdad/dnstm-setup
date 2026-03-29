# shellcheck shell=bash

set -euo pipefail

if [[ -n "${DNSTM_DEPS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly DNSTM_DEPS_SH_LOADED=1

readonly DNSTM_VERSION_PIN="v0.6.8"
readonly SSHTUN_USER_VERSION_PIN="v0.3.5"
readonly DNSTT_VERSION_PIN="latest"
readonly NOIZDNS_VERSION_PIN="noizdns-v1.0"
readonly THREE_X_UI_VERSION_PIN="v2.8.11"
readonly XRAY_VERSION_PIN="v26.3.27"
readonly MICROSSOCKS_COMMIT_PIN="96bf8a87408c36951b73b7957687f42904e620f8"
readonly XRAY_INSTALL_COMMIT_PIN="e741a4f56d368afbb9e5be3361b40c4552d3710d"

readonly THREE_X_UI_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/${THREE_X_UI_VERSION_PIN}/install.sh"
readonly THREE_X_UI_INSTALL_SCRIPT_SHA256="ae80c79c01a0b6d8af8d120a0a5933c4aafd8680ad15a8422f7b384c7c1d31bd"
readonly XRAY_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_COMMIT_PIN}/install-release.sh"
readonly XRAY_INSTALL_SCRIPT_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"

declare -Ar DNSTM_BINARY_URLS=(
    [386]="https://github.com/net2share/dnstm/releases/download/${DNSTM_VERSION_PIN}/dnstm-linux-386"
    [amd64]="https://github.com/net2share/dnstm/releases/download/${DNSTM_VERSION_PIN}/dnstm-linux-amd64"
    [arm64]="https://github.com/net2share/dnstm/releases/download/${DNSTM_VERSION_PIN}/dnstm-linux-arm64"
    [armv7]="https://github.com/net2share/dnstm/releases/download/${DNSTM_VERSION_PIN}/dnstm-linux-armv7"
)
declare -Ar DNSTM_BINARY_SHA256=(
    [386]="065c73b8c25380d469f5b9e740019a50670e8c7842585c39f4e079bbae0fa6f0"
    [amd64]="c1333ef32a73da1034ad819859db358fd1fa741c04e237a0e3e51f10be7e2207"
    [arm64]="6f03cebc5e7120cfbea6cb803be3f91928be1074e32c484b26e0a15bddd7e47a"
    [armv7]="fa93d9dc1cef954f41a6f119ca0d4d4cb091601253ffc13d97c4c98968edefd4"
)

declare -Ar SSHTUN_USER_BINARY_URLS=(
    [386]="https://github.com/net2share/sshtun-user/releases/download/${SSHTUN_USER_VERSION_PIN}/sshtun-user-linux-386"
    [amd64]="https://github.com/net2share/sshtun-user/releases/download/${SSHTUN_USER_VERSION_PIN}/sshtun-user-linux-amd64"
    [arm64]="https://github.com/net2share/sshtun-user/releases/download/${SSHTUN_USER_VERSION_PIN}/sshtun-user-linux-arm64"
    [armv7]="https://github.com/net2share/sshtun-user/releases/download/${SSHTUN_USER_VERSION_PIN}/sshtun-user-linux-armv7"
)
declare -Ar SSHTUN_USER_BINARY_SHA256=(
    [386]="19f3a9c40f9379ffe9ffc9c6fc8dbff3e8024075eb28b3f04d514e29b56e9168"
    [amd64]="a84e1389120f35f92804953ac78ccb8c1fd28bfaec79f769ef0c5d3cde463160"
    [arm64]="8c89a78aeb47d0fff3100d8c4031727c41d44096b3eb6de5f8174e8ff8e58762"
    [armv7]="6e6ac7b59fd65ecd70ce3d0a2c3740c80054f86c07c3a8ff63133530991a7542"
)

declare -Ar DNSTT_SERVER_URLS=(
    [amd64]="https://github.com/net2share/dnstt/releases/download/${DNSTT_VERSION_PIN}/dnstt-server-linux-amd64"
    [arm64]="https://github.com/net2share/dnstt/releases/download/${DNSTT_VERSION_PIN}/dnstt-server-linux-arm64"
)
declare -Ar DNSTT_SERVER_SHA256=(
    [amd64]="265bad0988988fd6bf07c19c10d61d40c1f2e461080d6c81dbb5f2b1b3f8ae30"
    [arm64]="ac583639210db3a508988cb9b9858532899784e03fc225b5575a0ffe2bce5190"
)

declare -Ar NOIZDNS_BINARY_URLS=(
    [amd64]="https://github.com/SamNet-dev/dnstm-setup/releases/download/${NOIZDNS_VERSION_PIN}/noizdns-server-linux-amd64"
    [arm64]="https://github.com/SamNet-dev/dnstm-setup/releases/download/${NOIZDNS_VERSION_PIN}/noizdns-server-linux-arm64"
)
declare -Ar NOIZDNS_BINARY_SHA256=(
    [amd64]="f4525f780203c4c4a02fce08d8b3708bb86418bdbc877e6bc94141e3661718c0"
    [arm64]="1dacbab58b7a08a68768fa8734beb429f061224f32e588947191c526a2a2ab2f"
)

map_lookup() {
    local map_name="$1"
    local key="$2"
    local -n map_ref="$map_name"
    printf '%s' "${map_ref[$key]:-}"
}

sha256_of_file() {
    local path="$1"
    sha256sum "$path" | awk '{print $1}'
}

binary_matches_checksum() {
    local path="$1"
    local expected="$2"
    [[ -f "$path" ]] || return 1
    [[ -n "$expected" ]] || return 1
    [[ "$(sha256_of_file "$path")" == "$expected" ]]
}

download_and_verify() {
    local url="$1"
    local expected_sha="$2"
    local destination="$3"
    local label="$4"
    local tmp_file actual_sha

    if binary_matches_checksum "$destination" "$expected_sha"; then
        log_info "${label} already present with expected checksum"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "download ${label} from ${url} -> ${destination}"
        return 0
    fi

    tmp_file=$(mktemp "/tmp/${APP_NAME}.download.XXXXXX")
    log_info "Downloading ${label} from ${url}"
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp_file" "$url"; then
        command rm -f -- "$tmp_file"
        print_fail "Failed to download ${label}"
        return 1
    fi

    actual_sha=$(sha256_of_file "$tmp_file")
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        command rm -f -- "$tmp_file"
        print_fail "Checksum verification failed for ${label}"
        log_error "Expected ${expected_sha}, got ${actual_sha} for ${label}"
        return 1
    fi

    backup_path_for_rollback "$destination"
    ensure_directory "$(dirname -- "$destination")"
    command install -m 0755 -- "$tmp_file" "$destination"
    command rm -f -- "$tmp_file"
    log_info "Installed ${label} to ${destination}"
    return 0
}

fetch_verified_script() {
    local url="$1"
    local expected_sha="$2"
    local destination="$3"
    local label="$4"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "download ${label} script from ${url}"
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp "/tmp/${APP_NAME}.script.XXXXXX")
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp_file" "$url"; then
        command rm -f -- "$tmp_file"
        print_fail "Failed to download ${label} installer"
        return 1
    fi

    if [[ "$(sha256_of_file "$tmp_file")" != "$expected_sha" ]]; then
        command rm -f -- "$tmp_file"
        print_fail "Checksum verification failed for ${label} installer"
        return 1
    fi

    backup_path_for_rollback "$destination"
    command install -m 0755 -- "$tmp_file" "$destination"
    command rm -f -- "$tmp_file"
}

ensure_pinned_binary() {
    local arch="$1"
    local destination="$2"
    local map_urls="$3"
    local map_sha="$4"
    local label="$5"
    local url checksum

    url=$(map_lookup "$map_urls" "$arch")
    checksum=$(map_lookup "$map_sha" "$arch")
    if [[ -z "$url" || -z "$checksum" ]]; then
        print_fail "${label} is not available for architecture ${arch}"
        return 1
    fi

    download_and_verify "$url" "$checksum" "$destination" "$label"
}

ensure_dnstm_binary() {
    local arch="${1:-$(detect_architecture)}"
    ensure_pinned_binary "$arch" "/usr/local/bin/dnstm" DNSTM_BINARY_URLS DNSTM_BINARY_SHA256 "dnstm ${DNSTM_VERSION_PIN}"
}

ensure_sshtun_user_binary() {
    local arch="${1:-$(detect_architecture)}"
    ensure_pinned_binary "$arch" "/usr/local/bin/sshtun-user" SSHTUN_USER_BINARY_URLS SSHTUN_USER_BINARY_SHA256 "sshtun-user ${SSHTUN_USER_VERSION_PIN}"
}

ensure_dnstt_server_binary() {
    local arch="${1:-$(detect_architecture)}"
    if ! ensure_pinned_binary "$arch" "/usr/local/bin/dnstt-server" DNSTT_SERVER_URLS DNSTT_SERVER_SHA256 "dnstt-server ${DNSTT_VERSION_PIN}"; then
        print_warn "Pinned dnstt-server binary is unavailable for ${arch}"
        return 1
    fi
    return 0
}

detect_architecture() {
    local machine_arch
    machine_arch=$(uname -m)

    case "$machine_arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        i386|i686)
            echo "386"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv7)
            echo "armv7"
            ;;
        *)
            print_warn "Unsupported architecture: $machine_arch (defaulting to amd64)" >&2
            echo "amd64"
            ;;
    esac
}

fix_ssh_macs() {
    local sshd_config="/etc/ssh/sshd_config"
    [[ -f "$sshd_config" ]] || return 0

    if grep -qE '^MACs\s+.*etm@openssh\.com' "$sshd_config" 2>/dev/null && \
        ! grep -qE '^MACs\s+.*hmac-sha2-256[^-]' "$sshd_config" 2>/dev/null; then
        backup_path_for_rollback "$sshd_config"
        sed -i 's/^\(MACs\s\+.*\)$/\1,hmac-sha2-256,hmac-sha2-512/' "$sshd_config"
        if command_exists sshd && sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || ignore_failure
            print_ok "Added SSH MAC compatibility (non-ETM SHA2 fallbacks)"
        else
            run_rollback
            clear_rollback_stack
            print_warn "SSH MAC fix failed validation — reverted"
        fi
    fi
}

compile_microsocks_from_source() {
    local build_dir="/tmp/microsocks-build-$$"
    local lock_wait=0

    print_info "Compiling microsocks from source (GLIBC compatibility fix)..."

    if ! command_exists gcc || ! command_exists make; then
        print_info "Installing build tools (gcc, make, git)..."
        while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || \
            fuser /var/lib/apt/lists/lock &>/dev/null 2>&1 || \
            fuser /var/lib/dpkg/lock &>/dev/null 2>&1; do
            if (( lock_wait == 0 )); then
                print_info "Waiting for package manager lock (another process is running)..."
            fi
            sleep 2
            lock_wait=$((lock_wait + 2))
            if (( lock_wait >= 60 )); then
                print_warn "Package manager still locked after 60s — attempting recovery"
                pkill -f unattended-upgr 2>/dev/null || ignore_failure
                sleep 3
                dpkg --configure -a 2>/dev/null || ignore_failure
                break
            fi
        done
        dpkg --configure -a 2>/dev/null || ignore_failure
        apt-get update -qq 2>/dev/null || ignore_failure
        apt-get install -y -qq build-essential git 2>/dev/null || ignore_failure
    fi

    if ! command_exists gcc; then
        print_fail "Cannot install gcc — microsocks will not work"
        print_info "Try manually: apt install -y build-essential && re-run this script"
        return 1
    fi

    rm -rf "$build_dir"
    if ! git clone https://github.com/rofl0r/microsocks.git "$build_dir" >/dev/null 2>&1; then
        print_fail "Failed to clone microsocks source"
        rm -rf "$build_dir"
        return 1
    fi
    if ! git -C "$build_dir" checkout "$MICROSSOCKS_COMMIT_PIN" >/dev/null 2>&1; then
        print_fail "Failed to pin microsocks source to ${MICROSSOCKS_COMMIT_PIN}"
        rm -rf "$build_dir"
        return 1
    fi

    if ! make -C "$build_dir" >/dev/null 2>&1; then
        print_fail "Failed to compile microsocks"
        rm -rf "$build_dir"
        return 1
    fi

    if [[ ! -f "$build_dir/microsocks" ]]; then
        print_fail "microsocks binary not produced"
        rm -rf "$build_dir"
        return 1
    fi

    backup_path_for_rollback "/usr/local/bin/microsocks"
    systemctl stop microsocks 2>/dev/null || ignore_failure
    command install -m 0755 -- "$build_dir/microsocks" /usr/local/bin/microsocks
    rm -rf "$build_dir"
    systemctl reset-failed microsocks 2>/dev/null || ignore_failure
    systemctl daemon-reload 2>/dev/null || ignore_failure
    if systemctl start microsocks 2>/dev/null; then
        sleep 2
        if pgrep -x microsocks &>/dev/null; then
            print_ok "microsocks compiled from source and running"
            return 0
        fi
    fi

    print_fail "microsocks compiled but failed to start"
    return 1
}

microsocks_binary_works() {
    local bin="${1:-/usr/local/bin/microsocks}"
    [[ -x "$bin" ]] || return 1
    if ldd "$bin" 2>&1 | grep -qi "not found"; then
        return 1
    fi
    return 0
}

ensure_noizdns_binary() {
    local arch="${1:-$(detect_architecture)}"

    if binary_matches_checksum "/usr/local/bin/noizdns-server" "$(map_lookup NOIZDNS_BINARY_SHA256 "$arch")"; then
        return 0
    fi

    print_info "Downloading NoizDNS server (DPI-resistant tunnel)..."
    if ! ensure_pinned_binary "$arch" "/usr/local/bin/noizdns-server" NOIZDNS_BINARY_URLS NOIZDNS_BINARY_SHA256 "noizdns-server ${NOIZDNS_VERSION_PIN}"; then
        print_warn "Could not download pinned NoizDNS binary for ${arch}"
        return 1
    fi

    if command_exists file; then
        if ! file /usr/local/bin/noizdns-server 2>/dev/null | grep -qi "ELF"; then
            print_fail "NoizDNS binary failed ELF validation"
            return 1
        fi
    fi
    print_ok "NoizDNS server installed and verified"
}

sync_tree() {
    local src="$1"
    local dest="$2"
    local file relative target mode

    ensure_directory "$dest"
    while IFS= read -r -d '' file; do
        relative="${file#${src}/}"
        target="${dest}/${relative}"
        mode=0644
        if [[ -x "$file" ]]; then
            mode=0755
        fi
        sync_file "$file" "$target" "$mode"
    done < <(find "$src" -type f -print0)
}

write_path_wrappers() {
    write_file_atomic "$INSTALL_LINK" 0755 root root <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_ROOT}/bin/dnstm-setup" "\$@"
EOF
    write_file_atomic "$COMPAT_INSTALL_LINK" 0755 root root <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_LINK}" "\$@"
EOF
}

install_to_path() {
    ensure_directory "$INSTALL_ROOT"
    ensure_directory "$STATE_DIR" 0755 root root
    sync_tree "${PROJECT_ROOT}/bin" "${INSTALL_ROOT}/bin"
    sync_tree "${PROJECT_ROOT}/lib" "${INSTALL_ROOT}/lib"
    sync_tree "${PROJECT_ROOT}/docs" "${INSTALL_ROOT}/docs"
    sync_file "${PROJECT_ROOT}/README.md" "${INSTALL_ROOT}/README.md" 0644
    sync_file "${PROJECT_ROOT}/LICENSE" "${INSTALL_ROOT}/LICENSE" 0644
    [[ -f "${PROJECT_ROOT}/CONTRIBUTING.md" ]] && sync_file "${PROJECT_ROOT}/CONTRIBUTING.md" "${INSTALL_ROOT}/CONTRIBUTING.md" 0644
    [[ -f "${PROJECT_ROOT}/.editorconfig" ]] && sync_file "${PROJECT_ROOT}/.editorconfig" "${INSTALL_ROOT}/.editorconfig" 0644
    [[ -f "${PROJECT_ROOT}/.shellcheckrc" ]] && sync_file "${PROJECT_ROOT}/.shellcheckrc" "${INSTALL_ROOT}/.shellcheckrc" 0644
    [[ -f "${PROJECT_ROOT}/dnstm-setup.sh" ]] && sync_file "${PROJECT_ROOT}/dnstm-setup.sh" "${INSTALL_ROOT}/dnstm-setup.sh" 0755
    write_path_wrappers
    print_ok "Installed dnstm-setup to PATH (run 'dnstm-setup --manage' from anywhere)"
}

do_update() {
    local archive_file extract_dir staged_root marker_file

    print_header "Update dnstm-setup"
    print_info "Checking for updates..."

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "refresh installed tree from ${DEFAULT_REPO_ARCHIVE_URL}"
        return 0
    fi

    archive_file=$(mktemp "/tmp/${APP_NAME}.update.XXXXXX.tar.gz")
    extract_dir=$(mktemp -d "/tmp/${APP_NAME}.update.XXXXXX")
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$archive_file" "$DEFAULT_REPO_ARCHIVE_URL"; then
        command rm -f -- "$archive_file"
        command rm -rf -- "$extract_dir"
        print_fail "Could not reach GitHub. Check your internet connection."
        echo ""
        read -rp "  Press Enter to return to menu..." _
        return 1
    fi

    if ! tar -xzf "$archive_file" -C "$extract_dir"; then
        command rm -f -- "$archive_file"
        command rm -rf -- "$extract_dir"
        print_fail "Downloaded update archive is invalid"
        echo ""
        read -rp "  Press Enter to return to menu..." _
        return 1
    fi

    staged_root=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)
    if [[ -z "$staged_root" ]]; then
        command rm -f -- "$archive_file"
        command rm -rf -- "$extract_dir"
        print_fail "Could not locate extracted update contents"
        echo ""
        read -rp "  Press Enter to return to menu..." _
        return 1
    fi

    backup_path_for_rollback "$INSTALL_ROOT"
    ensure_directory "$INSTALL_ROOT"
    sync_tree "${staged_root}/bin" "${INSTALL_ROOT}/bin"
    sync_tree "${staged_root}/lib" "${INSTALL_ROOT}/lib"
    sync_tree "${staged_root}/docs" "${INSTALL_ROOT}/docs"
    sync_file "${staged_root}/README.md" "${INSTALL_ROOT}/README.md" 0644
    sync_file "${staged_root}/LICENSE" "${INSTALL_ROOT}/LICENSE" 0644
    [[ -f "${staged_root}/CONTRIBUTING.md" ]] && sync_file "${staged_root}/CONTRIBUTING.md" "${INSTALL_ROOT}/CONTRIBUTING.md" 0644
    [[ -f "${staged_root}/.editorconfig" ]] && sync_file "${staged_root}/.editorconfig" "${INSTALL_ROOT}/.editorconfig" 0644
    [[ -f "${staged_root}/.shellcheckrc" ]] && sync_file "${staged_root}/.shellcheckrc" "${INSTALL_ROOT}/.shellcheckrc" 0644
    [[ -f "${staged_root}/dnstm-setup.sh" ]] && sync_file "${staged_root}/dnstm-setup.sh" "${INSTALL_ROOT}/dnstm-setup.sh" 0755
    write_path_wrappers

    command rm -f -- "$archive_file"
    command rm -rf -- "$extract_dir"

    echo ""
    print_ok "Updated installed dnstm-setup tree."
    print_info "Restarting with the refreshed version..."
    echo ""
    sleep 1

    marker_file="/tmp/.dnstm-update-reexec"
    printf '%s\n' "$INSTALL_LINK" >"$marker_file"
    exit 0
}
