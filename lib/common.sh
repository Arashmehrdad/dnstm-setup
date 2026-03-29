# shellcheck shell=bash

set -euo pipefail

if [[ -n "${DNSTM_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
readonly DNSTM_COMMON_SH_LOADED=1

readonly VERSION="1.3.1"
readonly TOTAL_STEPS=12
readonly APP_NAME="dnstm-setup"
readonly DEFAULT_BRANCH="master"
readonly DEFAULT_LOG_FILE="/var/log/dnstm-setup.log"
readonly DEFAULT_INSTALL_ROOT="/opt/dnstm-setup"
readonly DEFAULT_INSTALL_LINK="/usr/local/bin/dnstm-setup"
readonly DEFAULT_COMPAT_LINK="/usr/local/bin/dnstm-setup.sh"
readonly DEFAULT_STATE_DIR="/var/lib/dnstm-setup"
readonly DEFAULT_REPO_ARCHIVE_URL="https://codeload.github.com/SamNet-dev/dnstm-setup/tar.gz/${DEFAULT_BRANCH}"

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly PROJECT_ROOT
readonly LIB_DIR="${PROJECT_ROOT}/lib"
readonly BIN_DIR="${PROJECT_ROOT}/bin"
readonly DOCS_DIR="${PROJECT_ROOT}/docs"

LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
INSTALL_ROOT="${INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
INSTALL_LINK="${INSTALL_LINK:-$DEFAULT_INSTALL_LINK}"
COMPAT_INSTALL_LINK="${COMPAT_INSTALL_LINK:-$DEFAULT_COMPAT_LINK}"
STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
DEBUG_MODE=false
DRY_RUN=false
LOG_INITIALIZED=false
ROLLBACK_ACTIVE=true
DNS_CLEANUP_REQUESTED=false
SOCKS_AUTH=false
SOCKS_USER=""
SOCKS_PASS=""
DOMAIN=""
SERVER_IP=""

declare -ag ROLLBACK_STACK=()

log_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

format_command() {
    local formatted=()
    local arg
    for arg in "$@"; do
        formatted+=("$(printf '%q' "$arg")")
    done
    printf '%s' "${formatted[*]}"
}

log_message() {
    local level="$1"
    shift
    local message="$*"
    if [[ "$level" == "DEBUG" && "$DEBUG_MODE" != true ]]; then
        return 0
    fi
    if [[ "$LOG_INITIALIZED" != true ]]; then
        return 0
    fi
    printf '%s [%s] %s\n' "$(log_timestamp)" "$level" "$message" >>"$LOG_FILE"
}

log_debug() {
    log_message "DEBUG" "$@"
}

log_info() {
    log_message "INFO" "$@"
}

log_warn() {
    log_message "WARN" "$@"
}

log_error() {
    log_message "ERROR" "$@"
}

ignore_failure() {
    local status=$?
    local context="${1:-optional command}"

    if (( status != 0 )); then
        if [[ "$LOG_INITIALIZED" == true ]]; then
            log_debug "Ignoring non-fatal failure (${context}) with exit code ${status}"
        fi
    fi
    return 0
}

notify_console() {
    local level="$1"
    shift
    local message="$*"
    if declare -F "print_${level}" >/dev/null 2>&1; then
        "print_${level}" "$message"
        return 0
    fi
    printf '[%s] %s\n' "${level^^}" "$message" >&2
}

init_logging() {
    local requested="${LOG_FILE}"
    local log_dir

    if [[ "$requested" != /* ]]; then
        requested="${PWD}/${requested}"
    fi

    log_dir=$(dirname -- "$requested")
    if ! command mkdir -p -- "$log_dir" 2>/dev/null; then
        requested="/tmp/${APP_NAME}.log"
        log_dir=$(dirname -- "$requested")
        command mkdir -p -- "$log_dir"
    fi

    command touch -- "$requested"
    command chmod 600 -- "$requested" 2>/dev/null || ignore_failure "set log file permissions"
    LOG_FILE="$requested"
    LOG_INITIALIZED=true
    log_info "Initialized logging at ${LOG_FILE}"
}

register_rollback() {
    local action="$1"
    [[ -z "$action" ]] && return 0
    ROLLBACK_STACK+=("$action")
    log_debug "Registered rollback action: ${action}"
}

clear_rollback_stack() {
    ROLLBACK_STACK=()
}

backup_path_for_rollback() {
    local path="$1"
    local backup_root backup_path

    [[ "$ROLLBACK_ACTIVE" != true || "$DRY_RUN" == true ]] && return 0

    if [[ -e "$path" || -L "$path" ]]; then
        backup_root=$(mktemp -d "/tmp/${APP_NAME}-rollback.XXXXXX")
        backup_path="${backup_root}/$(basename -- "$path")"
        command cp -a -- "$path" "$backup_path"
        register_rollback "$(printf 'rm -rf -- %q && cp -a -- %q %q && rm -rf -- %q' "$path" "$backup_path" "$path" "$backup_root")"
    else
        register_rollback "$(printf 'rm -rf -- %q' "$path")"
    fi
}

run_rollback() {
    local index

    [[ "$ROLLBACK_ACTIVE" != true ]] && return 0
    if [[ "${#ROLLBACK_STACK[@]}" -eq 0 ]]; then
        log_warn "Rollback requested but stack is empty"
        return 0
    fi

    log_warn "Running rollback actions (${#ROLLBACK_STACK[@]})"
    for ((index = ${#ROLLBACK_STACK[@]} - 1; index >= 0; index--)); do
        log_warn "Rollback: ${ROLLBACK_STACK[index]}"
        bash -lc "${ROLLBACK_STACK[index]}" >>"$LOG_FILE" 2>&1 || log_error "Rollback action failed: ${ROLLBACK_STACK[index]}"
    done
}

on_exit_trap() {
    local exit_code=$?

    if (( exit_code != 0 )); then
        log_error "Installer exiting with status ${exit_code}"
        if [[ "$DRY_RUN" != true ]]; then
            run_rollback
        fi
    else
        log_info "Installer completed successfully"
    fi

    if [[ "$DNS_CLEANUP_REQUESTED" == true ]] && declare -F _dnstm_cleanup_dns >/dev/null 2>&1; then
        _dnstm_cleanup_dns || ignore_failure "cleanup temporary DNS settings"
    fi

    exit "$exit_code"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_domain() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    [[ "$candidate" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_port() {
    local candidate="$1"
    [[ "$candidate" =~ ^[0-9]+$ ]] || return 1
    (( candidate >= 1 && candidate <= 65535 ))
}

validate_positive_int_range() {
    local candidate="$1"
    local min="$2"
    local max="$3"
    [[ "$candidate" =~ ^[0-9]+$ ]] || return 1
    (( candidate >= min && candidate <= max ))
}

validate_username() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    [[ "$candidate" != *'|'* ]]
}

validate_password_no_pipe() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    [[ "$candidate" != *'|'* ]]
}

validate_log_file() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    case "$candidate" in
        *$'\n'*|*$'\r'*)
            return 1
            ;;
    esac
    return 0
}

fetch_public_ipv4() {
    local url
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me" \
        "https://icanhazip.com"; do
        if SERVER_IP=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null); then
            printf '%s\n' "$SERVER_IP"
            return 0
        fi
    done
    return 1
}

ensure_directory() {
    local path="$1"
    local mode="${2:-}"
    local owner="${3:-}"
    local group="${4:-}"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN mkdir -p ${path}"
        return 0
    fi

    if [[ ! -d "$path" ]]; then
        register_rollback "$(printf 'rmdir --ignore-fail-on-non-empty -- %q' "$path")"
    fi

    command mkdir -p -- "$path"
    [[ -n "$mode" ]] && command chmod "$mode" -- "$path"
    if [[ -n "$owner" || -n "$group" ]]; then
        command chown "${owner:-root}:${group:-root}" -- "$path"
    fi
}

write_file_atomic() {
    local path="$1"
    local mode="${2:-0644}"
    local owner="${3:-}"
    local group="${4:-}"
    local tmp_file

    tmp_file=$(mktemp "/tmp/${APP_NAME}.XXXXXX")
    cat >"$tmp_file"

    if [[ -f "$path" ]] && cmp -s -- "$tmp_file" "$path"; then
        command rm -f -- "$tmp_file"
        return 0
    fi

    log_debug "Atomic write prepared for ${path}"
    backup_path_for_rollback "$path"
    ensure_directory "$(dirname -- "$path")"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN write ${path}"
        command rm -f -- "$tmp_file"
        return 0
    fi

    command install -m "$mode" -- "$tmp_file" "$path"
    if [[ -n "$owner" || -n "$group" ]]; then
        command chown "${owner:-root}:${group:-root}" -- "$path"
    fi
    command rm -f -- "$tmp_file"
}

sync_file() {
    local src="$1"
    local dest="$2"
    local mode="${3:-0755}"

    if [[ -f "$dest" ]] && cmp -s -- "$src" "$dest"; then
        return 0
    fi

    backup_path_for_rollback "$dest"
    ensure_directory "$(dirname -- "$dest")"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN install ${src} -> ${dest}"
        return 0
    fi
    command install -m "$mode" -- "$src" "$dest"
}

dry_run_notice() {
    local message="$1"
    notify_console "info" "Dry-run: ${message}"
    log_info "DRY-RUN ${message}"
}

run_cmd() {
    local formatted
    formatted=$(format_command "$@")
    log_debug "Running: ${formatted}"
    "$@"
}

is_mutating_systemctl_command() {
    case "${1:-}" in
        start|stop|restart|try-restart|reload|enable|disable|mask|unmask|daemon-reload|reset-failed|link|preset|preset-all)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_mutating_apt_get_command() {
    case "${1:-}" in
        update|install|remove|purge|dist-upgrade|upgrade|autoremove|autoclean)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_mutating_dnstm_command() {
    case "${1:-}" in
        install|uninstall)
            return 0
            ;;
        router)
            case "${2:-}" in
                start|stop|restart)
                    return 0
                    ;;
            esac
            ;;
        tunnel)
            case "${2:-}" in
                add|remove|start|stop)
                    return 0
                    ;;
            esac
            ;;
        backend)
            [[ "${2:-}" == "auth" ]] && return 0
            ;;
    esac
    return 1
}

is_mutating_iptables_command() {
    local first="${1:-}"
    case "$first" in
        -L|-S|-n)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

is_mutating_ufw_command() {
    [[ "${1:-}" != "status" ]]
}

find_is_mutating() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -delete)
                return 0
                ;;
        esac
    done
    return 1
}

mkdir() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command mkdir "$@")"
        return 0
    fi
    command mkdir "$@"
}

rm() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command rm "$@")"
        return 0
    fi
    command rm "$@"
}

cp() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command cp "$@")"
        return 0
    fi
    command cp "$@"
}

mv() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command mv "$@")"
        return 0
    fi
    command mv "$@"
}

chmod() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command chmod "$@")"
        return 0
    fi
    command chmod "$@"
}

chown() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command chown "$@")"
        return 0
    fi
    command chown "$@"
}

chattr() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command chattr "$@")"
        return 0
    fi
    command chattr "$@"
}

install() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command install "$@")"
        return 0
    fi
    command install "$@"
}

ln() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command ln "$@")"
        return 0
    fi
    command ln "$@"
}

useradd() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "$(format_command useradd "$@")"
        return 0
    fi
    command useradd "$@"
}

apt-get() {
    if [[ "$DRY_RUN" == true ]] && is_mutating_apt_get_command "${1:-}"; then
        dry_run_notice "$(format_command apt-get "$@")"
        return 0
    fi
    command apt-get "$@"
}

systemctl() {
    if [[ "$DRY_RUN" == true ]] && is_mutating_systemctl_command "${1:-}"; then
        dry_run_notice "$(format_command systemctl "$@")"
        return 0
    fi
    command systemctl "$@"
}

dnstm() {
    if [[ "$DRY_RUN" == true ]] && is_mutating_dnstm_command "$@"; then
        dry_run_notice "$(format_command dnstm "$@")"
        return 0
    fi
    command dnstm "$@"
}

iptables() {
    if [[ "$DRY_RUN" == true ]] && is_mutating_iptables_command "$@"; then
        dry_run_notice "$(format_command iptables "$@")"
        return 0
    fi
    command iptables "$@"
}

ufw() {
    if [[ "$DRY_RUN" == true ]] && is_mutating_ufw_command "${1:-}"; then
        dry_run_notice "$(format_command ufw "$@")"
        return 0
    fi
    command ufw "$@"
}

find() {
    if [[ "$DRY_RUN" == true ]] && find_is_mutating "$@"; then
        dry_run_notice "$(format_command find "$@")"
        return 0
    fi
    command find "$@"
}

parse_tunnel_tags() {
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^tag=/) {
                    sub(/^tag=/, "", $i)
                    print $i
                    next
                }
                if ($i ~ /^(slip|dnstt|noiz|xray)[A-Za-z0-9_-]*$/) {
                    print $i
                    next
                }
            }
        }
    ' <<<"${1:-}" | sort -u
}

dnstm_tag_exists() {
    local tag="$1"
    local existing_tag
    while IFS= read -r existing_tag; do
        [[ "$existing_tag" == "$tag" ]] && return 0
    done < <(dnstm_get_tags)
    return 1
}

dnstm_get_tags() {
    local output
    output=$(dnstm tunnel list 2>/dev/null || ignore_failure)
    [[ -z "$output" ]] && return 0
    parse_tunnel_tags "$output"
}

dnstm_has_tunnels() {
    local output
    output=$(dnstm tunnel list 2>/dev/null || ignore_failure)
    [[ -n "$output" ]] || return 1
    [[ -n "$(parse_tunnel_tags "$output")" ]]
}

detect_socks_auth() {
    local status_output
    local detected_user
    local detected_pass

    status_output=$(timeout --kill-after=3 10 dnstm backend status -t socks 2>/dev/null || ignore_failure)
    detected_user=$(sed -n 's/^[[:space:]]*User:[[:space:]]*//p' <<<"$status_output" | sed 's/[[:space:]]*$//' | head -n1 || ignore_failure)
    detected_pass=$(sed -n 's/^[[:space:]]*Password:[[:space:]]*//p' <<<"$status_output" | sed 's/[[:space:]]*$//' | head -n1 || ignore_failure)

    if [[ -n "$detected_user" && -n "$detected_pass" ]]; then
        if ! validate_username "$detected_user" || ! validate_password_no_pipe "$detected_pass"; then
            SOCKS_AUTH=false
            SOCKS_USER=""
            SOCKS_PASS=""
            return 1
        fi
        SOCKS_AUTH=true
        SOCKS_USER="$detected_user"
        SOCKS_PASS="$detected_pass"
        return 0
    fi

    SOCKS_AUTH=false
    SOCKS_USER=""
    SOCKS_PASS=""
    return 1
}

generate_slipnet_url() {
    local tunnel_type="$1"
    local subdomain="$2"
    local pubkey="${3:-}"
    local ssh_user="${4:-}"
    local ssh_pass="${5:-}"
    local socks_user="${6:-}"
    local socks_pass="${7:-}"
    local name="${subdomain}.${DOMAIN}"
    local ns_domain="${subdomain}.${DOMAIN}"
    local resolver="8.8.8.8:53:0"
    local ssh_enabled="0"
    local ssh_port="22"
    local ssh_host="127.0.0.1"
    local auth_mode="0"
    local data

    if [[ -n "$ssh_user" && -n "$ssh_pass" ]]; then
        ssh_enabled="1"
    fi

    if [[ -n "$socks_user" && -n "$socks_pass" ]]; then
        auth_mode="1"
    fi

    data="16|${tunnel_type}|${name}|${ns_domain}|${resolver}|${auth_mode}|5000|bbr|1080|127.0.0.1|0|${pubkey}|${socks_user}|${socks_pass}|${ssh_enabled}|${ssh_user}|${ssh_pass}|${ssh_port}|0|${ssh_host}|0||udp|password|||0|0|443|||0||0|0|"
    echo "slipnet://$(printf '%s' "$data" | base64 -w0)"
}

detect_next_tunnel_num() {
    local max=1
    local num
    local tag
    while IFS= read -r tag; do
        num=$(sed -n 's/.*\([0-9][0-9]*\)$/\1/p' <<<"$tag" | head -n1 || ignore_failure)
        if [[ -n "$num" ]] && (( num >= max )); then
            max=$((num + 1))
        fi
    done < <(dnstm_get_tags)
    printf '%s\n' "$max"
}
