# shellcheck shell=bash

set -euo pipefail

if [[ -n "${DNSTM_TUNNELS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly DNSTM_TUNNELS_SH_LOADED=1

do_configure_socks_auth() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip SOCKS5 authentication changes"
        return 0
    fi

    banner
    print_header "Configure SOCKS5 Authentication"

    if [[ $EUID -ne 0 ]]; then
        print_fail "Not running as root."
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed."
        exit 1
    fi

    # Show current state
    echo ""
    detect_socks_auth || ignore_failure
    if [[ "$SOCKS_AUTH" == true ]]; then
        echo -e "  ${BOLD}Current status:${NC} ${GREEN}Enabled${NC}"
        echo -e "  ${DIM}Username: ${SOCKS_USER}${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC}  Change credentials"
        echo -e "  ${BOLD}2)${NC}  Disable authentication"
        echo -e "  ${BOLD}0)${NC}  Cancel"
        echo ""
        local choice=""
        read -rp "  Select [0-2]: " choice || exit 0
        case "$choice" in
            1)
                echo ""
                ;;
            2)
                echo ""
                print_info "Disabling SOCKS5 authentication..."
                if dnstm backend auth -t socks --disable; then
                    print_ok "SOCKS5 authentication disabled"
                    sleep 2
                    if pgrep -x microsocks &>/dev/null || systemctl is-active --quiet microsocks 2>/dev/null; then
                        print_ok "microsocks restarted without authentication"
                    else
                        print_warn "microsocks may not have restarted — check: systemctl status microsocks"
                    fi
                else
                    print_fail "Failed to disable authentication"
                fi
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
    else
        echo -e "  ${BOLD}Current status:${NC} ${RED}Disabled (open proxy)${NC}"
        echo ""
        if ! prompt_yn "Enable SOCKS5 authentication?" "y"; then
            print_info "Cancelled."
            exit 0
        fi
        echo ""
    fi

    # Collect credentials
    local new_user new_pass
    new_user=$(prompt_input "Enter SOCKS proxy username" "proxy")
    new_user=$(echo "$new_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$new_user" ]]; then
        print_fail "Username cannot be empty"
        exit 1
    fi
    if [[ "$new_user" == *"|"* || "$new_user" == *":"* ]]; then
        print_fail "Username cannot contain | or : characters"
        exit 1
    fi

    new_pass=$(prompt_input "Enter SOCKS proxy password")
    new_pass=$(echo "$new_pass" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$new_pass" ]]; then
        print_fail "Password cannot be empty"
        exit 1
    fi
    if [[ "$new_pass" == *"|"* ]]; then
        print_fail "Password cannot contain the | character"
        exit 1
    fi

    echo ""
    print_info "Applying SOCKS5 authentication..."
    if dnstm backend auth -t socks -u "$new_user" -p "$new_pass"; then
        print_ok "SOCKS5 authentication enabled (user: ${new_user})"
        sleep 2
        if pgrep -x microsocks &>/dev/null || systemctl is-active --quiet microsocks 2>/dev/null; then
            print_ok "microsocks restarted with authentication"
        else
            print_warn "microsocks may not have restarted — check: systemctl status microsocks"
        fi

        # Verify auth enforcement
        local socks_port=""
        socks_port=$(ss -tlnp 2>/dev/null | grep microsocks | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) {split($i,a,":"); print a[length(a)]; exit}}' || ignore_failure)
        if [[ -z "$socks_port" ]]; then
            socks_port="19801"
        fi
        local noauth_test
        noauth_test=$(curl -s --max-time 5 --socks5 "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null || ignore_failure)
        if [[ -z "$noauth_test" ]]; then
            print_ok "Auth enforced: unauthenticated connections are rejected"
        else
            print_warn "Auth NOT enforced: proxy still works without credentials!"
            print_info "Try restarting: systemctl restart microsocks"
        fi
    else
        print_fail "Failed to configure SOCKS5 authentication"
        print_info "Try manually: dnstm backend auth -t socks -u ${new_user} -p <password>"
    fi
}

# ─── --status ───────────────────────────────────────────────────────────────────

do_status() {
    banner

    # Warn if not root (ss -p and file reads may not work)
    if [[ $EUID -ne 0 ]]; then
        print_warn "Running without root — some info may be unavailable"
        echo ""
    fi

    # Check dnstm is installed
    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the full setup first: sudo bash $0"
        exit 1
    fi

    # Save/restore global DOMAIN so generate_slipnet_url() can read it
    local _saved_domain="$DOMAIN"

    # Detect server IP
    local server_ip
    server_ip=$(fetch_public_ipv4 2>/dev/null || ignore_failure)
    if [[ -n "$server_ip" ]]; then
        echo -e "  ${BOLD}Server IP:${NC} ${GREEN}${server_ip}${NC}"
    fi
    echo ""

    # ─── Cache tunnel list output (reused throughout) ───
    local tunnel_list_output
    tunnel_list_output=$(timeout --kill-after=3 10 dnstm tunnel list 2>/dev/null || ignore_failure)

    echo -e "  ${BOLD}Tunnel Status${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    if [[ -n "$tunnel_list_output" ]]; then
        echo "$tunnel_list_output"
    else
        print_warn "Could not get tunnel list"
    fi
    echo ""

    # ─── Detect SOCKS auth via dnstm ───
    detect_socks_auth || ignore_failure
    local socks_user="$SOCKS_USER" socks_pass="$SOCKS_PASS" socks_auth="$SOCKS_AUTH"

    echo -e "  ${BOLD}SOCKS Proxy Authentication${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    if [[ "$socks_auth" == true ]]; then
        echo -e "  Username:  ${GREEN}${socks_user}${NC}"
        echo -e "  Password:  ${GREEN}${socks_pass}${NC}"
    else
        echo -e "  ${YELLOW}No authentication (open proxy)${NC}"
    fi
    echo ""

    # ─── Detect microsocks port ───
    local socks_port=""
    socks_port=$(ss -tlnp 2>/dev/null | grep microsocks | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) {split($i,a,":"); print a[length(a)]; exit}}' || ignore_failure)
    if [[ -z "$socks_port" ]]; then
        socks_port=$(sed -n 's/.*-p[[:space:]]*\([0-9]*\).*/\1/p' /etc/systemd/system/microsocks.service 2>/dev/null | head -1 || ignore_failure)
    fi
    if [[ -n "$socks_port" ]]; then
        echo -e "  ${BOLD}microsocks Port:${NC} ${GREEN}${socks_port}${NC}"
        echo ""
    fi

    # ─── Collect all tunnel tags and their domains ───
    local tags
    tags=$(echo "$tunnel_list_output" | grep -oE 'tag=[^ ]+' | sed 's/tag=//' || ignore_failure)
    # Fallback: extract known tag patterns if tag= format not found
    if [[ -z "$tags" ]] && [[ -n "$tunnel_list_output" ]]; then
        tags=$(echo "$tunnel_list_output" | grep -oE '\b(slip|dnstt|noiz|xray)[a-z0-9_-]*' | sort -u || ignore_failure)
    fi
    if [[ -z "$tags" ]]; then
        print_warn "No tunnels found"
        return
    fi

    # ─── Detect SSH users (check if sshtun-user is available) ───
    local ssh_user="" ssh_pass=""
    local has_ssh_users=false
    if command -v sshtun-user &>/dev/null; then
        local user_list
        user_list=$(timeout --kill-after=3 10 sshtun-user list </dev/null 2>/dev/null || ignore_failure)
        # Fallback: sshtun-user list may require TTY
        if [[ -z "$user_list" ]]; then
            user_list=$(awk -F: '/SSH tunnel only/{print $1}' /etc/passwd 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$user_list" ]]; then
            has_ssh_users=true
            echo -e "  ${BOLD}SSH Tunnel Users${NC}"
            echo -e "  ${DIM}────────────────────────────────────────${NC}"
            echo "$user_list" | while IFS= read -r line; do
                echo -e "  ${GREEN}${line}${NC}"
            done
            echo ""
        fi
    fi
    # Check and auto-fix sshd reachability (needed for SSH tunnels)
    if [[ "$has_ssh_users" == true ]]; then
        if ! timeout 3 bash -c 'echo | nc -w2 127.0.0.1 22' &>/dev/null; then
            echo -e "  ${YELLOW}[!] sshd not reachable on 127.0.0.1:22 — fixing...${NC}"
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || ignore_failure
            if command -v iptables &>/dev/null; then
                iptables -I INPUT -i lo -p tcp --dport 22 -j ACCEPT 2>/dev/null || ignore_failure
            fi
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
                ufw allow from 127.0.0.1 to any port 22 2>/dev/null || ignore_failure
            fi
            sleep 1
            if timeout 3 bash -c 'echo | nc -w2 127.0.0.1 22' &>/dev/null; then
                echo -e "  ${GREEN}[+] sshd fixed — now reachable on 127.0.0.1:22${NC}"
            else
                echo -e "  ${RED}[x] sshd still not reachable — SSH tunnels will NOT work${NC}"
                echo -e "  ${DIM}Check: sudo iptables -L -n | grep 22${NC}"
            fi
            echo ""
        fi
    fi
    # Read stored SSH credentials for URL generation
    if [[ -f /etc/dnstm/ssh-credentials ]]; then
        ssh_user=$(cut -d: -f1 /etc/dnstm/ssh-credentials 2>/dev/null || ignore_failure)
        ssh_pass=$(cut -d: -f2- /etc/dnstm/ssh-credentials 2>/dev/null || ignore_failure)
    fi

    # ─── Share URLs — dnst:// ───
    echo -e "  ${BOLD}Share URLs — dnst:// (for dnstc CLI)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local share_url
    for tag in $tags; do
        # SOCKS tunnels — no SSH credentials needed
        if echo "$tag" | grep -qE '^(slip[0-9]+|dnstt[0-9]+|noiz[0-9]+)$'; then
            share_url=$(timeout --kill-after=3 10 dnstm tunnel share -t "$tag" 2>/dev/null || ignore_failure)
            if [[ -n "$share_url" ]]; then
                echo -e "  ${GREEN}${tag}:${NC}"
                echo "  ${share_url}"
                echo ""
            fi
        fi
    done
    # SSH tunnels — need credentials
    local ssh_tags
    ssh_tags=$(echo "$tags" | grep -E 'ssh' || ignore_failure)
    if [[ -n "$ssh_tags" ]]; then
        if [[ "$has_ssh_users" == true ]]; then
            echo -e "  ${DIM}SSH tunnel share URLs require credentials:${NC}"
            for tag in $ssh_tags; do
                echo -e "  ${DIM}  dnstm tunnel share -t ${tag} --user <username> --password <pass>${NC}"
            done
        else
            echo -e "  ${YELLOW}SSH tunnels: no users configured — create one with: sshtun-user create <user> --insecure-password <pass>${NC}"
        fi
        echo ""
    fi

    # ─── Share URLs — slipnet:// ───
    # We need the domain for each tunnel to generate slipnet:// URLs
    echo -e "  ${BOLD}Share URLs — slipnet:// (for SlipNet app)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"

    local s_user="" s_pass=""
    if [[ "$socks_auth" == true ]]; then
        s_user="$socks_user"
        s_pass="$socks_pass"
    fi

    # Pre-load domain map from dnstm config.json (most reliable source)
    local _dnstm_config="/etc/dnstm/config.json"
    local _domain_map=""
    if [[ -f "$_dnstm_config" ]]; then
        if command -v jq &>/dev/null; then
            _domain_map=$(jq -r '.tunnels[]? | "\(.tag)=\(.domain)"' "$_dnstm_config" 2>/dev/null || ignore_failure)
        elif command -v python3 &>/dev/null; then
            _domain_map=$(python3 -c '
import sys, json
try:
    cfg = json.load(sys.stdin)
    for t in cfg.get("tunnels", []):
        tag, domain = t.get("tag",""), t.get("domain","")
        if tag and domain: print(f"{tag}={domain}")
except: pass
' < "$_dnstm_config" 2>/dev/null || ignore_failure)
        fi
    fi

    for tag in $tags; do
        # Extract domain for this tunnel from dnstm
        local tag_domain
        tag_domain=$(echo "$tunnel_list_output" | grep -wF "$tag" | grep -oE 'domain=[^ ]+' | head -1 | sed 's/domain=//' || ignore_failure)
        # Fallback: parse table format (TAG TRANSPORT BACKEND PORT DOMAIN STATUS)
        if [[ -z "$tag_domain" ]]; then
            tag_domain=$(echo "$tunnel_list_output" | awk -v t="$tag" '$1 == t {for(i=2;i<=NF;i++) if($i ~ /\./) {print $i; exit}}' || ignore_failure)
        fi
        # Fallback: read domain from dnstm config.json
        if [[ -z "$tag_domain" && -n "$_domain_map" ]]; then
            tag_domain=$(echo "$_domain_map" | grep "^${tag}=" | head -1 | sed 's/^[^=]*=//' || ignore_failure)
        fi
        if [[ -z "$tag_domain" ]]; then
            continue
        fi

        # Extract base domain (strip subdomain prefix)
        DOMAIN=$(echo "$tag_domain" | sed 's/^[^.]*\.//')
        local subdomain
        subdomain=$(echo "$tag_domain" | sed 's/\..*//')

        # Get DNSTT pubkey — required by SlipNet for ALL tunnel types
        local pubkey=""
        if [[ -f "/etc/dnstm/tunnels/${tag}/server.pub" ]]; then
            pubkey=$(cat "/etc/dnstm/tunnels/${tag}/server.pub" 2>/dev/null || ignore_failure)
        fi
        # Slipstream tunnels don't have server.pub — grab any available dnstt pubkey
        if [[ -z "$pubkey" ]]; then
            pubkey=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
        fi

        local url=""
        case "$tag" in
            slip[0-9]*)
                url=$(generate_slipnet_url "ss" "$subdomain" "$pubkey" "" "" "$s_user" "$s_pass")
                ;;
            dnstt[0-9]*)
                if [[ -n "$pubkey" ]]; then
                    url=$(generate_slipnet_url "dnstt" "$subdomain" "$pubkey" "" "" "$s_user" "$s_pass")
                fi
                ;;
            slip-ssh*)
                if [[ -n "$ssh_user" && -n "$ssh_pass" ]]; then
                    url=$(generate_slipnet_url "slipstream_ssh" "$subdomain" "$pubkey" "$ssh_user" "$ssh_pass" "$s_user" "$s_pass")
                elif [[ "$has_ssh_users" == true ]]; then
                    echo -e "  ${DIM}${tag}: regenerate with — sudo bash $0 --users (option 5)${NC}"
                    continue
                else
                    echo -e "  ${DIM}${tag}: create SSH user first — sudo bash $0 --users${NC}"
                    continue
                fi
                ;;
            dnstt-ssh*)
                if [[ -n "$ssh_user" && -n "$ssh_pass" ]]; then
                    url=$(generate_slipnet_url "dnstt_ssh" "$subdomain" "$pubkey" "$ssh_user" "$ssh_pass" "$s_user" "$s_pass")
                elif [[ "$has_ssh_users" == true ]]; then
                    echo -e "  ${DIM}${tag}: regenerate with — sudo bash $0 --users (option 5)${NC}"
                    continue
                else
                    echo -e "  ${DIM}${tag}: create SSH user first — sudo bash $0 --users${NC}"
                    continue
                fi
                ;;
            xray*)
                if [[ -n "$pubkey" ]]; then
                    url=$(generate_slipnet_url "dnstt" "$subdomain" "$pubkey" "" "" "$s_user" "$s_pass")
                fi
                ;;
            noiz[0-9]*)
                if [[ -n "$pubkey" ]]; then
                    url=$(generate_slipnet_url "sayedns" "$subdomain" "$pubkey" "" "" "$s_user" "$s_pass")
                fi
                ;;
            noiz-ssh*)
                if [[ -n "$ssh_user" && -n "$ssh_pass" ]]; then
                    url=$(generate_slipnet_url "sayedns_ssh" "$subdomain" "$pubkey" "$ssh_user" "$ssh_pass" "$s_user" "$s_pass")
                elif [[ "$has_ssh_users" == true ]]; then
                    echo -e "  ${DIM}${tag}: regenerate with — sudo bash $0 --users (option 5)${NC}"
                    continue
                else
                    echo -e "  ${DIM}${tag}: create SSH user first — sudo bash $0 --users${NC}"
                    continue
                fi
                ;;
        esac

        if [[ -n "$url" ]]; then
            echo -e "  ${GREEN}${tag}:${NC}"
            echo "  ${url}"
            echo ""
        fi
    done

    # ─── Xray Tunnel Info (if configured) ───
    if [[ -d /etc/dnstm/xray ]] && ls /etc/dnstm/xray/*.conf >/dev/null 2>&1; then
        echo -e "  ${BOLD}Xray Backend Tunnels${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        local xconf
        for xconf in /etc/dnstm/xray/*.conf; do
            local XRAY_TAG="" XRAY_PORT="" XRAY_PROTOCOL="" XRAY_UUID="" XRAY_PASSWORD="" XRAY_PANEL="" XRAY_DOMAIN=""
            # shellcheck disable=SC1090
            source "$xconf"
            echo -e "  Tag:       ${GREEN}${XRAY_TAG}${NC}"
            echo -e "  Protocol:  ${GREEN}${XRAY_PROTOCOL}${NC}"
            echo -e "  Domain:    ${GREEN}${XRAY_DOMAIN}${NC}"
            echo -e "  Port:      ${GREEN}${XRAY_PORT}${NC} ${DIM}(127.0.0.1)${NC}"
            echo -e "  Panel:     ${GREEN}${XRAY_PANEL}${NC}"

            # Generate client URI
            local xcred=""
            if [[ -n "$XRAY_UUID" ]]; then
                xcred="$XRAY_UUID"
            else
                xcred="$XRAY_PASSWORD"
            fi
            if [[ -n "$xcred" ]]; then
                # Use 127.0.0.1 — client connects through DNSTT tunnel, traffic exits on server localhost
                local xuri
                xuri=$(generate_xray_client_uri "$XRAY_PROTOCOL" "127.0.0.1" "$XRAY_PORT" "$xcred" "DNSTT-${XRAY_PROTOCOL}")
                echo -e "  URI:       ${GREEN}${xuri}${NC}"
            fi
            echo ""
        done
    fi

    echo -e "  ${BOLD}DNS Resolvers (use in SlipNet)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "  8.8.8.8:53        (Google)"
    echo "  1.1.1.1:53        (Cloudflare)"
    echo "  9.9.9.9:53        (Quad9)"
    echo "  208.67.222.222:53 (OpenDNS)"
    echo ""

    # Restore global DOMAIN
    DOMAIN="$_saved_domain"
}

# ─── --monitor ─────────────────────────────────────────────────────────────────

do_monitor() {
    banner

    if [[ $EUID -ne 0 ]]; then
        print_warn "Running without root — some info may be unavailable"
        echo ""
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the full setup first: sudo bash $0"
        exit 1
    fi

    local tunnel_list_output
    tunnel_list_output=$(timeout --kill-after=3 10 dnstm tunnel list 2>/dev/null || ignore_failure)

    if [[ -z "$tunnel_list_output" ]]; then
        print_warn "No tunnels found"
        return
    fi

    # ─── Tunnel process stats ───
    echo -e "  ${BOLD}Tunnel Process Stats${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    printf "  ${BOLD}%-16s %-10s %-8s %-10s %-10s %-s${NC}\n" "TAG" "PID" "CPU%" "MEM(MB)" "UPTIME" "STATUS"
    echo -e "  ${DIM}$(printf '%.0s─' {1..76})${NC}"

    # Extract tags from tunnel list
    local tags
    tags=$(echo "$tunnel_list_output" | grep -oE 'tag=[^ ]+' | sed 's/tag=//' || ignore_failure)
    if [[ -z "$tags" ]]; then
        tags=$(echo "$tunnel_list_output" | grep -oE '\b(slip|dnstt|noiz|xray)[a-z0-9_-]*' | sort -u || ignore_failure)
    fi

    # Pre-fetch constants used in the loop (avoid forking per tunnel)
    local _clk_tck _boot_time_s _now_s
    _clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
    _boot_time_s=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null || ignore_failure)
    _now_s=$(date +%s)

    local total_conns=0 total_mem=0
    for tag in $tags; do
        local pid="" cpu="" mem_kb="" mem_mb="" uptime="" status=""

        # Check if tunnel is running from the list output
        local tag_line
        tag_line=$(echo "$tunnel_list_output" | grep -wF "$tag" | head -1)
        if echo "$tag_line" | grep -qi "stopped\|inactive"; then
            printf "  %-16s %-10s %-8s %-10s %-10s ${RED}%s${NC}\n" "$tag" "-" "-" "-" "-" "Stopped"
            continue
        fi

        # Find PID: look for process with this tag in its command line
        pid=$(pgrep -f "tag[= ]${tag}" 2>/dev/null | head -1 || ignore_failure)
        if [[ -z "$pid" ]]; then
            pid=$(systemctl show "dnstm-tunnel-${tag}" --property=MainPID 2>/dev/null | sed 's/MainPID=//' || ignore_failure)
            [[ "$pid" == "0" ]] && pid=""
        fi

        if [[ -n "$pid" ]]; then
            # Single ps call for both CPU and memory
            read -r cpu mem_kb <<< "$(ps -p "$pid" -o %cpu=,rss= 2>/dev/null || ignore_failure)"
            if [[ -n "$mem_kb" && "$mem_kb" -gt 0 ]] 2>/dev/null; then
                local _m=$((mem_kb * 10 / 1024)); mem_mb="$((_m / 10)).$((_m % 10))"
                total_mem=$((total_mem + mem_kb))
            else
                mem_mb="-"
            fi

            # Get uptime from /proc (uses pre-fetched constants)
            if [[ -f "/proc/${pid}/stat" && -n "$_boot_time_s" ]]; then
                local start_time elapsed_s
                start_time=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || ignore_failure)
                if [[ -n "$start_time" ]]; then
                    elapsed_s=$(( _now_s - (_boot_time_s + start_time / _clk_tck) ))
                    [[ $elapsed_s -lt 0 ]] && elapsed_s=0
                    if [[ $elapsed_s -ge 86400 ]]; then
                        uptime="$((elapsed_s / 86400))d $((elapsed_s % 86400 / 3600))h"
                    elif [[ $elapsed_s -ge 3600 ]]; then
                        uptime="$((elapsed_s / 3600))h $((elapsed_s % 3600 / 60))m"
                    else
                        uptime="$((elapsed_s / 60))m $((elapsed_s % 60))s"
                    fi
                fi
            fi
            [[ -z "$uptime" ]] && uptime="-"
            [[ -z "$cpu" ]] && cpu="-"
            printf "  %-16s %-10s %-8s %-10s %-10s ${GREEN}%s${NC}\n" "$tag" "$pid" "$cpu" "$mem_mb" "$uptime" "Running"
        else
            if echo "$tag_line" | grep -qi "running"; then
                printf "  %-16s %-10s %-8s %-10s %-10s ${YELLOW}%s${NC}\n" "$tag" "?" "-" "-" "-" "Running (no PID)"
            else
                printf "  %-16s %-10s %-8s %-10s %-10s ${RED}%s${NC}\n" "$tag" "-" "-" "-" "-" "Unknown"
            fi
        fi
    done
    echo ""

    # ─── Active connections (single ss calls, cached) ───
    echo -e "  ${BOLD}Active Connections${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"

    local ss_tcp_output ss_listen_output ss_udp_output
    ss_listen_output=$(ss -tlnp 2>/dev/null || ignore_failure)
    ss_tcp_output=$(ss -tnp 2>/dev/null || ignore_failure)
    ss_udp_output=$(ss -unp 2>/dev/null || ignore_failure)

    # Count SOCKS proxy connections (microsocks)
    local socks_port=""
    socks_port=$(echo "$ss_listen_output" | grep microsocks | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) {split($i,a,":"); print a[length(a)]; exit}}' || ignore_failure)
    if [[ -n "$socks_port" ]]; then
        local socks_conns
        socks_conns=$(echo "$ss_tcp_output" | grep ":${socks_port}\b" | grep -c "ESTAB" || ignore_failure)
        echo -e "  SOCKS proxy (port ${socks_port}):  ${GREEN}${socks_conns:-0}${NC} active connections"
        total_conns=$((total_conns + ${socks_conns:-0}))
    fi

    # Count SSH tunnel connections
    local ssh_conns
    ssh_conns=$(echo "$ss_tcp_output" | grep ":22\b" | grep -c "ESTAB" || ignore_failure)
    if [[ "${ssh_conns:-0}" -gt 0 ]]; then
        echo -e "  SSH tunnels (port 22):     ${GREEN}${ssh_conns}${NC} active connections"
        total_conns=$((total_conns + ssh_conns))
    fi

    # DNS listener (port 53)
    local dns_conns
    dns_conns=$(echo "$ss_udp_output" | grep -c ":53\b" || ignore_failure)
    if [[ "${dns_conns:-0}" -gt 0 ]]; then
        echo -e "  DNS listener (port 53):    ${GREEN}${dns_conns}${NC} UDP sessions"
    fi

    echo -e "  ${DIM}──────────────────────────${NC}"
    echo -e "  Total:                     ${BOLD}${total_conns}${NC} TCP connections"
    echo ""

    # ─── Memory summary ───
    if [[ $total_mem -gt 0 ]]; then
        local _tm=$((total_mem * 10 / 1024)); local total_mem_mb="$((_tm / 10)).$((_tm % 10))"
        echo -e "  ${BOLD}Total tunnel memory:${NC} ${GREEN}${total_mem_mb} MB${NC}"
        echo ""
    fi

    # ─── Recent tunnel logs ───
    echo -e "  ${BOLD}Recent Tunnel Activity (last 20 lines)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local has_logs=false
    if command -v journalctl &>/dev/null; then
        local log_output
        log_output=$(journalctl -u 'dnstm*' --no-pager -n 20 --no-hostname 2>/dev/null || ignore_failure)
        if [[ -n "$log_output" && "$log_output" != *"No entries"* && "$log_output" != *"-- No entries --"* ]]; then
            echo "$log_output" | while IFS= read -r line; do
                echo -e "  ${DIM}${line}${NC}"
            done
            has_logs=true
        fi
    fi
    if [[ "$has_logs" == false ]]; then
        echo -e "  ${DIM}No recent logs available${NC}"
        echo -e "  ${DIM}Try: dnstm tunnel logs --tag <tag>${NC}"
    fi
    echo ""

    echo -e "  ${DIM}Tip: Run with watch for live monitoring:${NC}"
    echo -e "  ${DIM}  watch -n 5 sudo bash $0 --monitor${NC}"
    echo ""
}

# ─── SlipNet URL Generator ────────────────────────────────────────────────────

# Generate a slipnet:// deep-link URL for the SlipNet Android app.
# Usage: generate_slipnet_url <tunnel_type> <subdomain> [pubkey] [ssh_user] [ssh_pass] [socks_user] [socks_pass]
#   tunnel_type: "ss", "dnstt", "sayedns", "slipstream_ssh", "dnstt_ssh", or "sayedns_ssh" (SlipNet constants)
#   subdomain:   e.g. "t" or "d"
#   pubkey:      DNSTT public key (required for dnstt, empty for slipstream)
#   ssh_user:    SSH tunnel username (optional)
#   ssh_pass:    SSH tunnel password (optional)

fix_noizdns_transport() {
    local config="/etc/dnstm/config.json"
    [[ -f "$config" ]] || return 0
    command -v jq &>/dev/null || return 0

    # Detect if this version of dnstm supports "noizdns" transport
    local supports_noizdns=false
    if dnstm tunnel add --help 2>&1 | grep -qi "noizdns" || \
       dnstm --help 2>&1 | grep -qi "noizdns"; then
        supports_noizdns=true
    else
        # Quick probe: try creating a test config in memory to see if router accepts noizdns
        local test_config='{"tunnels":[{"tag":"_test","transport":"noizdns","backend":"socks","domain":"test.example.com","port":9999}]}'
        if echo "$test_config" | dnstm router validate 2>&1 | grep -qi "valid" 2>/dev/null; then
            supports_noizdns=true
        fi
    fi

    local changed=false
    local tmp_config="${config}.tmp.$$"

    if [[ "$supports_noizdns" == true ]]; then
        # Newer dnstm: noiz tunnels should have transport "noizdns"
        if jq -e '.tunnels[]? | select(.tag | test("^noiz")) | select(.transport == "dnstt")' "$config" &>/dev/null; then
            if jq '(.tunnels[]? | select(.tag | test("^noiz")) | select(.transport == "dnstt") | .transport) = "noizdns"' "$config" > "$tmp_config" 2>/dev/null; then
                backup_path_for_rollback "$config"
                mv "$tmp_config" "$config"
                changed=true
                print_ok "Fixed NoizDNS tunnel transport in dnstm config (dnstt → noizdns)"
            else
                rm -f "$tmp_config"
            fi
        fi
    else
        # Older dnstm: noiz tunnels must stay as "dnstt" (router doesn't know noizdns)
        if jq -e '.tunnels[]? | select(.tag | test("^noiz")) | select(.transport == "noizdns")' "$config" &>/dev/null; then
            if jq '(.tunnels[]? | select(.tag | test("^noiz")) | select(.transport == "noizdns") | .transport) = "dnstt"' "$config" > "$tmp_config" 2>/dev/null; then
                backup_path_for_rollback "$config"
                mv "$tmp_config" "$config"
                changed=true
                print_ok "Fixed NoizDNS tunnel transport in dnstm config (noizdns → dnstt for older dnstm)"
            else
                rm -f "$tmp_config"
            fi
        fi
    fi
}

# Override a DNSTT tunnel's systemd service to use the NoizDNS binary instead.
# NoizDNS does NOT support -udp flag — it uses Pluggable Transport (PT) mode
# with TOR_PT_* environment variables for bind address and upstream.
# Usage: create_noizdns_service_override <tag>

create_noizdns_service_override() {
    local tag="$1"
    local service="dnstm-${tag}.service"
    local dropin_dir="/etc/systemd/system/${service}.d"
    local dropin_file="${dropin_dir}/10-noizdns-binary.conf"

    # Read original ExecStart to extract port, key, MTU, domain, upstream
    local orig_exec
    orig_exec=$(systemctl cat "$service" 2>/dev/null | grep '^ExecStart=/' | head -1 || ignore_failure)
    if [[ -z "$orig_exec" ]]; then
        orig_exec=$(systemctl cat "$service" 2>/dev/null | grep '^ExecStart=.*dnstt-server' | tail -1 || ignore_failure)
    fi
    if [[ -z "$orig_exec" ]]; then
        print_fail "Could not read ExecStart from ${service}"
        return 1
    fi

    # Extract components from original ExecStart
    # Original: /path/dnstt-server -udp :5300 -privkey-file KEY [-mtu MTU] DOMAIN UPSTREAM
    local tunnel_port privkey_path mtu_val domain upstream

    # Extract -udp port (e.g., ":5300" or "5300")
    tunnel_port=$(echo "$orig_exec" | grep -oE '\-udp[[:space:]]+[^ ]+' | grep -oE '[0-9]+$' || ignore_failure)
    if [[ -z "$tunnel_port" ]]; then
        print_fail "Could not detect tunnel port from ${service}"
        return 1
    fi

    # Extract -privkey-file path
    privkey_path=$(echo "$orig_exec" | grep -oE '\-privkey-file\s+[^ ]+' | sed 's/-privkey-file\s*//' || ignore_failure)
    if [[ -z "$privkey_path" ]]; then
        privkey_path="/etc/dnstm/tunnels/${tag}/server.key"
    fi

    # Extract -mtu value (optional)
    mtu_val=$(echo "$orig_exec" | grep -oE '\-mtu\s+[0-9]+' | grep -oE '[0-9]+' || ignore_failure)
    local mtu_arg=""
    if [[ -n "$mtu_val" ]]; then
        mtu_arg=" -mtu ${mtu_val}"
    fi

    # Extract domain and upstream (last two positional args)
    # Strip all flags and their values, leaving just positional args
    local positional
    positional=$(echo "$orig_exec" | sed 's|^ExecStart=[^ ]*||; s|-udp[[:space:]]*[^ ]*||; s|-privkey-file[[:space:]]*[^ ]*||; s|-mtu[[:space:]]*[0-9]*||' | xargs || ignore_failure)
    domain=$(echo "$positional" | awk '{print $1}')
    upstream=$(echo "$positional" | awk '{print $2}')

    if [[ -z "$domain" || -z "$upstream" ]]; then
        print_fail "Could not parse domain/upstream from ${service}"
        return 1
    fi

    if ! mkdir -p "$dropin_dir" 2>/dev/null; then
        print_fail "Could not create drop-in directory: ${dropin_dir}"
        return 1
    fi

    # Write PT-mode drop-in (NoizDNS uses TOR_PT_* env vars instead of -udp flag)
    write_file_atomic "$dropin_file" 0644 root root <<EOF || { print_fail "Could not write NoizDNS override: ${dropin_file}"; return 1; }
[Service]
ExecStart=
ExecStart=/usr/local/bin/noizdns-server -privkey-file ${privkey_path}${mtu_arg} ${domain}
Environment=TOR_PT_MANAGED_TRANSPORT_VER=1
Environment=TOR_PT_SERVER_TRANSPORTS=dnstt
Environment=TOR_PT_SERVER_BINDADDR=dnstt-0.0.0.0:${tunnel_port}
Environment=TOR_PT_ORPORT=${upstream}
EOF
    print_ok "NoizDNS binary override (PT mode): ${service}"
}

# Main Xray backend integration function

do_remove_tunnel() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip tunnel removal"
        return 0
    fi

    local target_tag="$1"
    banner

    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${CROSS} Not running as root. Please run with: sudo bash $0 --remove-tunnel <tag>"
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Nothing to remove."
        exit 1
    fi

    # Cache tunnel list output (reused throughout)
    local tunnel_output
    tunnel_output=$(dnstm tunnel list 2>/dev/null || ignore_failure)

    # Show current tunnels
    print_header "Remove Tunnel"
    echo ""
    print_info "Current tunnels:"
    echo ""
    echo "$tunnel_output"
    echo ""

    # If no tag given, ask interactively
    if [[ -z "$target_tag" ]]; then
        local tags
        tags=$(echo "$tunnel_output" | grep -oE 'tag=[^ ]+' | sed 's/tag=//' || ignore_failure)
        [[ -z "$tags" && -n "$tunnel_output" ]] && \
            tags=$(echo "$tunnel_output" | grep -oE '\b(slip|dnstt|noiz|xray)[a-z0-9_-]*' | sort -u || ignore_failure)
        if [[ -z "$tags" ]]; then
            print_warn "No tunnels found."
            exit 0
        fi

        # Show numbered list
        local i=1
        local tag_arr=()
        for tag in $tags; do
            local domain_info
            domain_info=$(echo "$tunnel_output" | grep -wF "$tag" | grep -oE 'domain=[^ ]+' | head -1 | sed 's/domain=//' || ignore_failure)
            echo -e "  ${BOLD}${i})${NC}  ${tag}  ${DIM}(${domain_info})${NC}"
            tag_arr+=("$tag")
            i=$((i + 1))
        done
        echo -e "  ${BOLD}0)${NC}  Cancel"
        echo ""

        local choice
        choice=$(prompt_input "Select tunnel to remove (1-${#tag_arr[@]})")
        if [[ "$choice" == "0" || -z "$choice" ]]; then
            print_info "Cancelled."
            exit 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#tag_arr[@]} ]]; then
            target_tag="${tag_arr[$((choice - 1))]}"
        else
            print_fail "Invalid selection."
            exit 1
        fi
    fi

    # Verify tunnel exists
    if ! echo "$tunnel_output" | grep -qwF "${target_tag}"; then
        print_fail "Tunnel '${target_tag}' not found."
        echo ""
        print_info "Available tunnels:"
        local _avail_tags
        _avail_tags=$(echo "$tunnel_output" | grep -oE 'tag=[^ ]+' | sed 's/tag=//' || ignore_failure)
        [[ -z "$_avail_tags" && -n "$tunnel_output" ]] && \
            _avail_tags=$(echo "$tunnel_output" | grep -oE '\b(slip|dnstt|noiz|xray)[a-z0-9_-]*' | sort -u || ignore_failure)
        echo "$_avail_tags" | sed 's/^/  /' || ignore_failure
        exit 1
    fi

    local domain_info
    domain_info=$(echo "$tunnel_output" | grep -wF "$target_tag" | grep -oE 'domain=[^ ]+' | head -1 | sed 's/domain=//' || ignore_failure)

    echo ""
    if ! prompt_yn "Remove tunnel '${target_tag}' (${domain_info})?" "n"; then
        print_info "Cancelled."
        exit 0
    fi

    echo ""

    # Stop the tunnel
    print_info "Stopping tunnel: ${target_tag}..."
    if dnstm tunnel stop --tag "$target_tag" 2>/dev/null; then
        print_ok "Stopped: ${target_tag}"
    else
        print_warn "Stop command failed (tunnel may already be stopped)"
    fi

    # Remove the tunnel
    print_info "Removing tunnel: ${target_tag}..."
    if dnstm tunnel remove --tag "$target_tag" 2>/dev/null; then
        print_ok "Removed: ${target_tag}"
    else
        print_warn "Remove command returned an error (tunnel may already be gone)"
    fi

    # Clean up Xray config and systemd drop-in if this was an xray tunnel
    if [[ "$target_tag" == xray* ]]; then
        rm -f "/etc/dnstm/xray/${target_tag}.conf" 2>/dev/null || ignore_failure
        rm -f "/etc/systemd/system/dnstm-${target_tag}.service.d/10-xray-upstream.conf" 2>/dev/null || ignore_failure
        rmdir "/etc/systemd/system/dnstm-${target_tag}.service.d" 2>/dev/null || ignore_failure
        systemctl daemon-reload 2>/dev/null || ignore_failure
        print_ok "Cleaned up Xray config for ${target_tag}"
        print_warn "Note: The Xray inbound in your panel was NOT removed. Delete it manually if needed."
    fi

    # Clean up NoizDNS systemd drop-in if this was a noiz tunnel
    if [[ "$target_tag" == noiz* ]]; then
        rm -f "/etc/systemd/system/dnstm-${target_tag}.service.d/10-noizdns-binary.conf" 2>/dev/null || ignore_failure
        rmdir "/etc/systemd/system/dnstm-${target_tag}.service.d" 2>/dev/null || ignore_failure
        systemctl daemon-reload 2>/dev/null || ignore_failure
        print_ok "Cleaned up NoizDNS override for ${target_tag}"
    fi

    # Restart router only if tunnels remain
    local remaining
    if dnstm_has_tunnels; then
        print_info "Restarting DNS Router..."
        dnstm router stop 2>/dev/null || ignore_failure
        sleep 1
        if dnstm router start 2>/dev/null; then
            print_ok "DNS Router restarted"
        else
            print_warn "DNS Router restart may have issues. Check: dnstm router logs"
        fi
        echo ""
        print_info "Remaining tunnels:"
        echo ""
        dnstm tunnel list 2>/dev/null || ignore_failure
    else
        dnstm router stop 2>/dev/null || ignore_failure
        print_info "No tunnels remaining — DNS Router stopped"
    fi
    echo ""
    print_ok "Tunnel '${target_tag}' removed."
    echo ""
}

# ─── --add-tunnel ────────────────────────────────────────────────────────────────

do_add_tunnel() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip standalone tunnel creation"
        return 0
    fi

    banner

    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${CROSS} Not running as root. Please run with: sudo bash $0 --add-tunnel"
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the full setup first: sudo bash $0"
        exit 1
    fi

    print_header "Add Single Tunnel"

    # Show current tunnels
    echo ""
    print_info "Current tunnels:"
    echo ""
    dnstm tunnel list 2>/dev/null || print_info "(none)"
    echo ""

    # Detect server IP
    SERVER_IP=$(fetch_public_ipv4 2>/dev/null || ignore_failure)
    if [[ -n "$SERVER_IP" ]]; then
        print_ok "Server IP: ${SERVER_IP}"
    fi
    echo ""

    # 1. Choose transport
    echo -e "  ${BOLD}Transport:${NC}"
    echo -e "  ${BOLD}1)${NC}  Slipstream  ${DIM}(QUIC + TLS, faster ~63 KB/s)${NC}"
    echo -e "  ${BOLD}2)${NC}  DNSTT       ${DIM}(Noise + Curve25519, ~42 KB/s)${NC}"
    echo -e "  ${BOLD}3)${NC}  NoizDNS     ${DIM}(DPI-resistant DNSTT fork)${NC}"
    echo ""
    local transport_choice
    transport_choice=$(prompt_input "Select transport (1-3)" "1")
    local transport
    local use_noizdns=false
    case "$transport_choice" in
        1) transport="slipstream" ;;
        2) transport="dnstt" ;;
        3)
            transport="dnstt"
            use_noizdns=true
            # Ensure noizdns binary is available
            if ! ensure_noizdns_binary; then
                print_fail "NoizDNS binary not available. Cannot create NoizDNS tunnel."
                exit 1
            fi
            ;;
        *)
            print_fail "Invalid selection. Use 1, 2, or 3."
            exit 1
            ;;
    esac
    print_ok "Transport: ${transport}$( [[ "$use_noizdns" == true ]] && echo ' (NoizDNS)' )"
    echo ""

    # 2. Choose backend
    echo -e "  ${BOLD}Backend:${NC}"
    echo -e "  ${BOLD}1)${NC}  SOCKS  ${DIM}(connects to microsocks proxy)${NC}"
    echo -e "  ${BOLD}2)${NC}  SSH    ${DIM}(connects via SSH port forwarding, requires SSH user)${NC}"
    echo ""
    local backend_choice
    backend_choice=$(prompt_input "Select backend (1-2)" "1")
    local backend
    case "$backend_choice" in
        1) backend="socks" ;;
        2) backend="ssh" ;;
        *)
            print_fail "Invalid selection. Use 1 or 2."
            exit 1
            ;;
    esac
    print_ok "Backend: ${backend}"
    echo ""

    # 3. Get domain
    local domain
    domain=$(prompt_input "Enter the full tunnel domain (e.g. t.example.com)")
    domain=$(echo "$domain" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||;s|^https\?://||;s|/.*$||')
    if [[ -z "$domain" || ! "$domain" == *.*.* ]]; then
        print_fail "Invalid domain. Must be a subdomain (e.g. t.example.com, not example.com)"
        exit 1
    fi
    print_ok "Domain: ${domain}"
    echo ""

    # 4. Get tag
    local tag
    tag=$(prompt_input "Enter a unique tag for this tunnel (e.g. slip1, dnstt2, my-tunnel)")
    tag=$(echo "$tag" | sed 's|[[:space:]]||g')
    if [[ -z "$tag" ]]; then
        print_fail "Tag cannot be empty."
        exit 1
    fi
    # Check if tag already exists
    if dnstm_tag_exists "$tag"; then
        print_fail "Tunnel with tag '${tag}' already exists. Choose a different tag."
        exit 1
    fi
    print_ok "Tag: ${tag}"
    echo ""

    # 5. MTU for DNSTT
    local mtu_flag=""
    if [[ "$transport" == "dnstt" ]]; then
        local mtu_input
        mtu_input=$(prompt_input "DNSTT MTU size (512-1400)" "$DNSTT_MTU")
        if [[ "$mtu_input" =~ ^[0-9]+$ ]] && [[ "$mtu_input" -ge 512 ]] && [[ "$mtu_input" -le 1400 ]]; then
            mtu_flag="--mtu $mtu_input"
            print_ok "MTU: ${mtu_input}"
        else
            print_warn "Invalid MTU; using default ${DNSTT_MTU}"
            mtu_flag="--mtu $DNSTT_MTU"
        fi
        echo ""
    fi

    # Confirm
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Creating tunnel:${NC}"
    echo -e "  Transport: ${GREEN}${transport}${NC}"
    echo -e "  Backend:   ${GREEN}${backend}${NC}"
    echo -e "  Domain:    ${GREEN}${domain}${NC}"
    echo -e "  Tag:       ${GREEN}${tag}${NC}"
    echo ""

    if ! prompt_yn "Create this tunnel?" "y"; then
        print_info "Cancelled."
        exit 0
    fi

    echo ""

    # Create the tunnel
    print_info "Creating tunnel: ${tag}..."
    local create_output
    # shellcheck disable=SC2086
    create_output=$(dnstm tunnel add --transport "$transport" --backend "$backend" --domain "$domain" --tag "$tag" $mtu_flag 2>&1) || ignore_failure
    echo "$create_output"

    if dnstm_tag_exists "$tag"; then
        print_ok "Created: ${tag}"
    else
        print_fail "Tunnel creation may have failed. Check output above."
        exit 1
    fi

    # Apply NoizDNS override if selected
    if [[ "$use_noizdns" == true ]]; then
        create_noizdns_service_override "$tag" || print_warn "Could not set NoizDNS binary for ${tag}"
        # Stop tunnel so it restarts with noizdns-server binary
        systemctl stop "dnstm-${tag}.service" 2>/dev/null || ignore_failure
        systemctl daemon-reload 2>/dev/null || ignore_failure
    fi

    # Show DNSTT pubkey if applicable
    if [[ "$transport" == "dnstt" && -f "/etc/dnstm/tunnels/${tag}/server.pub" ]]; then
        local pubkey
        pubkey=$(cat "/etc/dnstm/tunnels/${tag}/server.pub" 2>/dev/null || ignore_failure)
        if [[ -n "$pubkey" ]]; then
            echo ""
            echo -e "  ${BOLD}${YELLOW}DNSTT Public Key (save this!):${NC}"
            echo -e "  ${GREEN}${pubkey}${NC}"
        fi
    fi

    echo ""

    # Start the tunnel
    print_info "Starting tunnel: ${tag}..."
    if dnstm tunnel start --tag "$tag" 2>/dev/null; then
        print_ok "Started: ${tag}"
    else
        print_warn "Could not start tunnel. Check: dnstm tunnel logs --tag ${tag}"
    fi

    # Restart router to pick up new config
    print_info "Restarting DNS Router..."
    dnstm router stop 2>/dev/null || ignore_failure
    sleep 1
    if dnstm router start 2>/dev/null; then
        print_ok "DNS Router restarted"
    else
        print_warn "DNS Router restart may have issues. Check: dnstm router logs"
    fi

    echo ""

    # Show share URLs
    local subdomain
    subdomain=$(echo "$domain" | sed 's/\..*//')
    local base_domain
    base_domain=$(echo "$domain" | sed 's/^[^.]*\.//')

    echo -e "  ${BOLD}Share URL — dnst:// (for dnstc CLI)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local share_url
    share_url=$(dnstm tunnel share -t "$tag" 2>/dev/null || ignore_failure)
    if [[ -n "$share_url" ]]; then
        echo -e "  ${share_url}"
    else
        print_info "Share URL not available (generate later with: dnstm tunnel share -t ${tag})"
    fi
    echo ""

    # Generate slipnet:// URL for non-SSH tunnels
    if [[ "$backend" == "socks" ]]; then
        # Detect existing SOCKS auth via dnstm
        detect_socks_auth || ignore_failure
        local s_user="$SOCKS_USER" s_pass="$SOCKS_PASS"

        local pubkey_for_url=""
        if [[ "$transport" == "dnstt" && -f "/etc/dnstm/tunnels/${tag}/server.pub" ]]; then
            pubkey_for_url=$(cat "/etc/dnstm/tunnels/${tag}/server.pub" 2>/dev/null || ignore_failure)
        fi

        local slipnet_type
        case "$transport" in
            slipstream) slipnet_type="ss" ;;
            dnstt) slipnet_type="dnstt" ;;
        esac
        # NoizDNS tunnels use dnstt transport but need sayedns type for SlipNet
        [[ "$use_noizdns" == true || "$tag" == noiz* ]] && slipnet_type="sayedns"

        DOMAIN="$base_domain"
        local slipnet_url
        slipnet_url=$(generate_slipnet_url "$slipnet_type" "$subdomain" "$pubkey_for_url" "" "" "$s_user" "$s_pass")
        echo -e "  ${BOLD}Share URL — slipnet:// (for SlipNet app)${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${slipnet_url}"
        echo ""
    else
        echo -e "  ${DIM}slipnet:// URL for SSH tunnels requires credentials.${NC}"
        echo -e "  ${DIM}Use --status after creating an SSH user to see all share URLs.${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}Required DNS Record${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Make sure this NS record exists in Cloudflare for ${GREEN}${base_domain}${NC}:"
    echo ""
    echo -e "  Type: ${GREEN}NS${NC}  |  Name: ${GREEN}${subdomain}${NC}  |  Target: ${GREEN}ns.${base_domain}${NC}"
    echo ""

    print_info "All tunnels:"
    echo ""
    dnstm tunnel list 2>/dev/null || ignore_failure
    echo ""
    print_ok "Tunnel '${tag}' added."
    echo ""
}

# ─── --uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip uninstall"
        return 0
    fi

    banner

    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${CROSS} Not running as root. Please run with: sudo bash $0 --uninstall"
        exit 1
    fi

    print_header "Uninstall DNS Tunnel Setup"

    echo -e "  ${YELLOW}This will remove all DNS tunnel components from this server.${NC}"
    echo ""
    echo "  Components to remove:"
    echo "    - All dnstm tunnels and router"
    echo "    - dnstm binary and configuration"
    echo "    - sshtun-user binary (if installed)"
    echo "    - microsocks service"
    echo ""

    if ! prompt_yn "Are you sure you want to uninstall everything?" "n"; then
        echo ""
        print_info "Uninstall cancelled."
        exit 0
    fi

    echo ""

    # Stop and remove tunnels
    if command -v dnstm &>/dev/null; then
        print_info "Stopping tunnels..."
        local tags
        tags=$(dnstm_get_tags)
        for tag in $tags; do
            dnstm tunnel stop --tag "$tag" 2>/dev/null && print_ok "Stopped tunnel: $tag" || ignore_failure
        done

        print_info "Stopping router..."
        dnstm router stop 2>/dev/null && print_ok "Router stopped" || ignore_failure

        print_info "Removing tunnels..."
        for tag in $tags; do
            dnstm tunnel remove --tag "$tag" 2>/dev/null && print_ok "Removed tunnel: $tag" || ignore_failure
        done

        print_info "Uninstalling dnstm..."
        dnstm uninstall 2>/dev/null && print_ok "dnstm uninstalled" || print_warn "dnstm uninstall returned an error (may already be removed)"
    else
        print_info "dnstm not found, skipping tunnel cleanup"
    fi

    # Remove binaries
    if [[ -f /usr/local/bin/dnstm ]]; then
        rm -f /usr/local/bin/dnstm
        print_ok "Removed /usr/local/bin/dnstm"
    fi

    if [[ -f /usr/local/bin/sshtun-user ]]; then
        rm -f /usr/local/bin/sshtun-user
        print_ok "Removed /usr/local/bin/sshtun-user"
    fi

    if [[ -f /usr/local/bin/noizdns-server ]]; then
        rm -f /usr/local/bin/noizdns-server
        print_ok "Removed /usr/local/bin/noizdns-server"
    fi

    if [[ -f /usr/local/bin/dnstm-setup ]]; then
        rm -f /usr/local/bin/dnstm-setup
        print_ok "Removed /usr/local/bin/dnstm-setup"
    fi

    if [[ -f /usr/local/bin/dnstm-setup.sh ]]; then
        rm -f /usr/local/bin/dnstm-setup.sh
        print_ok "Removed /usr/local/bin/dnstm-setup.sh"
    fi

    if [[ -d /opt/dnstm-setup ]]; then
        rm -rf /opt/dnstm-setup
        print_ok "Removed /opt/dnstm-setup"
    fi

    # Stop microsocks
    if systemctl is-active --quiet microsocks 2>/dev/null; then
        systemctl stop microsocks 2>/dev/null || ignore_failure
        systemctl disable microsocks 2>/dev/null || ignore_failure
        print_ok "Stopped and disabled microsocks"
    fi

    # Remove config directory (includes /etc/dnstm/xray/)
    if [[ -d /etc/dnstm ]]; then
        rm -rf /etc/dnstm
        print_ok "Removed /etc/dnstm (including Xray tunnel configs)"
    fi

    # Remove systemd overrides (hardening + xray upstream drop-ins)
    find /etc/systemd/system -maxdepth 2 -type f -name '20-hardening.conf' -path '*/dnstm-*.service.d/*' -delete 2>/dev/null || ignore_failure
    find /etc/systemd/system -maxdepth 2 -type f -name '10-xray-upstream.conf' -path '*/dnstm-*.service.d/*' -delete 2>/dev/null || ignore_failure
    find /etc/systemd/system -maxdepth 2 -type f -name '10-noizdns-binary.conf' -path '*/dnstm-*.service.d/*' -delete 2>/dev/null || ignore_failure
    rm -f /etc/systemd/system/microsocks.service.d/20-hardening.conf 2>/dev/null || ignore_failure
    systemctl daemon-reload 2>/dev/null || ignore_failure
    print_ok "Removed local service hardening drop-ins"

    # Remove resolver override used to free port 53
    rm -f /etc/systemd/resolved.conf.d/10-dnstm-no-stub.conf 2>/dev/null || ignore_failure

    # Unlock resolv.conf so the system can manage DNS again
    chattr -i /etc/resolv.conf 2>/dev/null || ignore_failure
    print_ok "Removed immutable flag from /etc/resolv.conf"

    systemctl unmask systemd-resolved.socket systemd-resolved.service 2>/dev/null || ignore_failure
    systemctl enable systemd-resolved.service 2>/dev/null || ignore_failure
    systemctl restart systemd-resolved.service 2>/dev/null || ignore_failure
    sleep 1
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || ignore_failure
    fi
    # Ensure DNS works after uninstall — if resolv.conf is broken, write fallback
    if ! getent hosts google.com >/dev/null 2>&1 && \
       ! curl -sf --max-time 3 https://api.ipify.org >/dev/null 2>&1; then
        print_warn "DNS not working after restore — writing fallback nameservers"
        write_public_dns_resolver_file /etc/resolv.conf
    fi
    print_ok "Restored systemd-resolved defaults (best effort)"

    echo ""
    print_ok "${GREEN}Uninstall complete.${NC}"
    echo ""
    print_warn "Note: DNS records in Cloudflare were NOT removed. Remove them manually if needed."
    print_warn "Note: Xray/3x-ui panel was NOT removed (only DNSTT tunnel configs were cleaned up)."
    echo ""
}

# ─── Architecture Detection ────────────────────────────────────────────────────

do_manage_users() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip SSH tunnel user management"
        return 0
    fi

    banner
    print_header "SSH Tunnel User Management"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        print_fail "Not running as root. Please run with: sudo bash $0 --users"
        exit 1
    fi

    # Install sshtun-user if not present
    if ! command -v sshtun-user &>/dev/null; then
        print_info "sshtun-user not found. Installing..."
        local arch
        arch=$(detect_architecture)
        if ensure_sshtun_user_binary "$arch"; then
            print_ok "Installed pinned sshtun-user for ${arch}"
        else
            print_fail "Failed to install pinned sshtun-user for ${arch} architecture."
            exit 1
        fi

        # Run initial configure
        print_info "Applying SSH security configuration..."
        mkdir -p /run/sshd 2>/dev/null || ignore_failure
        # Back up sshd_config before modification
        if [[ -f /etc/ssh/sshd_config ]]; then
            cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.dnstm-backup 2>/dev/null || ignore_failure
        fi
        if timeout --kill-after=3 30 sshtun-user configure </dev/null 2>&1; then
            print_ok "SSH configuration applied"
        else
            print_warn "SSH configuration may not have applied fully — user management may have issues"
        fi
        # Validate sshd_config — rollback if broken
        if command -v sshd &>/dev/null && ! sshd -t 2>/dev/null; then
            print_warn "sshd_config validation failed — rolling back"
            if [[ -f /etc/ssh/sshd_config.dnstm-backup ]]; then
                cp -f /etc/ssh/sshd_config.dnstm-backup /etc/ssh/sshd_config
                print_ok "Restored sshd_config from backup"
            fi
        fi
        # Fix ETM-only MACs for client compatibility (Bitvise, older clients)
        fix_ssh_macs
        echo ""
    fi

    while true; do
        echo ""
        echo -e "  ${BOLD}SSH Tunnel User Management${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BOLD}1${NC}  List users"
        echo -e "  ${BOLD}2${NC}  Add user"
        echo -e "  ${BOLD}3${NC}  Change password"
        echo -e "  ${BOLD}4${NC}  Delete user"
        echo -e "  ${BOLD}5${NC}  Regenerate SSH share URLs"
        echo -e "  ${BOLD}0${NC}  Exit"
        echo ""

        local choice=""
        read -rp "  Select [0-5]: " choice || break

        case "$choice" in
            1)
                echo ""
                print_info "SSH tunnel users:"
                echo ""
                if ! timeout --kill-after=3 10 sshtun-user list </dev/null 2>/dev/null; then
                    # Fallback: sshtun-user list requires TTY on some versions
                    local tun_users
                    tun_users=$(awk -F: '/SSH tunnel only/{print $1}' /etc/passwd 2>/dev/null)
                    if [[ -n "$tun_users" ]]; then
                        echo "$tun_users" | while IFS= read -r u; do
                            echo -e "  ${GREEN}${u}${NC}"
                        done
                    else
                        print_warn "No tunnel users found"
                    fi
                fi
                ;;
            2)
                echo ""
                local new_user new_pass
                new_user=$(prompt_input "Enter username for new tunnel user")
                new_user=$(echo "$new_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -z "$new_user" ]]; then
                    print_fail "Username cannot be empty"
                    continue
                fi
                if [[ "$new_user" == *"|"* ]]; then
                    print_fail "Username cannot contain the | character"
                    continue
                fi
                new_pass=$(prompt_input "Enter password (leave blank to auto-generate)")
                new_pass=$(echo "$new_pass" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ "$new_pass" == *"|"* ]]; then
                    print_fail "Password cannot contain the | character"
                    continue
                fi
                echo ""
                local user_created=false
                if [[ -n "$new_pass" ]]; then
                    if timeout --kill-after=3 30 sshtun-user create "$new_user" --insecure-password "$new_pass" </dev/null 2>&1; then
                        print_ok "User '${new_user}' created"
                        user_created=true
                    else
                        print_fail "Failed to create user '${new_user}' (command timed out or failed)"
                    fi
                else
                    if timeout --kill-after=3 30 sshtun-user create "$new_user" </dev/null 2>&1; then
                        print_ok "User '${new_user}' created (random password assigned)"
                        user_created=true
                    else
                        print_fail "Failed to create user '${new_user}' (command timed out or failed)"
                    fi
                fi

                # Save credentials for status page URL generation
                if [[ "$user_created" == true ]]; then
                    local final_pass="$new_pass"
                    if [[ -z "$final_pass" ]]; then
                        final_pass=$(timeout --kill-after=3 10 sshtun-user show "$new_user" </dev/null 2>/dev/null | grep -i pass | awk '{print $NF}' || ignore_failure)
                    fi
                    if [[ -n "$final_pass" ]]; then
                        # Store credentials (root-only) for status page
                        mkdir -p /etc/dnstm 2>/dev/null || ignore_failure
                    write_file_atomic /etc/dnstm/ssh-credentials 0600 root root <<<"${new_user}:${final_pass}"
                        chmod 600 /etc/dnstm/ssh-credentials
                        echo ""
                        print_info "SlipNet SSH config URLs for user '${new_user}':"
                        echo ""
                        # Find all SSH tunnels and generate URLs
                        local s_user="" s_pass=""
                        if detect_socks_auth; then
                            s_user="$SOCKS_USER"
                            s_pass="$SOCKS_PASS"
                        fi
                        local tunnel_domains
                        tunnel_domains=$(dnstm tunnel list 2>/dev/null || ignore_failure)
                        # Get all unique base domains from tunnels
                        local domains
                        domains=$(echo "$tunnel_domains" | grep -o 'domain=[^ ]*' | sed 's/domain=//;s/^[a-z]*\.//' | sort -u || ignore_failure)
                        for dom in $domains; do
                            DOMAIN="$dom"
                            local pubkey=""
                            # Find DNSTT pubkey for this domain
                            local dnstt_tag_name
                            dnstt_tag_name=$(echo "$tunnel_domains" | grep "domain=d\.${dom}" | grep -oE 'tag=[^ ]+' | head -1 | sed 's/tag=//' || ignore_failure)
                            # Fallback: try matching dnstt tag from the domain line
                            [[ -z "$dnstt_tag_name" ]] && \
                                dnstt_tag_name=$(echo "$tunnel_domains" | grep "d\.${dom}" | grep -oE '\bdnstt[a-z0-9_-]*' | head -1 || ignore_failure)
                            if [[ -n "$dnstt_tag_name" && -f "/etc/dnstm/tunnels/${dnstt_tag_name}/server.pub" ]]; then
                                pubkey=$(cat "/etc/dnstm/tunnels/${dnstt_tag_name}/server.pub" 2>/dev/null || ignore_failure)
                            fi
                            # Slipstream + SSH — SlipNet needs pubkey even for slipstream
                            local slip_ssh_pk=""
                            slip_ssh_pk=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
                            local url
                            url=$(generate_slipnet_url "slipstream_ssh" "s" "$slip_ssh_pk" "$new_user" "$final_pass" "$s_user" "$s_pass")
                            echo -e "  ${GREEN}s.${dom}:${NC}  ${url}"
                            # DNSTT + SSH
                            if [[ -n "$pubkey" ]]; then
                                url=$(generate_slipnet_url "dnstt_ssh" "ds" "$pubkey" "$new_user" "$final_pass" "$s_user" "$s_pass")
                                echo -e "  ${GREEN}ds.${dom}:${NC} ${url}"
                            fi
                            # NoizDNS + SSH
                            local noiz_ssh_pk=""
                            local noiz_ssh_tags
                            noiz_ssh_tags=$(echo "$tunnel_domains" | grep -o 'tag=noiz-ssh[^ ]*' | sed 's/tag=//' || ignore_failure)
                            for ntag in $noiz_ssh_tags; do
                                if [[ -f "/etc/dnstm/tunnels/${ntag}/server.pub" ]]; then
                                    noiz_ssh_pk=$(cat "/etc/dnstm/tunnels/${ntag}/server.pub" 2>/dev/null || ignore_failure)
                                    if [[ -n "$noiz_ssh_pk" ]]; then
                                        url=$(generate_slipnet_url "sayedns_ssh" "z" "$noiz_ssh_pk" "$new_user" "$final_pass" "$s_user" "$s_pass")
                                        echo -e "  ${GREEN}z.${dom}:${NC}  ${url}"
                                    fi
                                    break
                                fi
                            done
                        done
                    fi
                fi
                ;;
            3)
                echo ""
                local upd_user upd_pass
                upd_user=$(prompt_input "Enter username to update")
                upd_user=$(echo "$upd_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -z "$upd_user" ]]; then
                    print_fail "Username cannot be empty"
                    continue
                fi
                if [[ "$upd_user" == *"|"* ]]; then
                    print_fail "Username cannot contain the | character"
                    continue
                fi
                upd_pass=$(prompt_input "Enter new password")
                upd_pass=$(echo "$upd_pass" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -z "$upd_pass" ]]; then
                    print_fail "Password cannot be empty"
                    continue
                fi
                if [[ "$upd_pass" == *"|"* ]]; then
                    print_fail "Password cannot contain the | character"
                    continue
                fi
                echo ""
                if timeout --kill-after=3 30 sshtun-user update "$upd_user" --insecure-password "$upd_pass" </dev/null 2>&1; then
                    print_ok "Password updated for '${upd_user}'"
                    # Update stored credentials
                    mkdir -p /etc/dnstm 2>/dev/null || ignore_failure
                        write_file_atomic /etc/dnstm/ssh-credentials 0600 root root <<<"${upd_user}:${upd_pass}"
                    chmod 600 /etc/dnstm/ssh-credentials
                else
                    print_fail "Failed to update user '${upd_user}'"
                fi
                ;;
            4)
                echo ""
                local del_user
                del_user=$(prompt_input "Enter username to delete")
                del_user=$(echo "$del_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -z "$del_user" ]]; then
                    print_fail "Username cannot be empty"
                    continue
                fi
                if [[ "$del_user" == *"|"* ]]; then
                    print_fail "Username cannot contain the | character"
                    continue
                fi
                if prompt_yn "Are you sure you want to delete '${del_user}'?" "n"; then
                    if timeout --kill-after=3 30 sshtun-user delete "$del_user" </dev/null 2>&1; then
                        print_ok "User '${del_user}' deleted"
                        # Remove stored credentials if they match
                        if [[ -f /etc/dnstm/ssh-credentials ]]; then
                            local stored_user
                            stored_user=$(cut -d: -f1 /etc/dnstm/ssh-credentials 2>/dev/null || ignore_failure)
                            if [[ "$stored_user" == "$del_user" ]]; then
                                rm -f /etc/dnstm/ssh-credentials
                            fi
                        fi
                    else
                        print_fail "Failed to delete user '${del_user}'"
                    fi
                else
                    print_info "Cancelled"
                fi
                ;;
            5)
                echo ""
                local regen_user regen_pass
                regen_user=$(prompt_input "Enter SSH tunnel username")
                regen_user=$(echo "$regen_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -z "$regen_user" ]]; then
                    print_fail "Username cannot be empty"
                    continue
                fi
                regen_pass=$(prompt_input "Enter SSH tunnel password")
                regen_pass=$(echo "$regen_pass" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -z "$regen_pass" ]]; then
                    print_fail "Password cannot be empty"
                    continue
                fi
                echo ""
                print_info "SlipNet SSH share URLs for '${regen_user}':"
                echo ""
                local s_user="" s_pass=""
                if detect_socks_auth; then
                    s_user="$SOCKS_USER"
                    s_pass="$SOCKS_PASS"
                fi
                local tunnel_domains
                tunnel_domains=$(dnstm tunnel list 2>/dev/null || ignore_failure)
                local domains
                domains=$(echo "$tunnel_domains" | awk '{for(i=1;i<=NF;i++) if($i ~ /\.[a-z]/) print $i}' | sed 's/^[a-z]*\.//' | sort -u || ignore_failure)
                if [[ -z "$domains" ]]; then
                    domains=$(echo "$tunnel_domains" | grep -o 'domain=[^ ]*' | sed 's/domain=//;s/^[a-z]*\.//' | sort -u || ignore_failure)
                fi
                for dom in $domains; do
                    DOMAIN="$dom"
                    local _any_pk=""
                    _any_pk=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
                    # Slipstream + SSH
                    local url
                    url=$(generate_slipnet_url "slipstream_ssh" "s" "$_any_pk" "$regen_user" "$regen_pass" "$s_user" "$s_pass")
                    echo -e "  ${GREEN}slip-ssh (s.${dom}):${NC}"
                    echo "  ${url}"
                    echo ""
                    # DNSTT + SSH
                    local _dnstt_pk=""
                    _dnstt_pk=$(cat /etc/dnstm/tunnels/dnstt-ssh/server.pub 2>/dev/null || ignore_failure)
                    [[ -z "$_dnstt_pk" ]] && _dnstt_pk=$(cat /etc/dnstm/tunnels/dnstt1/server.pub 2>/dev/null || ignore_failure)
                    if [[ -n "$_dnstt_pk" ]]; then
                        url=$(generate_slipnet_url "dnstt_ssh" "ds" "$_dnstt_pk" "$regen_user" "$regen_pass" "$s_user" "$s_pass")
                        echo -e "  ${GREEN}dnstt-ssh (ds.${dom}):${NC}"
                        echo "  ${url}"
                        echo ""
                    fi
                    # NoizDNS + SSH
                    local _noiz_pk=""
                    _noiz_pk=$(cat /etc/dnstm/tunnels/noiz-ssh/server.pub 2>/dev/null || ignore_failure)
                    if [[ -n "$_noiz_pk" ]]; then
                        url=$(generate_slipnet_url "sayedns_ssh" "z" "$_noiz_pk" "$regen_user" "$regen_pass" "$s_user" "$s_pass")
                        echo -e "  ${GREEN}noiz-ssh (z.${dom}):${NC}"
                        echo "  ${url}"
                        echo ""
                    fi
                done
                ;;
            0)
                echo ""
                print_ok "Done"
                exit 0
                ;;
            *)
                print_warn "Invalid choice"
                ;;
        esac
    done
}

# ─── Xray Backend Integration ─────────────────────────────────────────────────

# Install 3x-ui panel with custom credentials and port.
# Usage: install_3xui <username> <password> <panel_port>

do_manage() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${CROSS} Not running as root. Please run with: sudo bash $0 --manage"
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the full setup first: sudo bash $0"
        exit 1
    fi

    # Trap SIGINT in the parent so Ctrl+C only kills the subshell,
    # not the entire manage menu. Restore default trap on exit.
    trap '' INT

    while true; do
        banner
        print_header "Management Menu"
        echo ""

        echo -e "  ${BOLD}1)${NC}  Show status          ${DIM}(tunnels, credentials, share URLs)${NC}"
        echo -e "  ${BOLD}2)${NC}  Add tunnel            ${DIM}(single tunnel — pick transport & backend)${NC}"
        echo -e "  ${BOLD}3)${NC}  Remove tunnel         ${DIM}(pick one to remove)${NC}"
        echo -e "  ${BOLD}4)${NC}  Add backup domain     ${DIM}(new domain → 4 more tunnels)${NC}"
        echo -e "  ${BOLD}5)${NC}  Manage SSH users      ${DIM}(add, list, update, delete)${NC}"
        echo -e "  ${BOLD}6)${NC}  Configure SOCKS auth  ${DIM}(enable, disable, or change credentials)${NC}"
        echo -e "  ${BOLD}7)${NC}  Apply hardening       ${DIM}(systemd security for all services)${NC}"
        echo -e "  ${BOLD}8)${NC}  Xray backend          ${DIM}(connect 3x-ui panel via DNS tunnel)${NC}"
        echo -e "  ${BOLD}9)${NC}  Change DNSTT MTU      ${DIM}(change MTU on existing DNSTT tunnels)${NC}"
        echo ""
        echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}10)${NC} Update script         ${DIM}(check for new versions)${NC}"
        echo -e "  ${BOLD}${RED}11)${NC} ${RED}Uninstall everything${NC}"
        echo ""
        echo -e "  ${BOLD}0)${NC}  Exit"
        echo ""

        local choice=""
        read -rp "  Select [0-11]: " choice || break

        case "$choice" in
            1)
                ( trap - INT; do_status )  || ignore_failure
                ;;
            2)
                ( trap - INT; do_add_tunnel ) || ignore_failure
                ;;
            3)
                ( trap - INT; do_remove_tunnel "" ) || ignore_failure
                ;;
            4)
                ( trap - INT; do_add_domain ) || ignore_failure
                ;;
            5)
                ( trap - INT; do_manage_users ) || ignore_failure
                ;;
            6)
                ( trap - INT; do_configure_socks_auth ) || ignore_failure
                ;;
            7)
                ( trap - INT; do_harden ) || ignore_failure
                ;;
            8)
                ( trap - INT; do_add_xray ) || ignore_failure
                ;;
            9)
                ( trap - INT; do_change_mtu ) || ignore_failure
                ;;
            10)
                ( trap - INT; do_update ) || ignore_failure
                # If update wrote the re-exec marker, restart with new version
                if [[ -f /tmp/.dnstm-update-reexec ]]; then
                    local reexec_path
                    reexec_path=$(cat /tmp/.dnstm-update-reexec)
                    rm -f /tmp/.dnstm-update-reexec
                    exec bash "$reexec_path" --manage
                fi
                ;;
            11)
                ( trap - INT; do_uninstall ) || ignore_failure
                # If uninstall succeeded, dnstm is gone — exit menu
                hash -d dnstm 2>/dev/null || ignore_failure
                if ! command -v dnstm &>/dev/null; then
                    echo ""
                    print_info "dnstm has been uninstalled. Exiting menu."
                    break
                fi
                ;;
            0|q|Q)
                echo ""
                break
                ;;
            "")
                # Just Enter — redraw menu
                continue
                ;;
            *)
                print_warn "Invalid choice. Enter 0-11."
                sleep 1
                continue
                ;;
        esac

        # Pause so user can read output before menu redraws
        echo ""
        echo -e "  ${DIM}Press Enter to return to menu...${NC}"
        read -r || break
    done

    # Restore default SIGINT handling
    trap - INT
}

# ─── Global Variables (must be set before arg parser since --status/--manage use them) ───

DOMAIN=""
SERVER_IP=""
DNSTT_PUBKEY=""
NOIZDNS_PUBKEY=""
SSH_USER=""
SSH_PASS=""
SOCKS_USER=""
SOCKS_PASS=""
SOCKS_AUTH=false
TUNNELS_CHANGED=false

# ─── Variables (populated during setup) ─────────────────────────────────────────

SSH_SETUP_DONE=false

# ─── STEP 1: Pre-flight Checks ─────────────────────────────────────────────────

step_preflight() {
    print_step 1 "Pre-flight Checks"

    # Check root
    if [[ $EUID -eq 0 ]]; then
        print_ok "Running as root"
    else
        print_fail "Not running as root. Please run with: sudo bash $0"
        exit 1
    fi

    # Back up resolv.conf so we can always recover DNS
    if [[ -f /etc/resolv.conf ]] && [[ ! -f /etc/resolv.conf.dnstm-backup ]]; then
        cp -f /etc/resolv.conf /etc/resolv.conf.dnstm-backup 2>/dev/null || ignore_failure
    fi

    # Check OS (read in subshell to avoid overwriting script's VERSION variable)
    if [[ -f /etc/os-release ]]; then
        local os_id os_name
        os_id=$(. /etc/os-release && echo "${ID:-}")
        os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-$os_id}")
        if [[ "$os_id" == "ubuntu" || "$os_id" == "debian" ]]; then
            print_ok "OS: ${os_name}"
        else
            print_warn "OS: ${os_name} (not Ubuntu/Debian - may work but untested)"
        fi
    else
        print_warn "Cannot detect OS (missing /etc/os-release)"
    fi

    # Check curl
    if command -v curl &>/dev/null; then
        print_ok "curl is installed"
    else
        print_fail "curl is not installed"
        echo ""
        if prompt_yn "Install curl now?" "y"; then
            if apt-get update -qq && apt-get install -y -qq curl; then
                print_ok "curl installed"
            else
                print_fail "Failed to install curl. Check your network/repos."
                exit 1
            fi
        else
            echo ""
            print_fail "curl is required. Please install it and re-run."
            exit 1
        fi
    fi

    # Ensure DNS resolution works (may be broken after previous uninstall)
    if ! curl -4 -s --max-time 3 https://api.ipify.org >/dev/null 2>&1; then
        if grep -q '127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
            # systemd-resolved stub is dead — replace with public DNS
            print_warn "DNS broken (stub listener dead) — fixing resolv.conf"
            write_public_dns_resolver_file /etc/resolv.conf
        fi
    fi

    # Detect server IP
    SERVER_IP=$(fetch_public_ipv4 2>/dev/null || ignore_failure)
    if [[ -n "$SERVER_IP" ]]; then
        print_ok "Server IP: ${SERVER_IP}"
    else
        print_warn "Could not auto-detect server IP"
        SERVER_IP=$(prompt_input "Enter your server's public IP")
        if [[ -z "$SERVER_IP" ]] || ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            print_fail "A valid server IPv4 address is required."
            exit 1
        fi
    fi

    echo ""
    print_ok "All pre-flight checks passed"
}

# ─── STEP 2: Ask Domain ────────────────────────────────────────────────────────

step_ask_domain() {
    print_step 2 "Domain Configuration"

    while true; do
        DOMAIN=$(prompt_input "Enter your domain (e.g. example.com)")
        # Strip whitespace, http(s)://, trailing slashes
        DOMAIN=$(echo "$DOMAIN" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||;s|^https\?://||;s|/.*$||')
        if [[ -z "$DOMAIN" ]]; then
            print_fail "Domain cannot be empty. Please try again."
        elif ! validate_domain "$DOMAIN"; then
            print_fail "Invalid domain. Please try again."
        else
            break
        fi
    done

    echo ""
    print_ok "Using domain: ${BOLD}${DOMAIN}${NC}"
}

# ─── Cloudflare API: Auto-create DNS records ────────────────────────────────────

# Create all required DNS records via Cloudflare API.
# Args: $1=API token, $2=domain, $3=server IP

cloudflare_create_dns_records() {
    local api_token="$1"
    local domain="$2"
    local server_ip="$3"
    local cf_api="https://api.cloudflare.com/client/v4"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "Dry-run: Cloudflare DNS record creation preview"
        echo -e "  ${GREEN}[plan]${NC} A  ns  -> ${server_ip}"
        echo -e "  ${GREEN}[plan]${NC} NS t   -> ns.${domain}"
        echo -e "  ${GREEN}[plan]${NC} NS d   -> ns.${domain}"
        echo -e "  ${GREEN}[plan]${NC} NS n   -> ns.${domain}"
        echo -e "  ${GREEN}[plan]${NC} NS s   -> ns.${domain}"
        echo -e "  ${GREEN}[plan]${NC} NS ds  -> ns.${domain}"
        echo -e "  ${GREEN}[plan]${NC} NS z   -> ns.${domain}"
        return 0
    fi

    # Ensure jq is installed (needed for JSON parsing)
    if ! command -v jq &>/dev/null; then
        print_info "Installing jq (needed for Cloudflare API)..."
        apt-get update -qq >/dev/null 2>&1 || ignore_failure
        apt-get install -y -qq jq >/dev/null 2>&1 || ignore_failure
        if ! command -v jq &>/dev/null; then
            print_fail "Could not install jq. Install manually: apt-get install jq"
            return 1
        fi
    fi

    # Step 1: Get Zone ID
    print_info "Looking up Cloudflare Zone ID for ${domain}..."
    local zone_resp
    zone_resp=$(curl -s -X GET "${cf_api}/zones?name=${domain}" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" --max-time 15 2>/dev/null || ignore_failure)

    if [[ -z "$zone_resp" ]]; then
        print_fail "Could not connect to Cloudflare API"
        return 1
    fi

    local zone_id
    zone_id=$(echo "$zone_resp" | jq -r '.result[0].id // empty' 2>/dev/null || ignore_failure)
    if [[ -z "$zone_id" ]]; then
        local cf_err
        cf_err=$(echo "$zone_resp" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Invalid response")
        print_fail "Could not find zone for ${domain}: ${cf_err}"
        print_info "Make sure the domain is added to your Cloudflare account and the API token has Zone:Read permission"
        return 1
    fi
    print_ok "Zone ID: ${zone_id}"

    # Helper: create or skip a DNS record
    local created=0 skipped=0 failed=0
    _cf_create_record() {
        local rtype="$1" rname="$2" rcontent="$3" proxied="${4:-false}"
        local full_name="${rname}.${domain}"

        # Check if record already exists
        local existing
        existing=$(curl -s -X GET "${cf_api}/zones/${zone_id}/dns_records?name=${full_name}&type=${rtype}" \
            -H "Authorization: Bearer ${api_token}" \
            -H "Content-Type: application/json" --max-time 10 2>/dev/null || ignore_failure)
        local count
        count=$(echo "$existing" | jq '.result | length' 2>/dev/null || echo "0")

        if [[ "$count" -gt 0 ]]; then
            echo -e "  ${DIM}[skip]${NC} ${rtype} ${rname} — already exists"
            skipped=$((skipped + 1))
            return 0
        fi

        # Create the record
        local payload
        if [[ "$rtype" == "A" ]]; then
            payload=$(jq -n --arg t "$rtype" --arg n "$full_name" --arg c "$rcontent" --argjson p "$proxied" \
                '{type: $t, name: $n, content: $c, ttl: 3600, proxied: $p}')
        else
            payload=$(jq -n --arg t "$rtype" --arg n "$full_name" --arg c "$rcontent" \
                '{type: $t, name: $n, content: $c, ttl: 3600}')
        fi

        local create_resp
        create_resp=$(curl -s -X POST "${cf_api}/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${api_token}" \
            -H "Content-Type: application/json" \
            -d "$payload" --max-time 10 2>/dev/null || ignore_failure)

        local success
        success=$(echo "$create_resp" | jq -r '.success // false' 2>/dev/null || echo "false")
        if [[ "$success" == "true" ]]; then
            echo -e "  ${GREEN}[created]${NC} ${rtype} ${rname} → ${rcontent}"
            created=$((created + 1))
        else
            local err_msg
            err_msg=$(echo "$create_resp" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "API error")
            echo -e "  ${RED}[failed]${NC} ${rtype} ${rname}: ${err_msg}"
            failed=$((failed + 1))
        fi
    }

    # Step 2: Create A record
    echo ""
    print_info "Creating DNS records..."
    echo ""
    _cf_create_record "A" "ns" "$server_ip" "false"

    # Step 3: Create NS records
    local ns_target="ns.${domain}"
    local subdomains=("t" "d" "n" "s" "ds" "z")
    for sub in "${subdomains[@]}"; do
        _cf_create_record "NS" "$sub" "$ns_target"
    done

    echo ""
    print_ok "Done: ${created} created, ${skipped} skipped, ${failed} failed"

    if [[ $failed -gt 0 ]]; then
        print_warn "Some records failed — check your Cloudflare dashboard"
        return 1
    fi
    return 0
}

# ─── STEP 3: Show DNS Records ──────────────────────────────────────────────────

step_dns_records() {
    print_step 3 "DNS Records (Cloudflare)"

    echo ""
    echo -e "  ${BOLD}How do you want to set up DNS records?${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  Automatic (Cloudflare API)  ${DIM}— enter API token, records created for you${NC}"
    echo -e "  ${BOLD}2)${NC}  Manual                      ${DIM}— create records yourself in Cloudflare dashboard${NC}"
    echo ""
    local dns_choice
    dns_choice=$(prompt_input "Select (1-2)" "1")

    if [[ "$dns_choice" == "1" ]]; then
        # Automatic via Cloudflare API
        echo ""
        echo -e "  ${BOLD}${YELLOW}How to get a Cloudflare API Token:${NC}"
        echo ""
        echo -e "  ${BOLD}1.${NC} Go to: ${GREEN}https://dash.cloudflare.com/profile/api-tokens${NC}"
        echo -e "  ${BOLD}2.${NC} Click ${BOLD}Create Token${NC}"
        echo -e "  ${BOLD}3.${NC} Select the ${BOLD}Edit zone DNS${NC} template"
        echo -e "  ${BOLD}4.${NC} Under ${BOLD}Zone Resources${NC}, select your domain (or All Zones)"
        echo -e "  ${BOLD}5.${NC} Click ${BOLD}Continue to summary${NC} → ${BOLD}Create Token${NC}"
        echo -e "  ${BOLD}6.${NC} Copy the token (you'll only see it once!)"
        echo ""
        echo -e "  ${DIM}Required permissions: Zone:DNS:Edit + Zone:Zone:Read${NC}"
        echo -e "  ${DIM}The 'Edit zone DNS' template includes both automatically${NC}"
        echo ""

        local cf_token
        cf_token=$(prompt_input "Paste your Cloudflare API Token here")
        cf_token=$(echo "$cf_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$cf_token" && "$DRY_RUN" != true ]]; then
            print_fail "API token cannot be empty"
            exit 1
        fi

        if [[ "$DRY_RUN" == true ]]; then
            cloudflare_create_dns_records "$cf_token" "$DOMAIN" "$SERVER_IP"
            return 0
        fi

        # Ensure jq is installed (needed for API JSON parsing)
        if ! command -v jq &>/dev/null; then
            print_info "Installing jq (needed for Cloudflare API)..."
            apt-get update -qq >/dev/null 2>&1 || ignore_failure
            apt-get install -y -qq jq >/dev/null 2>&1 || ignore_failure
            if ! command -v jq &>/dev/null; then
                print_fail "Could not install jq. Install manually: apt-get install jq"
                exit 1
            fi
        fi

        # Validate token
        # Try /user/tokens/verify first (standard tokens), then fall back to
        # /accounts (account-scoped tokens like cfat_*) which works universally.
        print_info "Validating API token..."
        local verify_resp token_status token_valid=false
        verify_resp=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "Authorization: Bearer ${cf_token}" \
            -H "Content-Type: application/json" --max-time 10 2>/dev/null || ignore_failure)
        token_status=$(echo "$verify_resp" | jq -r '.result.status // empty' 2>/dev/null || ignore_failure)
        if [[ "$token_status" == "active" ]]; then
            token_valid=true
        else
            # Fall back: account-scoped tokens don't work with /user/tokens/verify.
            # Check /accounts — a successful response confirms the token is valid.
            local accounts_resp accounts_success
            accounts_resp=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts?per_page=1" \
                -H "Authorization: Bearer ${cf_token}" \
                -H "Content-Type: application/json" --max-time 10 2>/dev/null || ignore_failure)
            accounts_success=$(echo "$accounts_resp" | jq -r '.success // empty' 2>/dev/null || ignore_failure)
            if [[ "$accounts_success" == "true" ]]; then
                token_valid=true
            fi
        fi

        if [[ "$token_valid" != "true" ]]; then
            print_fail "API token is invalid or expired"
            print_info "Check your token at: https://dash.cloudflare.com/profile/api-tokens"
            exit 1
        fi
        print_ok "API token is valid"

        # Create DNS records
        if cloudflare_create_dns_records "$cf_token" "$DOMAIN" "$SERVER_IP"; then
            print_ok "All DNS records created successfully"
        else
            echo ""
            if ! prompt_yn "Some records failed. Continue anyway?" "n"; then
                exit 1
            fi
        fi
    else
        # Manual setup
        print_info "Create these DNS records in your Cloudflare dashboard:"
        echo ""
        print_box \
            "Record 1:  Type: A   | Name: ns | Value: ${SERVER_IP}" \
            "           Proxy: OFF (DNS Only - grey cloud)" \
            "" \
            "Record 2:  Type: NS  | Name: t   | Value: ns.${DOMAIN}" \
            "Record 3:  Type: NS  | Name: d   | Value: ns.${DOMAIN}" \
            "Record 4:  Type: NS  | Name: s   | Value: ns.${DOMAIN}" \
            "Record 5:  Type: NS  | Name: ds  | Value: ns.${DOMAIN}" \
            "Record 6:  Type: NS  | Name: n   | Value: ns.${DOMAIN}" \
            "Record 7:  Type: NS  | Name: z   | Value: ns.${DOMAIN}"

        echo ""
        print_warn "IMPORTANT: The A record MUST be DNS Only (grey cloud, NOT orange)"
        print_warn "IMPORTANT: The A record name must be \"ns\" (not \"tns\")"
        echo ""
        echo "  Subdomain purposes:"
        echo "    t   = Slipstream + SOCKS tunnel"
        echo "    d   = DNSTT + SOCKS tunnel"
        echo "    n   = NoizDNS + SOCKS tunnel (DPI-resistant)"
        echo "    s   = Slipstream + SSH tunnel"
        echo "    ds  = DNSTT + SSH tunnel"
        echo "    z   = NoizDNS + SSH tunnel (DPI-resistant)"
        echo ""

        if ! prompt_yn "Have you created these DNS records in Cloudflare?" "n"; then
            echo ""
            print_info "Please create the DNS records and re-run this script."
            exit 0
        fi
    fi

    echo ""
    print_ok "DNS records confirmed"
}

# ─── STEP 4: Free Port 53 ──────────────────────────────────────────────────────

step_free_port53() {
    print_step 4 "Free Port 53"

    local port53_output
    port53_output=$(ss -ulnp 2>/dev/null | grep -E ':53\b' || ignore_failure)

    if [[ -z "$port53_output" ]]; then
        print_ok "Port 53 is free"
        return
    fi

    # dnstm already on port 53 is fine (re-run scenario)
    if echo "$port53_output" | grep -q "dnstm"; then
        print_ok "Port 53 is in use by dnstm (already set up)"
        return
    fi

    print_info "Something is using port 53:"
    echo -e "  ${DIM}${port53_output}${NC}"
    echo ""

    if echo "$port53_output" | grep -q "systemd-resolve\|127\.0\.0\.53"; then
        print_warn "systemd-resolved is occupying port 53"
        echo ""
        if prompt_yn "Configure systemd-resolved to disable only DNSStubListener?" "y"; then
            # Safer than masking resolved entirely: keep DNS management, only free :53.
            configure_systemd_resolved_no_stub || ignore_failure
            sleep 1
            port53_output=$(ss -ulnp 2>/dev/null | grep -E ':53\b' || ignore_failure)

            # Fallback if stub is still present.
            if echo "$port53_output" | grep -q "systemd-resolve\|127\.0\.0\.53"; then
                print_warn "systemd-resolved still occupies port 53; stopping + disabling as fallback"
                systemctl stop systemd-resolved.socket 2>/dev/null || ignore_failure
                systemctl stop systemd-resolved.service 2>/dev/null || ignore_failure
                systemctl disable systemd-resolved.service 2>/dev/null || ignore_failure
                ensure_resolv_conf_fallback
                sleep 1
            fi
        else
            print_fail "Port 53 must be free for DNS tunnels to work."
            exit 1
        fi
    else
        print_fail "An unknown service is using port 53."
        print_info "Please stop it manually and re-run this script."
        exit 1
    fi

    # Verify port is now free
    port53_output=$(ss -ulnp 2>/dev/null | grep -E ':53\b' || ignore_failure)
    if [[ -z "$port53_output" ]]; then
        print_ok "Port 53 is now free"
    else
        print_fail "Port 53 is still in use. Please investigate manually."
        exit 1
    fi
}

# ─── STEP 5: Install dnstm ─────────────────────────────────────────────────────

step_install_dnstm() {
    print_step 5 "Install dnstm"

    # Check if already installed
    if command -v dnstm &>/dev/null; then
        local ver
        ver=$(dnstm --version 2>/dev/null || echo "unknown")
        print_info "dnstm is already installed (${ver})"
        echo ""
        if ! prompt_yn "Re-install / update dnstm?" "n"; then
            # Ensure router is in multi mode even if we skip install
            local current_mode
            current_mode=$(dnstm router mode 2>/dev/null | awk '/[Mm]ode/{for(i=1;i<=NF;i++) if($i=="multi"||$i=="single") print $i}' | head -1 || ignore_failure)
            if [[ "$current_mode" != "multi" ]]; then
                print_warn "Router mode is '${current_mode:-unknown}', switching to multi..."
                if dnstm router mode multi 2>/dev/null; then
                    print_ok "Router mode switched to multi"
                else
                    print_fail "Failed to switch router mode to multi"
                    exit 1
                fi
            else
                print_ok "Router mode: multi"
            fi
            print_ok "Skipping dnstm installation"
            return
        fi
    fi

    # Stop and remove ALL tunnels so they get fresh configs after re-install
    print_info "Stopping dnstm services..."
    dnstm router stop 2>/dev/null || ignore_failure
    # Remove all existing tunnels (they'll be recreated in Step 7 with correct ports)
    local old_tags
    old_tags=$(dnstm_get_tags)
    for tag in $old_tags; do
        dnstm tunnel stop --tag "$tag" 2>/dev/null || ignore_failure
        dnstm tunnel remove --tag "$tag" 2>/dev/null || ignore_failure
    done
    # Stop all dnstm systemd units
    local unit
    for unit in $(systemctl list-units --type=service --no-legend 'dnstm-*' 2>/dev/null | awk '{print $1}' || ignore_failure); do
        systemctl stop "$unit" 2>/dev/null || ignore_failure
    done
    systemctl stop dnstm-dnsrouter 2>/dev/null || ignore_failure
    systemctl stop microsocks 2>/dev/null || ignore_failure
    # Kill tunnel/router processes by exact name (NOT -f, to avoid killing this script)
    # slipstream-server comm name is truncated to 15 chars: "slipstream-serv"
    pkill -9 slipstream-serv 2>/dev/null || ignore_failure
    pkill -9 dnstt-server 2>/dev/null || ignore_failure
    pkill -9 microsocks 2>/dev/null || ignore_failure
    # dnstm-dnsrouter comm name is truncated to 15 chars: "dnstm-dnsroute"
    pkill -9 dnstm-dnsroute 2>/dev/null || ignore_failure
    # Kill the dnstm binary itself (comm name = "dnstm", won't match "bash dnstm-setup.sh")
    pkill -9 -x dnstm 2>/dev/null || ignore_failure
    sleep 1
    # Reset systemd failed state before removing binary to prevent start-limit-hit
    for unit in $(systemctl list-units --all --type=service --no-legend 'dnstm-*' 2>/dev/null | awk '{print $1}' || ignore_failure); do
        systemctl reset-failed "$unit" 2>/dev/null || ignore_failure
    done
    systemctl reset-failed dnstm-dnsrouter 2>/dev/null || ignore_failure
    rm -f /usr/local/bin/dnstm

    # Download binary
    print_info "Downloading dnstm..."
    local arch
    arch=$(detect_architecture)
    if ensure_dnstm_binary "$arch"; then
        print_ok "Verified dnstm binary for ${arch}"
    else
        print_fail "Failed to install pinned dnstm for ${arch} architecture"
        exit 1
    fi

    # Save iptables state before dnstm install (it may reset firewall rules)
    local iptables_backup="/tmp/iptables-backup-$$"
    iptables-save > "$iptables_backup" 2>/dev/null || ignore_failure

    # Install in multi mode (use --force on re-install)
    print_info "Running dnstm install --mode multi ..."
    echo ""
    local install_ok=false
    if dnstm install --mode multi --force; then
        echo ""
        install_ok=true
        print_ok "dnstm installed successfully"
        TUNNELS_CHANGED=true
    else
        echo ""
        print_fail "dnstm install failed"
    fi

    # Restore original firewall rules (dnstm install may have reset them)
    if [[ -s "$iptables_backup" ]]; then
        iptables-restore < "$iptables_backup" 2>/dev/null || ignore_failure
    else
        # Do not force permissive policies if we don't have a valid snapshot.
        print_warn "No iptables snapshot found; leaving existing firewall policy unchanged"
    fi
    rm -f "$iptables_backup"

    if [[ "$install_ok" != "true" ]]; then
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip post-install verification for dnstm and helper binaries"
        return 0
    fi

    # Verify
    local ver
    ver=$(dnstm --version 2>/dev/null || echo "unknown")
    print_ok "dnstm version: ${ver}"

    echo ""
    print_info "dnstm install sets up:"
    echo "    - Tunnel binaries (slipstream-server, dnstt-server, microsocks)"
    echo "    - System user (dnstm)"
    echo "    - Firewall rules (port 53)"
    echo "    - DNS Router service"
    echo "    - microsocks SOCKS5 proxy"

    # Proactive GLIBC check — compile microsocks from source now if needed,
    # so it's ready by the time step 9 verifies the proxy.
    if ! microsocks_binary_works; then
        echo ""
        print_warn "microsocks binary incompatible with this system — compiling from source..."
        compile_microsocks_from_source || print_warn "microsocks compilation failed — will retry in step 9"
    fi

    # Download NoizDNS server binary (DPI-resistant DNSTT fork)
    echo ""
    ensure_noizdns_binary "$arch" || ignore_failure
}

# ─── STEP 6: Verify Port 53 ────────────────────────────────────────────────────

step_verify_port53() {
    print_step 6 "Verify Port 53"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip live port 53 verification"
        return 0
    fi

    local port53_output
    port53_output=$(ss -ulnp 2>/dev/null | grep -E ':53\b' || ignore_failure)

    # If systemd-resolved crept back to :53, switch it to no-stub mode.
    if echo "$port53_output" | grep -q "systemd-resolve\|127\.0\.0\.53"; then
        print_warn "systemd-resolved came back on :53 — reconfiguring stub listener"
        configure_systemd_resolved_no_stub || ignore_failure
        sleep 2
        port53_output=$(ss -ulnp 2>/dev/null | grep -E ':53\b' || ignore_failure)
        if echo "$port53_output" | grep -q "systemd-resolve\|127\.0\.0\.53"; then
            print_warn "systemd-resolved still occupies :53; stopping + disabling as fallback"
            systemctl stop systemd-resolved.socket 2>/dev/null || ignore_failure
            systemctl stop systemd-resolved.service 2>/dev/null || ignore_failure
            systemctl disable systemd-resolved.service 2>/dev/null || ignore_failure
            ensure_resolv_conf_fallback
        fi
        sleep 2
        port53_output=$(ss -ulnp 2>/dev/null | grep -E ':53\b' || ignore_failure)
    fi

    if echo "$port53_output" | grep -q "dnstm"; then
        print_ok "dnstm DNS Router is already on port 53"
        print_info "Router will be restarted after tunnel creation to pick up any changes"
    elif [[ -z "$port53_output" ]]; then
        print_ok "Port 53 is free — ready for DNS Router"
    else
        print_warn "Port 53 is in use by an unknown process:"
        echo "$port53_output"
        print_fail "Cannot proceed — port 53 must be free for the DNS Router"
        exit 1
    fi

    # Firewall
    print_info "Ensuring firewall allows port 53..."

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 53/tcp &>/dev/null || ignore_failure
        ufw allow 53/udp &>/dev/null || ignore_failure
        print_ok "ufw: port 53 TCP/UDP allowed"
    elif command -v ufw &>/dev/null; then
        print_info "ufw is installed but inactive; skipping ufw rule changes"
    fi

    if command -v iptables &>/dev/null; then
        # Check if rules already exist before adding
        if ! iptables -C INPUT -p tcp --dport 53 -j ACCEPT &>/dev/null; then
            iptables -A INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || ignore_failure
        fi
        if ! iptables -C INPUT -p udp --dport 53 -j ACCEPT &>/dev/null; then
            iptables -A INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || ignore_failure
        fi
        print_ok "iptables: port 53 TCP/UDP allowed"
    fi

    echo ""
    print_warn "If your hosting provider has an external firewall (web panel),"
    print_warn "make sure port 53 UDP and TCP are open there too."
}

# ─── STEP 7: Create Tunnels ────────────────────────────────────────────────────

step_create_tunnels() {
    print_step 7 "Create Tunnels"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip tunnel creation and share URL generation"
        return 0
    fi

    local any_created=false
    local _tunnel_count=4
    [[ -x /usr/local/bin/noizdns-server ]] && _tunnel_count=6
    print_info "Creating ${_tunnel_count} tunnels for domain: ${BOLD}${DOMAIN}${NC}"
    echo ""

    # Ask for DNSTT MTU (use CLI value as default if provided via --mtu)
    local mtu_input
    mtu_input=$(prompt_input "DNSTT MTU size (512-1400, affects packet size)" "$DNSTT_MTU")
    if [[ "$mtu_input" =~ ^[0-9]+$ ]] && [[ "$mtu_input" -ge 512 ]] && [[ "$mtu_input" -le 1400 ]]; then
        DNSTT_MTU="$mtu_input"
    else
        print_warn "Invalid MTU value; using default ${DNSTT_MTU}"
    fi
    print_ok "DNSTT MTU: ${DNSTT_MTU}"
    echo ""

    # Tunnel 1: Slipstream + SOCKS
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel 1: Slipstream + SOCKS${NC}"
    echo ""
    if dnstm tunnel add --transport slipstream --backend socks --domain "t.${DOMAIN}" --tag slip1 2>&1; then
        print_ok "Created: slip1 (Slipstream + SOCKS) on t.${DOMAIN}"
        any_created=true
    else
        print_warn "Tunnel slip1 may already exist or creation failed"
        print_info "If it already exists, this is OK"
    fi
    echo ""

    # Tunnel 2: DNSTT + SOCKS
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel 2: DNSTT + SOCKS${NC}"
    echo ""
    local dnstt_output
    dnstt_output=$(dnstm tunnel add --transport dnstt --backend socks --domain "d.${DOMAIN}" --tag dnstt1 --mtu "$DNSTT_MTU" 2>&1) || ignore_failure
    echo "$dnstt_output"

    # Try to extract DNSTT public key
    DNSTT_PUBKEY=""
    if [[ -f /etc/dnstm/tunnels/dnstt1/server.pub ]]; then
        DNSTT_PUBKEY=$(cat /etc/dnstm/tunnels/dnstt1/server.pub 2>/dev/null || ignore_failure)
    fi

    if [[ -n "$DNSTT_PUBKEY" ]]; then
        print_ok "Created: dnstt1 (DNSTT + SOCKS) on d.${DOMAIN}"
        any_created=true
        echo ""
        echo -e "  ${BOLD}${YELLOW}DNSTT Public Key (save this!):${NC}"
        echo -e "  ${GREEN}${DNSTT_PUBKEY}${NC}"
    else
        print_warn "Tunnel dnstt1 may already exist or creation failed"
        print_info "If it already exists, this is OK"
    fi
    echo ""

    # Tunnel 3: Slipstream + SSH
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel 3: Slipstream + SSH${NC}"
    echo ""
    if dnstm tunnel add --transport slipstream --backend ssh --domain "s.${DOMAIN}" --tag slip-ssh 2>&1; then
        print_ok "Created: slip-ssh (Slipstream + SSH) on s.${DOMAIN}"
        any_created=true
    else
        print_warn "Tunnel slip-ssh may already exist or creation failed"
        print_info "If it already exists, this is OK"
    fi
    echo ""

    # Tunnel 4: DNSTT + SSH
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel 4: DNSTT + SSH${NC}"
    echo ""
    if dnstm tunnel add --transport dnstt --backend ssh --domain "ds.${DOMAIN}" --tag dnstt-ssh --mtu "$DNSTT_MTU" 2>&1; then
        print_ok "Created: dnstt-ssh (DNSTT + SSH) on ds.${DOMAIN}"
        any_created=true
    else
        print_warn "Tunnel dnstt-ssh may already exist or creation failed"
        print_info "If it already exists, this is OK"
    fi
    echo ""

    # Re-read DNSTT key if not captured
    if [[ -z "$DNSTT_PUBKEY" && -f /etc/dnstm/tunnels/dnstt1/server.pub ]]; then
        DNSTT_PUBKEY=$(cat /etc/dnstm/tunnels/dnstt1/server.pub 2>/dev/null || ignore_failure)
        if [[ -n "$DNSTT_PUBKEY" ]]; then
            echo -e "  ${BOLD}${YELLOW}DNSTT Public Key:${NC}"
            echo -e "  ${GREEN}${DNSTT_PUBKEY}${NC}"
        fi
    fi

    # ─── NoizDNS tunnels (5 & 6) ───
    if [[ -x /usr/local/bin/noizdns-server ]]; then
        echo ""
        echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Tunnel 5: NoizDNS + SOCKS (DPI-resistant)${NC}"
        echo ""
        if dnstm tunnel add --transport dnstt --backend socks --domain "n.${DOMAIN}" --tag noiz1 --mtu "$DNSTT_MTU" 2>&1; then
            print_ok "Created: noiz1 (NoizDNS + SOCKS) on n.${DOMAIN}"
            any_created=true
        else
            print_warn "Tunnel noiz1 may already exist or creation failed"
        fi
        # Override binary to use noizdns-server
        create_noizdns_service_override "noiz1" || print_warn "Could not set NoizDNS binary for noiz1"
        echo ""

        # Extract NoizDNS pubkey
        if [[ -f /etc/dnstm/tunnels/noiz1/server.pub ]]; then
            NOIZDNS_PUBKEY=$(cat /etc/dnstm/tunnels/noiz1/server.pub 2>/dev/null || ignore_failure)
            if [[ -n "$NOIZDNS_PUBKEY" ]]; then
                echo -e "  ${BOLD}${YELLOW}NoizDNS Public Key:${NC}"
                echo -e "  ${GREEN}${NOIZDNS_PUBKEY}${NC}"
            fi
        fi

        echo ""
        echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Tunnel 6: NoizDNS + SSH (DPI-resistant)${NC}"
        echo ""
        if dnstm tunnel add --transport dnstt --backend ssh --domain "z.${DOMAIN}" --tag noiz-ssh --mtu "$DNSTT_MTU" 2>&1; then
            print_ok "Created: noiz-ssh (NoizDNS + SSH) on z.${DOMAIN}"
            any_created=true
        else
            print_warn "Tunnel noiz-ssh may already exist or creation failed"
        fi
        # Override binary to use noizdns-server
        create_noizdns_service_override "noiz-ssh" || print_warn "Could not set NoizDNS binary for noiz-ssh"
        echo ""

        # Stop NoizDNS tunnels so step_start_services can start them fresh
        # with the correct binary (dnstm tunnel add auto-starts with dnstt-server,
        # but we need them to run noizdns-server via the drop-in override)
        systemctl stop "dnstm-noiz1.service" 2>/dev/null || ignore_failure
        systemctl stop "dnstm-noiz-ssh.service" 2>/dev/null || ignore_failure

        # Fix transport field if dnstm rewrote it from "dnstt" to "noizdns"
        fix_noizdns_transport
    else
        echo ""
        print_warn "NoizDNS binary not available — skipping NoizDNS tunnels (n, z subdomains)"
    fi

    # Re-read NoizDNS key if not captured (e.g., tunnel already existed)
    if [[ -z "$NOIZDNS_PUBKEY" && -f /etc/dnstm/tunnels/noiz1/server.pub ]]; then
        NOIZDNS_PUBKEY=$(cat /etc/dnstm/tunnels/noiz1/server.pub 2>/dev/null || ignore_failure)
    fi

    if [[ "$any_created" == true ]]; then
        TUNNELS_CHANGED=true
    fi
    print_ok "All tunnels created"
}

# ─── STEP 8: Start Services ────────────────────────────────────────────────────

step_start_services() {
    print_step 8 "Start Services"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip service startup and router restarts"
        return 0
    fi

    # Validate dnstt-server binary supports -udp (detect if NoizDNS binary overwrote it)
    if [[ -x /usr/local/bin/dnstt-server ]]; then
        if ! /usr/local/bin/dnstt-server -help 2>&1 | grep -q '\-udp'; then
            print_warn "dnstt-server binary does not support -udp (may be NoizDNS fork) — re-downloading correct binary..."
            local _dnstt_arch
            _dnstt_arch=$(detect_architecture)
            if ensure_dnstt_server_binary "$_dnstt_arch"; then
                print_ok "Re-downloaded correct dnstt-server binary"
            else
                print_warn "Could not re-download dnstt-server — DNSTT tunnels may fail"
            fi
        fi
    fi

    # Reload systemd to pick up any service overrides (e.g., NoizDNS binary swap)
    systemctl daemon-reload 2>/dev/null || ignore_failure

    # ── 1. Start tunnels FIRST (before router) ──────────────────────────────────
    # The DNS Router crash-loops if any configured backend tunnel isn't running.
    # So we must start all tunnels and verify they're healthy BEFORE starting the router.

    # Stop router while we start tunnels (it may be running from a previous install)
    if [[ "$TUNNELS_CHANGED" == "true" ]]; then
        print_info "Stopping DNS Router (to reload tunnel config)..."
        dnstm router stop 2>/dev/null || ignore_failure
        sleep 1
    fi

    echo ""

    # Start all tunnels
    local all_tags
    all_tags=$(dnstm_get_tags)
    if [[ -z "$all_tags" ]]; then
        all_tags="slip1 dnstt1 slip-ssh dnstt-ssh"
        [[ -x /usr/local/bin/noizdns-server ]] && all_tags+=" noiz1 noiz-ssh"
    fi
    for tag in $all_tags; do
        print_info "Starting tunnel: ${tag}..."
        if dnstm tunnel start --tag "$tag" 2>/dev/null; then
            print_ok "Started: ${tag}"
        else
            if dnstm_tag_exists "$tag" && dnstm tunnel list 2>/dev/null | grep -wF "$tag" | grep -qi "running"; then
                print_ok "Already running: ${tag}"
            else
                print_warn "Could not start: ${tag}. Check: dnstm tunnel logs --tag ${tag}"
            fi
        fi
    done

    # ── 2. Verify NoizDNS tunnels actually started ──────────────────────────────
    # If NoizDNS services failed (wrong binary, bad config, etc.), remove them
    # so the DNS Router doesn't crash-loop trying to connect to dead backends.
    sleep 3
    for noiz_tag in noiz1 noiz-ssh; do
        if dnstm tunnel list 2>/dev/null | grep -q "tag=${noiz_tag}"; then
            if ! systemctl is-active --quiet "dnstm-${noiz_tag}.service" 2>/dev/null; then
                # Retry — give it more time before removing
                print_info "Waiting for ${noiz_tag} to start..."
                sleep 5
                systemctl restart "dnstm-${noiz_tag}.service" 2>/dev/null || ignore_failure
                sleep 3
                if ! systemctl is-active --quiet "dnstm-${noiz_tag}.service" 2>/dev/null; then
                    print_warn "NoizDNS tunnel ${noiz_tag} failed to start — removing to protect DNS Router"
                    local noiz_log
                    noiz_log=$(journalctl -u "dnstm-${noiz_tag}.service" -n 5 --no-pager 2>/dev/null || ignore_failure)
                    if [[ -n "$noiz_log" ]]; then
                        echo -e "  ${DIM}Last log lines:${NC}"
                        echo "$noiz_log" | while IFS= read -r l; do echo -e "  ${DIM}${l}${NC}"; done
                    fi
                    dnstm tunnel stop --tag "$noiz_tag" 2>/dev/null || ignore_failure
                    dnstm tunnel remove --tag "$noiz_tag" 2>/dev/null || ignore_failure
                    rm -f "/etc/systemd/system/dnstm-${noiz_tag}.service.d/10-noizdns-binary.conf" 2>/dev/null || ignore_failure
                    rmdir "/etc/systemd/system/dnstm-${noiz_tag}.service.d" 2>/dev/null || ignore_failure
                    systemctl daemon-reload 2>/dev/null || ignore_failure
                    print_info "Removed ${noiz_tag} — other tunnels will work normally"
                else
                    print_ok "NoizDNS tunnel ${noiz_tag} started successfully (after retry)"
                fi
            fi
        fi
    done

    # Fix transport field if dnstm rewrote it during start
    fix_noizdns_transport

    echo ""

    # ── 3. Start DNS Router (now that all healthy tunnels are running) ───────────
    if [[ "$TUNNELS_CHANGED" == "true" ]]; then
        print_info "Starting DNS Router..."
        if dnstm router start 2>/dev/null; then
            print_ok "DNS Router started"
        else
            print_warn "DNS Router start returned an error. Checking status..."
            if dnstm router status 2>/dev/null | grep -qi "running"; then
                print_ok "DNS Router is running"
            else
                print_fail "DNS Router failed to start. Check: dnstm router logs"
                exit 1
            fi
        fi

        # Wait for router to bind to port 53
        local attempts=0
        local max_attempts=10
        while [[ $attempts -lt $max_attempts ]]; do
            sleep 1
            if ss -ulnp 2>/dev/null | grep -E ':53\b' | grep -q "dnstm"; then
                print_ok "DNS Router confirmed on port 53"
                break
            fi
            attempts=$((attempts + 1))
        done

        if [[ $attempts -ge $max_attempts ]]; then
            print_warn "DNS Router may not be on port 53 yet. Check: dnstm router logs"
        fi
    else
        # No changes — just verify router is running
        if ss -ulnp 2>/dev/null | grep -E ':53\b' | grep -q "dnstm"; then
            print_ok "DNS Router already running on port 53 (no restart needed)"
        else
            print_warn "DNS Router not detected on port 53. Attempting start..."
            dnstm router start 2>/dev/null || ignore_failure
            sleep 2
            if ss -ulnp 2>/dev/null | grep -E ':53\b' | grep -q "dnstm"; then
                print_ok "DNS Router started on port 53"
            else
                print_fail "DNS Router failed to start. Check: dnstm router logs"
                exit 1
            fi
        fi
    fi

    echo ""
    print_info "Current tunnel status:"
    echo ""
    dnstm tunnel list 2>/dev/null || print_warn "Could not get tunnel list"
    echo ""

    if apply_service_hardening; then
        print_ok "Runtime hardening applied to dnstm and microsocks services"
    else
        print_warn "Runtime hardening reported issues; review systemctl status for dnstm units"
    fi
}

# ─── STEP 9: Verify microsocks ─────────────────────────────────────────────────

step_verify_microsocks() {
    print_step 9 "Verify SOCKS Proxy (microsocks)"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip microsocks runtime verification"
        return 0
    fi

    # Ask about SOCKS authentication
    echo ""
    print_info "SOCKS tunnels (t/d) currently have no authentication."
    print_info "Adding authentication makes the proxy secure — only clients with"
    print_info "the correct username and password can connect."
    echo ""
    if prompt_yn "Enable SOCKS5 authentication for the proxy?" "y"; then
        echo ""
        SOCKS_USER=$(prompt_input "Enter SOCKS proxy username" "proxy")
        SOCKS_USER=$(echo "$SOCKS_USER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$SOCKS_USER" ]]; then
            print_fail "Username cannot be empty"
            SOCKS_USER="proxy"
        fi
        # Reject pipe and colon in username (breaks slipnet URL format and curl --proxy-user)
        if [[ "$SOCKS_USER" == *"|"* || "$SOCKS_USER" == *":"* ]]; then
            print_warn "Username cannot contain | or : characters — using default 'proxy'"
            SOCKS_USER="proxy"
        fi
        SOCKS_PASS=$(prompt_input "Enter SOCKS proxy password")
        SOCKS_PASS=$(echo "$SOCKS_PASS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$SOCKS_PASS" ]]; then
            print_fail "Password cannot be empty — disabling SOCKS auth"
            SOCKS_USER=""
            SOCKS_PASS=""
        # Reject pipe in password (breaks slipnet URL pipe-delimited format)
        elif [[ "$SOCKS_PASS" == *"|"* ]]; then
            print_fail "Password cannot contain the | character — disabling SOCKS auth"
            SOCKS_USER=""
            SOCKS_PASS=""
        else
            SOCKS_AUTH=true
            print_ok "SOCKS authentication enabled (user: ${SOCKS_USER})"
        fi
    else
        print_warn "SOCKS proxy will run without authentication (open to anyone who knows the domain)"
    fi
    echo ""

    # Check if microsocks is running (dnstm manages the binary and service)
    local microsocks_running=false
    if pgrep -x microsocks &>/dev/null || systemctl is-active --quiet microsocks 2>/dev/null; then
        print_ok "microsocks is running"
        microsocks_running=true
    else
        print_warn "microsocks is not running"
        print_info "Starting microsocks..."

        systemctl enable microsocks 2>/dev/null || ignore_failure
        if systemctl start microsocks 2>/dev/null; then
            sleep 1
            if pgrep -x microsocks &>/dev/null; then
                print_ok "microsocks started"
                microsocks_running=true
            else
                # May have crashed immediately — check for GLIBC issue
                if ! microsocks_binary_works; then
                    print_warn "microsocks crashed (GLIBC incompatibility detected)"
                    if compile_microsocks_from_source; then
                        microsocks_running=true
                    fi
                else
                    print_fail "Failed to start microsocks"
                    print_info "Check: systemctl status microsocks"
                fi
            fi
        else
            # systemctl start failed — check for GLIBC issue
            if ! microsocks_binary_works; then
                print_warn "microsocks binary incompatible — compiling from source..."
                if compile_microsocks_from_source; then
                    microsocks_running=true
                fi
            else
                print_fail "Failed to start microsocks"
                print_info "Check: systemctl status microsocks"
            fi
        fi
    fi

    # Apply SOCKS authentication via dnstm (v0.6.8+) — only if microsocks is running
    if [[ "$microsocks_running" == true && "$SOCKS_AUTH" == true && -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
        print_info "Configuring SOCKS5 authentication via dnstm..."
        if dnstm backend auth -t socks -u "$SOCKS_USER" -p "$SOCKS_PASS"; then
            print_ok "SOCKS5 authentication enabled (user: ${SOCKS_USER})"
            # dnstm backend auth rewrites ExecStart and restarts microsocks;
            # give it a moment to come back up
            sleep 2
            if pgrep -x microsocks &>/dev/null || systemctl is-active --quiet microsocks 2>/dev/null; then
                print_ok "microsocks restarted with authentication"
            else
                print_warn "microsocks may not have restarted — check: systemctl status microsocks"
            fi
        else
            print_warn "Failed to configure SOCKS5 authentication via dnstm"
            print_info "Try manually: dnstm backend auth -t socks -u ${SOCKS_USER} -p <password>"
            SOCKS_AUTH=false
        fi
    fi

    if [[ "$microsocks_running" != true ]]; then
        print_warn "Skipping SOCKS proxy test — microsocks is not running"
        return
    fi

    # Detect actual microsocks port (3 methods, most reliable first)
    local socks_port=""
    # Method 1: parse ss output — find the listen port on the microsocks line
    socks_port=$(ss -tlnp 2>/dev/null | grep microsocks | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) {split($i,a,":"); print a[length(a)]; exit}}' || ignore_failure)
    # Method 2: parse the systemd unit file for -p flag
    if [[ -z "$socks_port" ]]; then
        socks_port=$(sed -n 's/.*-p[[:space:]]*\([0-9]*\).*/\1/p' /etc/systemd/system/microsocks.service 2>/dev/null | head -1 || ignore_failure)
    fi
    # Method 3: fallback
    if [[ -z "$socks_port" ]]; then
        socks_port="19801"
    fi

    # Test SOCKS proxy
    echo ""
    print_info "Testing SOCKS proxy on 127.0.0.1:${socks_port}..."
    local test_ip
    if [[ "$SOCKS_AUTH" == true ]]; then
        test_ip=$(curl -s --max-time 10 --socks5-basic --proxy "socks5://127.0.0.1:${socks_port}" --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" https://api.ipify.org 2>/dev/null || ignore_failure)
    else
        test_ip=$(curl -s --max-time 10 --socks5 "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null || ignore_failure)
    fi

    if [[ -n "$test_ip" ]]; then
        print_ok "SOCKS proxy works! Response: ${test_ip}"
    else
        print_warn "SOCKS proxy test failed (this may be OK if internet is restricted)"
        print_info "The proxy may still work for DNS tunnel clients"
    fi

    # Negative test: verify unauthenticated access is rejected when auth is enabled
    if [[ "$SOCKS_AUTH" == true && -n "$test_ip" ]]; then
        local noauth_ip
        noauth_ip=$(curl -s --max-time 5 --socks5 "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null || ignore_failure)
        if [[ -z "$noauth_ip" ]]; then
            print_ok "Auth enforced: unauthenticated connections are rejected"
        else
            print_warn "Auth NOT enforced: proxy works without credentials!"
            print_info "Try: dnstm backend auth -t socks -u ${SOCKS_USER} -p <password>"
        fi
    fi
}

# ─── STEP 10: SSH User (Optional) ──────────────────────────────────────────────

step_ssh_user() {
    print_step 10 "SSH Tunnel User"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip SSH tunnel user creation"
        return 0
    fi

    print_info "An SSH tunnel user allows clients to connect via Slipstream + SSH or DNSTT + SSH."
    print_info "This user can only create tunnels and has no shell access."
    print_warn "Without an SSH tunnel user, the SSH tunnels (s/ds) will NOT work."
    echo ""

    if ! prompt_yn "Create an SSH tunnel user? (required for SSH tunnels to work)" "y"; then
        print_warn "Skipping SSH user setup — SSH tunnels (s.${DOMAIN}, ds.${DOMAIN}) will not work"
        print_info "You can create one later with: sshtun-user create <username> --insecure-password <pass>"
        return
    fi

    echo ""

    # Install sshtun-user if not present
    if ! command -v sshtun-user &>/dev/null; then
        print_info "Downloading sshtun-user..."
        local arch
        arch=$(detect_architecture)
        if ensure_sshtun_user_binary "$arch"; then
            print_ok "Installed pinned sshtun-user for ${arch}"
        else
            print_fail "Failed to install pinned sshtun-user for ${arch} architecture"
            return
        fi
    else
        print_ok "sshtun-user already installed"
    fi

    # Configure SSH (only needed once)
    print_info "Applying SSH security configuration..."
    mkdir -p /run/sshd 2>/dev/null || ignore_failure

    # Back up sshd_config before any modification
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.dnstm-backup 2>/dev/null || ignore_failure
    fi

    local configure_output
    configure_output=$(timeout --kill-after=3 30 sshtun-user configure </dev/null 2>&1) || ignore_failure
    if echo "$configure_output" | grep -qi "already"; then
        print_ok "SSH already configured"
    elif echo "$configure_output" | grep -qi "error\|fail"; then
        print_warn "sshtun-user configure had issues:"
        echo -e "  ${DIM}${configure_output}${NC}"
    else
        print_ok "SSH configuration applied"
    fi

    # Validate sshd_config — rollback if broken
    if command -v sshd &>/dev/null && ! sshd -t 2>/dev/null; then
        print_warn "sshd_config validation failed — rolling back"
        if [[ -f /etc/ssh/sshd_config.dnstm-backup ]]; then
            cp -f /etc/ssh/sshd_config.dnstm-backup /etc/ssh/sshd_config
            print_ok "Restored sshd_config from backup"
        fi
    fi

    # Fix ETM-only MACs for client compatibility (Bitvise, older clients)
    fix_ssh_macs

    echo ""

    # Get username
    SSH_USER=$(prompt_input "Enter username for SSH tunnel user" "tunnel")
    SSH_USER=$(echo "$SSH_USER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$SSH_USER" ]]; then
        print_fail "Username cannot be empty"
        return
    fi
    if [[ "$SSH_USER" == *"|"* ]]; then
        print_fail "Username cannot contain the | character"
        return
    fi

    # Get password
    SSH_PASS=$(prompt_input "Enter password for SSH tunnel user")
    SSH_PASS=$(echo "$SSH_PASS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$SSH_PASS" ]]; then
        print_fail "Password cannot be empty"
        return
    fi
    if [[ "$SSH_PASS" == *"|"* ]]; then
        print_fail "Password cannot contain the | character"
        return
    fi

    echo ""

    # Create user
    print_info "Creating SSH tunnel user: ${SSH_USER}..."
    if timeout --kill-after=3 30 sshtun-user create "$SSH_USER" --insecure-password "$SSH_PASS" </dev/null 2>&1; then
        SSH_SETUP_DONE=true
        print_ok "SSH tunnel user created: ${SSH_USER}"
    else
        print_warn "User creation may have failed or user already exists"
        SSH_SETUP_DONE=true  # Still show in summary
    fi
    # Store credentials (root-only) for status page URL generation
    mkdir -p /etc/dnstm 2>/dev/null || ignore_failure
    write_file_atomic /etc/dnstm/ssh-credentials 0600 root root <<<"${SSH_USER}:${SSH_PASS}"
    chmod 600 /etc/dnstm/ssh-credentials

    # Verify and auto-fix sshd reachability on localhost (required for SSH tunnels)
    if ! timeout 3 bash -c 'echo | nc -w2 127.0.0.1 22' &>/dev/null; then
        print_warn "sshd NOT reachable on 127.0.0.1:22 — attempting auto-fix..."
        # Try restarting sshd first
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || ignore_failure
        sleep 1
        if ! timeout 3 bash -c 'echo | nc -w2 127.0.0.1 22' &>/dev/null; then
            # Check if firewall is blocking localhost
            if command -v iptables &>/dev/null; then
                # Allow SSH on localhost
                iptables -I INPUT -i lo -p tcp --dport 22 -j ACCEPT 2>/dev/null || ignore_failure
                print_info "Added firewall rule: allow SSH on localhost"
            fi
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
                ufw allow from 127.0.0.1 to any port 22 2>/dev/null || ignore_failure
                print_info "Added UFW rule: allow SSH from localhost"
            fi
            sleep 1
            if timeout 3 bash -c 'echo | nc -w2 127.0.0.1 22' &>/dev/null; then
                print_ok "sshd now reachable on 127.0.0.1:22"
            else
                print_warn "Could not auto-fix — SSH tunnels may not work"
                print_info "Manually check: sudo iptables -L -n | grep 22"
            fi
        else
            print_ok "sshd now reachable on 127.0.0.1:22 (after restart)"
        fi
    else
        print_ok "sshd reachable on 127.0.0.1:22"
    fi
}

# ─── STEP 11: Run Tests ────────────────────────────────────────────────────────

step_tests() {
    print_step 11 "Verification Tests"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip end-to-end tunnel tests"
        return 0
    fi

    local pass=0
    local fail=0

    # Test 1: SOCKS proxy — detect actual port
    echo -e "  ${BOLD}Test 1: SOCKS Proxy${NC}"
    local socks_port=""
    socks_port=$(ss -tlnp 2>/dev/null | grep microsocks | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) {split($i,a,":"); print a[length(a)]; exit}}' || ignore_failure)
    if [[ -z "$socks_port" ]]; then
        socks_port=$(sed -n 's/.*-p[[:space:]]*\([0-9]*\).*/\1/p' /etc/systemd/system/microsocks.service 2>/dev/null | head -1 || ignore_failure)
    fi
    if [[ -z "$socks_port" ]]; then
        socks_port="19801"
    fi

    local socks_result
    if [[ "$SOCKS_AUTH" == true ]]; then
        socks_result=$(curl -s --max-time 10 --socks5-basic --proxy "socks5://127.0.0.1:${socks_port}" --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" https://api.ipify.org 2>/dev/null || ignore_failure)
    else
        socks_result=$(curl -s --max-time 10 --socks5 "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null || ignore_failure)
    fi
    if [[ -n "$socks_result" ]]; then
        print_ok "SOCKS proxy: PASS (IP: ${socks_result}) on port ${socks_port}"
        pass=$((pass + 1))
        # Verify auth enforcement
        if [[ "$SOCKS_AUTH" == true ]]; then
            local noauth_result
            noauth_result=$(curl -s --max-time 5 --socks5 "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null || ignore_failure)
            if [[ -z "$noauth_result" ]]; then
                print_ok "SOCKS auth enforcement: PASS (unauthenticated rejected)"
                pass=$((pass + 1))
            else
                print_fail "SOCKS auth enforcement: FAIL (works without credentials!)"
                fail=$((fail + 1))
            fi
        fi
    elif ss -tlnp 2>/dev/null | grep -q "microsocks"; then
        print_warn "SOCKS proxy: LISTENING on port ${socks_port} but connectivity test failed"
        print_info "microsocks is running but outbound may be blocked or tunnels not ready"
        fail=$((fail + 1))
    else
        print_fail "SOCKS proxy: FAIL (microsocks not running)"
        fail=$((fail + 1))
    fi
    echo ""

    # Test 2: Tunnel list
    echo -e "  ${BOLD}Test 2: Tunnel Status${NC}"
    local tunnel_output
    tunnel_output=$(dnstm tunnel list 2>/dev/null || ignore_failure)
    if [[ -n "$tunnel_output" ]]; then
        local running_count
        running_count=$(echo "$tunnel_output" | grep -ci "running" || echo "0")
        local expected_tunnels=4
        [[ -x /usr/local/bin/noizdns-server ]] && expected_tunnels=6
        if [[ "$running_count" -ge "$expected_tunnels" ]]; then
            print_ok "All tunnels running: PASS (${running_count} running)"
            pass=$((pass + 1))
        elif [[ "$running_count" -ge 1 ]]; then
            print_warn "Some tunnels running: ${running_count}/${expected_tunnels}"
            pass=$((pass + 1))
        else
            print_fail "No tunnels running: FAIL"
            fail=$((fail + 1))
        fi
    else
        print_fail "Cannot get tunnel list: FAIL"
        fail=$((fail + 1))
    fi
    echo ""

    # Test 3: Router status
    echo -e "  ${BOLD}Test 3: DNS Router${NC}"
    if dnstm router status 2>/dev/null | grep -qi "running"; then
        print_ok "DNS Router: PASS (running)"
        pass=$((pass + 1))
    else
        print_fail "DNS Router: FAIL (not running)"
        fail=$((fail + 1))
    fi
    echo ""

    # Test 4: Port 53
    echo -e "  ${BOLD}Test 4: Port 53${NC}"
    if ss -ulnp 2>/dev/null | grep -E ':53\b' | grep -q "dnstm"; then
        print_ok "Port 53: PASS (dnstm listening)"
        pass=$((pass + 1))
    else
        print_fail "Port 53: FAIL (dnstm not listening)"
        fail=$((fail + 1))
    fi
    echo ""

    # Test 5: DNS delegation (end-to-end reachability)
    echo -e "  ${BOLD}Test 5: DNS Delegation${NC}"
    if command -v dig &>/dev/null; then
        local dig_result
        dig_result=$(dig +short +timeout=5 +tries=1 "dnstm-test.t.${DOMAIN}" @8.8.8.8 2>/dev/null || ignore_failure)
        if [[ -n "$dig_result" ]]; then
            print_ok "DNS delegation: PASS (query reached server via 8.8.8.8)"
            pass=$((pass + 1))
        else
            # Try Cloudflare resolver as fallback
            dig_result=$(dig +short +timeout=5 +tries=1 "dnstm-test.t.${DOMAIN}" @1.1.1.1 2>/dev/null || ignore_failure)
            if [[ -n "$dig_result" ]]; then
                print_ok "DNS delegation: PASS (query reached server via 1.1.1.1)"
                pass=$((pass + 1))
            else
                print_warn "DNS delegation: No response from public resolvers"
                print_info "This may mean DNS records are not set up correctly in Cloudflare,"
                print_info "or it may take a few minutes for DNS to propagate."
                print_info "Test manually: dig t.${DOMAIN} @8.8.8.8"
                fail=$((fail + 1))
            fi
        fi
    else
        print_info "DNS delegation: SKIPPED (dig not installed — install with: apt install dnsutils)"
        print_info "Test manually: nslookup t.${DOMAIN} 8.8.8.8"
        pass=$((pass + 1))
    fi
    echo ""

    # Test 6: SSH readiness
    echo -e "  ${BOLD}Test 6: SSH Tunnel Readiness${NC}"
    if ss -tlnp 2>/dev/null | grep -E ':22\b' | grep -q "sshd"; then
        if [[ "$SSH_SETUP_DONE" == true ]]; then
            print_ok "SSH: PASS (sshd running, tunnel user '${SSH_USER}' created)"
            pass=$((pass + 1))
        else
            print_warn "SSH: sshd running but no tunnel user created — SSH tunnels (s/ds) will not work"
            print_info "Create one with: sshtun-user create <username> --insecure-password <pass>"
            fail=$((fail + 1))
        fi
    else
        print_warn "SSH: sshd not detected on port 22 — SSH tunnels (s/ds) will not work"
        print_info "Start sshd with: systemctl start sshd"
        fail=$((fail + 1))
    fi
    echo ""

    # Summary
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    if [[ $fail -eq 0 ]]; then
        print_ok "${GREEN}All ${pass} tests passed!${NC}"
    else
        print_warn "${pass} passed, ${fail} failed"
        print_info "Check logs with: dnstm router logs / dnstm tunnel logs --tag <tag>"
    fi
}

# ─── STEP 12: Summary ──────────────────────────────────────────────────────────

step_summary() {
    print_step 12 "Setup Complete!"

    if [[ "$DRY_RUN" == true ]]; then
        print_info "Dry-run complete. No system changes were applied."
        echo ""
        return 0
    fi

    local w=54
    local border empty
    border=$(printf '═%.0s' $(seq 1 $w))
    empty=$(printf ' %.0s' $(seq 1 $w))
    local msg="SETUP COMPLETE!"
    local ml=$(( (w - ${#msg}) / 2 ))
    local mr=$(( w - ${#msg} - ml ))

    echo -e "${BOLD}${GREEN}"
    printf "  ╔%s╗\n" "$border"
    printf "  ║%s║\n" "$empty"
    printf "  ║%${ml}s%s%${mr}s║\n" "" "$msg" ""
    printf "  ║%s║\n" "$empty"
    printf "  ╚%s╝\n" "$border"
    echo -e "${NC}"

    echo -e "  ${BOLD}Server Information${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Server IP:     ${GREEN}${SERVER_IP}${NC}"
    echo -e "  Domain:        ${GREEN}${DOMAIN}${NC}"
    echo ""

    echo -e "  ${BOLD}Tunnel Endpoints${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Slipstream + SOCKS:  ${GREEN}t.${DOMAIN}${NC}"
    echo -e "  DNSTT + SOCKS:       ${GREEN}d.${DOMAIN}${NC}"
    if [[ -x /usr/local/bin/noizdns-server ]]; then
        echo -e "  NoizDNS + SOCKS:     ${GREEN}n.${DOMAIN}${NC}  ${DIM}(DPI-resistant)${NC}"
    fi
    echo -e "  Slipstream + SSH:    ${GREEN}s.${DOMAIN}${NC}"
    echo -e "  DNSTT + SSH:         ${GREEN}ds.${DOMAIN}${NC}"
    if [[ -x /usr/local/bin/noizdns-server ]]; then
        echo -e "  NoizDNS + SSH:       ${GREEN}z.${DOMAIN}${NC}  ${DIM}(DPI-resistant)${NC}"
    fi
    echo ""

    if [[ -n "$DNSTT_PUBKEY" ]]; then
        echo -e "  ${BOLD}DNSTT Public Keys${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}dnstt1 (SOCKS):${NC}  ${DNSTT_PUBKEY}"
        local _dnstt_ssh_pk=""
        if [[ -f /etc/dnstm/tunnels/dnstt-ssh/server.pub ]]; then
            _dnstt_ssh_pk=$(cat /etc/dnstm/tunnels/dnstt-ssh/server.pub 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$_dnstt_ssh_pk" ]]; then
            echo -e "  ${GREEN}dnstt-ssh (SSH):${NC} ${_dnstt_ssh_pk}"
        fi
        echo ""
    fi

    if [[ -n "$NOIZDNS_PUBKEY" ]]; then
        echo -e "  ${BOLD}NoizDNS Public Keys${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}noiz1 (SOCKS):${NC}   ${NOIZDNS_PUBKEY}"
        local _noiz_ssh_pk=""
        if [[ -f /etc/dnstm/tunnels/noiz-ssh/server.pub ]]; then
            _noiz_ssh_pk=$(cat /etc/dnstm/tunnels/noiz-ssh/server.pub 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$_noiz_ssh_pk" ]]; then
            echo -e "  ${GREEN}noiz-ssh (SSH):${NC}  ${_noiz_ssh_pk}"
        fi
        echo ""
    fi

    # Generate share URLs (dnst:// for dnstc CLI)
    echo -e "  ${BOLD}Share URLs — dnst:// (for dnstc CLI)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local share_url
    for tag in slip1 dnstt1 noiz1; do
        share_url=$(dnstm tunnel share -t "$tag" 2>/dev/null || ignore_failure)
        if [[ -n "$share_url" ]]; then
            echo -e "  ${GREEN}${tag}:${NC} ${share_url}"
        fi
    done
    if [[ "$SSH_SETUP_DONE" == true && -n "$SSH_USER" && -n "$SSH_PASS" ]]; then
        for tag in slip-ssh dnstt-ssh noiz-ssh; do
            share_url=$(dnstm tunnel share -t "$tag" --user "$SSH_USER" --password "$SSH_PASS" 2>/dev/null || ignore_failure)
            if [[ -n "$share_url" ]]; then
                echo -e "  ${GREEN}${tag}:${NC} ${share_url}"
            fi
        done
    fi
    echo ""

    # Generate SlipNet deep-link URLs (slipnet:// for SlipNet Android app)
    echo -e "  ${BOLD}Share URLs — slipnet:// (for SlipNet app)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local slipnet_url
    local s_user="" s_pass=""
    if [[ "$SOCKS_AUTH" == true ]]; then
        s_user="$SOCKS_USER"
        s_pass="$SOCKS_PASS"
    fi
    # Slipstream + SOCKS — SlipNet needs pubkey even for slipstream
    local _slip_pk=""
    _slip_pk=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
    slipnet_url=$(generate_slipnet_url "ss" "t" "$_slip_pk" "" "" "$s_user" "$s_pass")
    echo -e "  ${GREEN}slip1:${NC}    ${slipnet_url}"
    # DNSTT + SOCKS
    if [[ -n "$DNSTT_PUBKEY" ]]; then
        slipnet_url=$(generate_slipnet_url "dnstt" "d" "$DNSTT_PUBKEY" "" "" "$s_user" "$s_pass")
        echo -e "  ${GREEN}dnstt1:${NC}    ${slipnet_url}"
    fi
    # NoizDNS + SOCKS
    if [[ -n "$NOIZDNS_PUBKEY" ]]; then
        slipnet_url=$(generate_slipnet_url "sayedns" "n" "$NOIZDNS_PUBKEY" "" "" "$s_user" "$s_pass")
        echo -e "  ${GREEN}noiz1:${NC}     ${slipnet_url}"
    fi
    # SSH tunnels
    if [[ "$SSH_SETUP_DONE" == true && -n "$SSH_USER" && -n "$SSH_PASS" ]]; then
        local _any_pk=""
        _any_pk=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
        slipnet_url=$(generate_slipnet_url "slipstream_ssh" "s" "$_any_pk" "$SSH_USER" "$SSH_PASS" "$s_user" "$s_pass")
        echo -e "  ${GREEN}slip-ssh:${NC}  ${slipnet_url}"
        # dnstt-ssh has its own keypair
        local dnstt_ssh_pubkey=""
        if [[ -f /etc/dnstm/tunnels/dnstt-ssh/server.pub ]]; then
            dnstt_ssh_pubkey=$(cat /etc/dnstm/tunnels/dnstt-ssh/server.pub 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$dnstt_ssh_pubkey" ]]; then
            slipnet_url=$(generate_slipnet_url "dnstt_ssh" "ds" "$dnstt_ssh_pubkey" "$SSH_USER" "$SSH_PASS" "$s_user" "$s_pass")
            echo -e "  ${GREEN}dnstt-ssh:${NC} ${slipnet_url}"
        fi
        # NoizDNS + SSH
        local noiz_ssh_pubkey=""
        if [[ -f /etc/dnstm/tunnels/noiz-ssh/server.pub ]]; then
            noiz_ssh_pubkey=$(cat /etc/dnstm/tunnels/noiz-ssh/server.pub 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$noiz_ssh_pubkey" ]]; then
            slipnet_url=$(generate_slipnet_url "sayedns_ssh" "z" "$noiz_ssh_pubkey" "$SSH_USER" "$SSH_PASS" "$s_user" "$s_pass")
            echo -e "  ${GREEN}noiz-ssh:${NC}  ${slipnet_url}"
        fi
    fi
    echo ""

    if [[ "$SOCKS_AUTH" == true ]]; then
        echo -e "  ${BOLD}SOCKS Proxy Authentication${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  Username:  ${GREEN}${SOCKS_USER}${NC}"
        echo -e "  Password:  ${GREEN}${SOCKS_PASS}${NC}"
        echo ""
    else
        echo -e "  ${BOLD}SOCKS Proxy Authentication${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}⚠ No authentication — SOCKS tunnels (t/d) are open${NC}"
        echo ""
    fi

    if [[ "$SSH_SETUP_DONE" == true ]]; then
        echo -e "  ${BOLD}SSH Tunnel User${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  Username:  ${GREEN}${SSH_USER}${NC}"
        echo -e "  Password:  ${GREEN}${SSH_PASS}${NC}"
        echo -e "  Port:      ${GREEN}22${NC}"
        echo ""
    else
        echo -e "  ${BOLD}SSH Tunnel User${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}⚠ Not configured — SSH tunnels (s/ds) will not work${NC}"
        echo -e "  Create one with: ${BOLD}sshtun-user create <username> --insecure-password <pass>${NC}"
        echo ""
    fi

    echo -e "  ${BOLD}DNS Resolvers (use in SlipNet)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "  8.8.8.8:53        (Google)"
    echo "  1.1.1.1:53        (Cloudflare)"
    echo "  9.9.9.9:53        (Quad9)"
    echo "  208.67.222.222:53 (OpenDNS)"
    echo "  94.140.14.14:53   (AdGuard)"
    echo "  185.228.168.9:53  (CleanBrowsing)"
    echo ""

    echo -e "  ${BOLD}Client App${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "  SlipNet (Android): https://github.com/anonvector/SlipNet/releases"
    echo ""

    echo -e "  ${BOLD}Useful Commands${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "  dnstm tunnel list               Show all tunnels"
    echo "  dnstm tunnel share -t <tag>     Generate share URL"
    echo "  dnstm router status             Show router status"
    echo "  dnstm router logs               View router logs"
    echo "  dnstm tunnel logs --tag slip1   View tunnel logs"
    echo ""

    echo -e "  ${BOLD}Management TUI${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Run ${GREEN}dnstm-setup --manage${NC} to open the full management menu."
    echo "  From there you can:"
    echo "    - Add/remove tunnels and domains"
    echo "    - Add Xray backend (VLESS/VMess/Trojan)"
    echo "    - Manage SSH tunnel users"
    echo "    - Change DNSTT MTU"
    echo "    - View status, logs, and share URLs"
    echo "    - Update to latest version"
    echo "    - Harden or uninstall"
    echo ""

    echo -e "  ${DIM}Setup by dnstm-setup v${VERSION} — SamNet Technologies${NC}"
    echo -e "  ${DIM}https://github.com/SamNet-dev/dnstm-setup${NC}"
    echo ""
}

# ─── Install to PATH ─────────────────────────────────────────────────────────────

do_add_domain() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip adding a backup domain"
        return 0
    fi

    banner
    print_header "Add Backup Domain"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        print_fail "Not running as root. Please run with: sudo bash $0 --add-domain"
        exit 1
    fi

    # Check dnstm is installed
    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the full setup first: sudo bash $0"
        exit 1
    fi

    # Check router is running
    if ! dnstm router status 2>/dev/null | grep -qi "running"; then
        print_warn "DNS Router is not running. Starting it..."
        dnstm router start 2>/dev/null || ignore_failure
    fi

    # Ensure router is in multi mode (required for multiple domains)
    local current_mode
    current_mode=$(dnstm router mode 2>/dev/null | awk '/[Mm]ode/{for(i=1;i<=NF;i++) if($i=="multi"||$i=="single") print $i}' | head -1 || ignore_failure)
    if [[ "$current_mode" != "multi" ]]; then
        print_warn "Router mode is '${current_mode:-unknown}', switching to multi..."
        if dnstm router mode multi 2>/dev/null; then
            print_ok "Router mode switched to multi"
        else
            print_fail "Failed to switch router mode to multi. Multiple domains require multi mode."
            exit 1
        fi
    else
        print_ok "Router mode: multi"
    fi

    # Detect server IP
    SERVER_IP=$(fetch_public_ipv4 2>/dev/null || ignore_failure)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(prompt_input "Enter your server's public IP")
        if [[ -z "$SERVER_IP" ]]; then
            print_fail "Server IP is required."
            exit 1
        fi
    fi
    print_ok "Server IP: ${SERVER_IP}"

    # Show existing tunnels
    echo ""
    print_info "Current tunnels:"
    echo ""
    dnstm tunnel list 2>/dev/null || ignore_failure
    echo ""

    # Detect next tunnel number
    local num
    num=$(detect_next_tunnel_num)
    print_info "Next tunnel set number: ${num}"
    echo ""

    # Get existing tunnel domains for duplicate check
    local existing_domains
    existing_domains=$(dnstm tunnel list 2>/dev/null | grep -o 'domain=[^ ]*' | sed 's/domain=//;s/^[a-z0-9]*\.//' | sort -u || ignore_failure)

    # Use domain from argument if provided, otherwise prompt
    if [[ -n "$ADD_DOMAIN_ARG" ]]; then
        DOMAIN="$ADD_DOMAIN_ARG"
        DOMAIN=$(echo "$DOMAIN" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||;s|^https\?://||;s|/.*$||')
        if [[ -z "$DOMAIN" ]] || [[ ! "$DOMAIN" =~ \. ]]; then
            print_fail "Invalid domain: ${ADD_DOMAIN_ARG}"
            exit 1
        fi
        if [[ -n "$existing_domains" ]] && echo "$existing_domains" | grep -qx "$DOMAIN"; then
            print_fail "Domain '${DOMAIN}' is already in use by an existing tunnel."
            exit 1
        fi
    else
        # Interactive prompt — reopen /dev/tty in case stdin is a pipe
        while true; do
            echo -ne "  ${BOLD}Enter the new backup domain (e.g. backup.com)${NC} ${DIM}(h=help)${NC}: " >&2
            read -r DOMAIN </dev/tty || { print_fail "Cannot read input (stdin is a pipe). Pass domain as argument: --add-domain example.com"; exit 1; }
            DOMAIN=$(echo "$DOMAIN" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||;s|^https\?://||;s|/.*$||')
            if [[ -z "$DOMAIN" ]]; then
                print_fail "Domain cannot be empty. Please try again."
            elif [[ ! "$DOMAIN" =~ \. ]]; then
                print_fail "Invalid domain (must contain a dot). Please try again."
            elif [[ "$DOMAIN" =~ \.\. ]]; then
                print_fail "Invalid domain (consecutive dots not allowed). Please try again."
            elif [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
                print_fail "Invalid domain (use only letters, numbers, dots, hyphens). Please try again."
            elif [[ -n "$existing_domains" ]] && echo "$existing_domains" | grep -qx "$DOMAIN"; then
                print_fail "Domain '${DOMAIN}' is already in use by an existing tunnel. Please enter a different domain."
            else
                break
            fi
        done
    fi

    echo ""
    print_ok "Domain: ${DOMAIN}"
    echo ""

    # DNS record setup
    print_header "DNS Records for ${DOMAIN}"

    echo ""
    echo -e "  ${BOLD}How do you want to set up DNS records?${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  Automatic (Cloudflare API)"
    echo -e "  ${BOLD}2)${NC}  Manual (create in dashboard)"
    echo ""
    local dns_choice
    dns_choice=$(prompt_input "Select (1-2)" "2")

    if [[ "$dns_choice" == "1" ]]; then
        local cf_token
        cf_token=$(prompt_input "Cloudflare API Token")
        cf_token=$(echo "$cf_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$cf_token" ]]; then
            cloudflare_create_dns_records "$cf_token" "$DOMAIN" "$SERVER_IP" || ignore_failure
        else
            print_fail "API token cannot be empty"
            exit 1
        fi
    else
        print_info "Create these records in Cloudflare for ${BOLD}${DOMAIN}${NC}:"
        echo ""
        print_box \
            "Record 1:  Type: A   | Name: ns  | Value: ${SERVER_IP}" \
            "           Proxy: OFF (DNS Only - grey cloud)" \
            "" \
            "Record 2:  Type: NS  | Name: t   | Value: ns.${DOMAIN}" \
            "Record 3:  Type: NS  | Name: d   | Value: ns.${DOMAIN}" \
            "Record 4:  Type: NS  | Name: s   | Value: ns.${DOMAIN}" \
            "Record 5:  Type: NS  | Name: ds  | Value: ns.${DOMAIN}" \
            "Record 6:  Type: NS  | Name: n   | Value: ns.${DOMAIN}" \
            "Record 7:  Type: NS  | Name: z   | Value: ns.${DOMAIN}"

        echo ""
        print_warn "IMPORTANT: The A record MUST be DNS Only (grey cloud, NOT orange)"
        echo ""

        if ! prompt_yn "Have you created these DNS records in Cloudflare?" "n"; then
            echo ""
            print_info "Please create the DNS records and re-run: sudo bash $0 --add-domain"
            exit 0
        fi
    fi

    echo ""

    # Create tunnels with numbered tags
    local slip_tag="slip${num}"
    local dnstt_tag="dnstt${num}"
    local slip_ssh_tag="slip-ssh${num}"
    local dnstt_ssh_tag="dnstt-ssh${num}"

    print_header "Creating Tunnels for ${DOMAIN}"

    print_info "Creating 4 tunnels (set #${num}) for domain: ${BOLD}${DOMAIN}${NC}"
    echo ""

    # Detect existing SOCKS authentication via dnstm
    if detect_socks_auth; then
        print_ok "Detected existing SOCKS authentication (user: ${SOCKS_USER})"
    else
        print_info "SOCKS proxy has no authentication configured"
    fi
    echo ""

    # Ask for DNSTT MTU (use CLI value as default if provided via --mtu)
    local mtu_input
    mtu_input=$(prompt_input "DNSTT MTU size (512-1400, affects packet size)" "$DNSTT_MTU")
    if [[ "$mtu_input" =~ ^[0-9]+$ ]] && [[ "$mtu_input" -ge 512 ]] && [[ "$mtu_input" -le 1400 ]]; then
        DNSTT_MTU="$mtu_input"
    else
        print_warn "Invalid MTU value; using default ${DNSTT_MTU}"
    fi
    print_ok "DNSTT MTU: ${DNSTT_MTU}"
    echo ""

    # Tunnel 1: Slipstream + SOCKS
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel: Slipstream + SOCKS${NC}"
    echo ""
    if dnstm tunnel add --transport slipstream --backend socks --domain "t.${DOMAIN}" --tag "$slip_tag" 2>&1; then
        print_ok "Created: ${slip_tag} (Slipstream + SOCKS) on t.${DOMAIN}"
    else
        print_warn "Tunnel ${slip_tag} may already exist or creation failed"
    fi
    echo ""

    # Tunnel 2: DNSTT + SOCKS
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel: DNSTT + SOCKS${NC}"
    echo ""
    local dnstt_output
    dnstt_output=$(dnstm tunnel add --transport dnstt --backend socks --domain "d.${DOMAIN}" --tag "$dnstt_tag" --mtu "$DNSTT_MTU" 2>&1) || ignore_failure
    echo "$dnstt_output"

    DNSTT_PUBKEY=""
    if [[ -f "/etc/dnstm/tunnels/${dnstt_tag}/server.pub" ]]; then
        DNSTT_PUBKEY=$(cat "/etc/dnstm/tunnels/${dnstt_tag}/server.pub" 2>/dev/null || ignore_failure)
    fi

    if [[ -n "$DNSTT_PUBKEY" ]]; then
        print_ok "Created: ${dnstt_tag} (DNSTT + SOCKS) on d.${DOMAIN}"
        echo ""
        echo -e "  ${BOLD}${YELLOW}DNSTT Public Key (save this!):${NC}"
        echo -e "  ${GREEN}${DNSTT_PUBKEY}${NC}"
    else
        print_warn "Tunnel ${dnstt_tag} may already exist or creation failed"
    fi
    echo ""

    # Tunnel 3: Slipstream + SSH
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel: Slipstream + SSH${NC}"
    echo ""
    if dnstm tunnel add --transport slipstream --backend ssh --domain "s.${DOMAIN}" --tag "$slip_ssh_tag" 2>&1; then
        print_ok "Created: ${slip_ssh_tag} (Slipstream + SSH) on s.${DOMAIN}"
    else
        print_warn "Tunnel ${slip_ssh_tag} may already exist or creation failed"
    fi
    echo ""

    # Tunnel 4: DNSTT + SSH
    echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Tunnel: DNSTT + SSH${NC}"
    echo ""
    if dnstm tunnel add --transport dnstt --backend ssh --domain "ds.${DOMAIN}" --tag "$dnstt_ssh_tag" --mtu "$DNSTT_MTU" 2>&1; then
        print_ok "Created: ${dnstt_ssh_tag} (DNSTT + SSH) on ds.${DOMAIN}"
    else
        print_warn "Tunnel ${dnstt_ssh_tag} may already exist or creation failed"
    fi
    echo ""

    # Re-read DNSTT key if not captured
    if [[ -z "$DNSTT_PUBKEY" && -f "/etc/dnstm/tunnels/${dnstt_tag}/server.pub" ]]; then
        DNSTT_PUBKEY=$(cat "/etc/dnstm/tunnels/${dnstt_tag}/server.pub" 2>/dev/null || ignore_failure)
    fi

    # NoizDNS tunnels — download binary if not available, then create tunnels
    ensure_noizdns_binary || ignore_failure
    if [[ -x /usr/local/bin/noizdns-server ]]; then
        local noiz_tag="noiz${num}"
        local noiz_ssh_tag="noiz-ssh${num}"

        echo ""
        echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Tunnel: NoizDNS + SOCKS (DPI-resistant)${NC}"
        echo ""
        if dnstm tunnel add --transport dnstt --backend socks --domain "n.${DOMAIN}" --tag "$noiz_tag" --mtu "$DNSTT_MTU" 2>&1; then
            print_ok "Created: ${noiz_tag} (NoizDNS + SOCKS) on n.${DOMAIN}"
        else
            print_warn "Tunnel ${noiz_tag} may already exist or creation failed"
        fi
        create_noizdns_service_override "$noiz_tag" || print_warn "Could not set NoizDNS binary for ${noiz_tag}"

        # Extract NoizDNS pubkey
        if [[ -f "/etc/dnstm/tunnels/${noiz_tag}/server.pub" ]]; then
            NOIZDNS_PUBKEY=$(cat "/etc/dnstm/tunnels/${noiz_tag}/server.pub" 2>/dev/null || ignore_failure)
        fi
        echo ""

        echo -e "  ${DIM}───────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Tunnel: NoizDNS + SSH (DPI-resistant)${NC}"
        echo ""
        if dnstm tunnel add --transport dnstt --backend ssh --domain "z.${DOMAIN}" --tag "$noiz_ssh_tag" --mtu "$DNSTT_MTU" 2>&1; then
            print_ok "Created: ${noiz_ssh_tag} (NoizDNS + SSH) on z.${DOMAIN}"
        else
            print_warn "Tunnel ${noiz_ssh_tag} may already exist or creation failed"
        fi
        create_noizdns_service_override "$noiz_ssh_tag" || print_warn "Could not set NoizDNS binary for ${noiz_ssh_tag}"
        echo ""

        # Stop NoizDNS tunnels so they restart with the correct binary
        # (dnstm tunnel add auto-starts with dnstt-server, not noizdns-server)
        systemctl stop "dnstm-${noiz_tag}.service" 2>/dev/null || ignore_failure
        systemctl stop "dnstm-${noiz_ssh_tag}.service" 2>/dev/null || ignore_failure

        # Fix transport field if dnstm rewrote it from "dnstt" to "noizdns"
        fix_noizdns_transport
    fi

    print_ok "All tunnels created"
    echo ""

    # Reload systemd to pick up any service overrides (NoizDNS binary swap)
    systemctl daemon-reload 2>/dev/null || ignore_failure

    # Stop router while we start tunnels (router crash-loops if backends are dead)
    print_info "Stopping DNS Router..."
    dnstm router stop 2>/dev/null || ignore_failure
    sleep 1

    # Start new tunnels FIRST (before router)
    local _start_tags="$slip_tag $dnstt_tag $slip_ssh_tag $dnstt_ssh_tag"
    if [[ -x /usr/local/bin/noizdns-server ]]; then
        _start_tags+=" ${noiz_tag:-} ${noiz_ssh_tag:-}"
    fi
    print_info "Starting new tunnels..."
    for tag in $_start_tags; do
        [[ -z "$tag" ]] && continue
        if dnstm tunnel start --tag "$tag" 2>/dev/null; then
            print_ok "Started: ${tag}"
        else
            if dnstm_tag_exists "$tag" && dnstm tunnel list 2>/dev/null | grep -wF "$tag" | grep -qi "running"; then
                print_ok "Already running: ${tag}"
            else
                print_warn "Could not start: ${tag}. Check: dnstm tunnel logs --tag ${tag}"
            fi
        fi
    done

    # Verify NoizDNS tunnels started — remove dead ones to protect router
    sleep 3
    for _ntag in ${noiz_tag:-} ${noiz_ssh_tag:-}; do
        [[ -z "$_ntag" ]] && continue
        if dnstm_tag_exists "$_ntag"; then
            if ! systemctl is-active --quiet "dnstm-${_ntag}.service" 2>/dev/null; then
                # Retry — give it more time before removing
                print_info "Waiting for ${_ntag} to start..."
                sleep 5
                systemctl restart "dnstm-${_ntag}.service" 2>/dev/null || ignore_failure
                sleep 3
                if systemctl is-active --quiet "dnstm-${_ntag}.service" 2>/dev/null; then
                    print_ok "NoizDNS tunnel ${_ntag} started successfully (after retry)"
                    continue
                fi
                print_warn "NoizDNS tunnel ${_ntag} failed to start — removing to protect DNS Router"
                dnstm tunnel stop --tag "$_ntag" 2>/dev/null || ignore_failure
                dnstm tunnel remove --tag "$_ntag" 2>/dev/null || ignore_failure
                rm -f "/etc/systemd/system/dnstm-${_ntag}.service.d/10-noizdns-binary.conf" 2>/dev/null || ignore_failure
                rmdir "/etc/systemd/system/dnstm-${_ntag}.service.d" 2>/dev/null || ignore_failure
                systemctl daemon-reload 2>/dev/null || ignore_failure
                print_info "Removed ${_ntag} — other tunnels will work normally"
            fi
        fi
    done

    # Fix transport field if dnstm rewrote it during start
    fix_noizdns_transport

    # NOW start the router (all backends are healthy)
    echo ""
    print_info "Starting DNS Router..."
    if dnstm router start 2>/dev/null; then
        print_ok "DNS Router restarted"
    else
        print_warn "DNS Router restart may have issues. Check: dnstm router logs"
    fi

    echo ""
    print_info "All tunnels:"
    echo ""
    dnstm tunnel list 2>/dev/null || ignore_failure
    echo ""

    if apply_service_hardening; then
        print_ok "Runtime hardening applied to dnstm and microsocks services"
    else
        print_warn "Runtime hardening reported issues; review systemctl status for dnstm units"
    fi

    # Summary
    local w=54
    local border empty
    border=$(printf '═%.0s' $(seq 1 $w))
    empty=$(printf ' %.0s' $(seq 1 $w))
    local msg="DOMAIN ADDED!"
    local ml=$(( (w - ${#msg}) / 2 ))
    local mr=$(( w - ${#msg} - ml ))

    echo -e "${BOLD}${GREEN}"
    printf "  ╔%s╗\n" "$border"
    printf "  ║%s║\n" "$empty"
    printf "  ║%${ml}s%s%${mr}s║\n" "" "$msg" ""
    printf "  ║%s║\n" "$empty"
    printf "  ╚%s╝\n" "$border"
    echo -e "${NC}"

    echo -e "  ${BOLD}Server Information${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Server IP:     ${GREEN}${SERVER_IP}${NC}"
    echo -e "  Domain:        ${GREEN}${DOMAIN}${NC}"
    echo ""

    echo -e "  ${BOLD}Tunnel Endpoints${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Slipstream + SOCKS:  ${GREEN}t.${DOMAIN}${NC}  (${slip_tag})"
    echo -e "  DNSTT + SOCKS:       ${GREEN}d.${DOMAIN}${NC}  (${dnstt_tag})"
    if [[ -n "${noiz_tag:-}" ]]; then
        echo -e "  NoizDNS + SOCKS:     ${GREEN}n.${DOMAIN}${NC}  (${noiz_tag})  ${DIM}(DPI-resistant)${NC}"
    fi
    echo -e "  Slipstream + SSH:    ${GREEN}s.${DOMAIN}${NC}  (${slip_ssh_tag})"
    echo -e "  DNSTT + SSH:         ${GREEN}ds.${DOMAIN}${NC}  (${dnstt_ssh_tag})"
    if [[ -n "${noiz_ssh_tag:-}" ]]; then
        echo -e "  NoizDNS + SSH:       ${GREEN}z.${DOMAIN}${NC}  (${noiz_ssh_tag})  ${DIM}(DPI-resistant)${NC}"
    fi
    echo ""

    if [[ -n "$DNSTT_PUBKEY" ]]; then
        echo -e "  ${BOLD}DNSTT Public Keys${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}${dnstt_tag} (SOCKS):${NC}  ${DNSTT_PUBKEY}"
        local _dnstt_ssh_pk=""
        if [[ -f "/etc/dnstm/tunnels/${dnstt_ssh_tag}/server.pub" ]]; then
            _dnstt_ssh_pk=$(cat "/etc/dnstm/tunnels/${dnstt_ssh_tag}/server.pub" 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$_dnstt_ssh_pk" ]]; then
            echo -e "  ${GREEN}${dnstt_ssh_tag} (SSH):${NC} ${_dnstt_ssh_pk}"
        fi
        echo ""
    fi

    if [[ -n "${NOIZDNS_PUBKEY:-}" ]]; then
        echo -e "  ${BOLD}NoizDNS Public Keys${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}${noiz_tag} (SOCKS):${NC}   ${NOIZDNS_PUBKEY}"
        local _noiz_ssh_pk=""
        if [[ -n "${noiz_ssh_tag:-}" && -f "/etc/dnstm/tunnels/${noiz_ssh_tag}/server.pub" ]]; then
            _noiz_ssh_pk=$(cat "/etc/dnstm/tunnels/${noiz_ssh_tag}/server.pub" 2>/dev/null || ignore_failure)
        fi
        if [[ -n "$_noiz_ssh_pk" ]]; then
            echo -e "  ${GREEN}${noiz_ssh_tag} (SSH):${NC}  ${_noiz_ssh_pk}"
        fi
        echo ""
    fi

    # Generate share URLs for new tunnels (dnst:// for dnstc CLI)
    echo -e "  ${BOLD}Share URLs — dnst:// (for dnstc CLI)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local share_url
    local _socks_tags="$slip_tag $dnstt_tag"
    [[ -n "${noiz_tag:-}" ]] && _socks_tags+=" $noiz_tag"
    for tag in $_socks_tags; do
        share_url=$(dnstm tunnel share -t "$tag" 2>/dev/null || ignore_failure)
        if [[ -n "$share_url" ]]; then
            echo -e "  ${GREEN}${tag}:${NC} ${share_url}"
        fi
    done
    echo ""
    echo -e "  ${DIM}Note: SSH tunnel share URLs require credentials. Generate them with:${NC}"
    echo -e "  ${DIM}  dnstm tunnel share -t ${slip_ssh_tag} --user <username> --password <pass>${NC}"
    echo -e "  ${DIM}  dnstm tunnel share -t ${dnstt_ssh_tag} --user <username> --password <pass>${NC}"
    if [[ -n "${noiz_ssh_tag:-}" ]]; then
        echo -e "  ${DIM}  dnstm tunnel share -t ${noiz_ssh_tag} --user <username> --password <pass>${NC}"
    fi
    echo ""

    # Generate SlipNet deep-link URLs for new tunnels (slipnet:// for SlipNet app)
    echo -e "  ${BOLD}Share URLs — slipnet:// (for SlipNet app)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local slipnet_url
    local s_user="" s_pass=""
    if [[ "$SOCKS_AUTH" == true ]]; then
        s_user="$SOCKS_USER"
        s_pass="$SOCKS_PASS"
    fi
    local _slip_pk2=""
    _slip_pk2=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
    slipnet_url=$(generate_slipnet_url "ss" "t" "$_slip_pk2" "" "" "$s_user" "$s_pass")
    echo -e "  ${GREEN}${slip_tag}:${NC}      ${slipnet_url}"
    if [[ -n "$DNSTT_PUBKEY" ]]; then
        slipnet_url=$(generate_slipnet_url "dnstt" "d" "$DNSTT_PUBKEY" "" "" "$s_user" "$s_pass")
        echo -e "  ${GREEN}${dnstt_tag}:${NC}     ${slipnet_url}"
    fi
    if [[ -n "${NOIZDNS_PUBKEY:-}" ]]; then
        slipnet_url=$(generate_slipnet_url "sayedns" "n" "$NOIZDNS_PUBKEY" "" "" "$s_user" "$s_pass")
        echo -e "  ${GREEN}${noiz_tag}:${NC}      ${slipnet_url}"
    fi

    # Ask user for SSH credentials to generate SSH tunnel URLs
    echo ""
    if prompt_yn "Generate SSH tunnel slipnet:// URLs?" "y"; then
        local ssh_tun_user ssh_tun_pass
        ssh_tun_user=$(prompt_input "SSH tunnel username")
        ssh_tun_pass=$(prompt_input "SSH tunnel password")
        if [[ "$ssh_tun_user" == *"|"* || "$ssh_tun_pass" == *"|"* ]]; then
            print_fail "Username/password cannot contain the | character"
        elif [[ -n "$ssh_tun_user" && -n "$ssh_tun_pass" ]]; then
            local _any_pk2=""
            _any_pk2=$(cat /etc/dnstm/tunnels/*/server.pub 2>/dev/null | head -1 || ignore_failure)
            slipnet_url=$(generate_slipnet_url "slipstream_ssh" "s" "$_any_pk2" "$ssh_tun_user" "$ssh_tun_pass" "$s_user" "$s_pass")
            echo -e "  ${GREEN}${slip_ssh_tag}:${NC}  ${slipnet_url}"
            # dnstt-ssh has its own keypair — read from its own tunnel dir
            local _dnstt_ssh_pk=""
            if [[ -f "/etc/dnstm/tunnels/${dnstt_ssh_tag}/server.pub" ]]; then
                _dnstt_ssh_pk=$(cat "/etc/dnstm/tunnels/${dnstt_ssh_tag}/server.pub" 2>/dev/null || ignore_failure)
            fi
            if [[ -n "$_dnstt_ssh_pk" ]]; then
                slipnet_url=$(generate_slipnet_url "dnstt_ssh" "ds" "$_dnstt_ssh_pk" "$ssh_tun_user" "$ssh_tun_pass" "$s_user" "$s_pass")
                echo -e "  ${GREEN}${dnstt_ssh_tag}:${NC} ${slipnet_url}"
            fi
            if [[ -n "${NOIZDNS_PUBKEY:-}" && -n "${noiz_ssh_tag:-}" ]]; then
                local _noiz_ssh_pk2=""
                if [[ -f "/etc/dnstm/tunnels/${noiz_ssh_tag}/server.pub" ]]; then
                    _noiz_ssh_pk2=$(cat "/etc/dnstm/tunnels/${noiz_ssh_tag}/server.pub" 2>/dev/null || ignore_failure)
                fi
                if [[ -n "$_noiz_ssh_pk2" ]]; then
                    slipnet_url=$(generate_slipnet_url "sayedns_ssh" "z" "$_noiz_ssh_pk2" "$ssh_tun_user" "$ssh_tun_pass" "$s_user" "$s_pass")
                    echo -e "  ${GREEN}${noiz_ssh_tag}:${NC} ${slipnet_url}"
                fi
            fi
        else
            echo -e "  ${DIM}Skipped — username or password was empty.${NC}"
        fi
    fi
    echo ""

    echo -e "  ${DIM}To add more domains, run again: sudo bash $0 --add-domain${NC}"
    echo ""
}

main() {
    banner
    echo -e "  ${DIM}Tip: Press 'h' at any prompt for help${NC}"

    step_preflight
    step_ask_domain
    step_dns_records
    step_free_port53
    step_install_dnstm
    step_verify_port53
    step_create_tunnels
    step_start_services
    step_verify_microsocks
    step_ssh_user
    step_tests
    install_to_path
    step_summary
    unset SSH_PASS 2>/dev/null || ignore_failure
}
