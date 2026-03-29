# shellcheck shell=bash

set -euo pipefail

if [[ -n "${DNSTM_FIREWALL_SH_LOADED:-}" ]]; then
    return 0
fi
readonly DNSTM_FIREWALL_SH_LOADED=1

write_public_dns_resolver_file() {
    local target="$1"
    if [[ "$DRY_RUN" != true ]]; then
        DNS_CLEANUP_REQUESTED=true
    fi
    chattr -i "$target" 2>/dev/null || ignore_failure
    rm -f "$target" 2>/dev/null || ignore_failure
    write_file_atomic "$target" 0644 root root <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
}

_dnstm_cleanup_dns() {
    # If resolv.conf is empty, missing, points at a dead stub, or has no nameservers, fix it.
    local _needs_dns_fix=false
    if [[ ! -s /etc/resolv.conf ]]; then
        _needs_dns_fix=true
    elif grep -q '127\.0\.0\.53' /etc/resolv.conf 2>/dev/null && \
         ! ss -ulnp 2>/dev/null | grep -q '127\.0\.0\.53.*systemd-resolve'; then
        _needs_dns_fix=true
    elif ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
        _needs_dns_fix=true
    fi
    if [[ "$_needs_dns_fix" == true ]]; then
        write_public_dns_resolver_file /etc/resolv.conf || ignore_failure
    fi
}

ensure_resolv_conf_fallback() {
    # After stopping systemd-resolved, /etc/resolv.conf may still point to
    # 127.0.0.53 which is now dead, or be a symlink to resolved's file with
    # no nameservers.  Write a fallback and lock it so nothing can overwrite it.
    local needs_fix=false
    if [[ ! -s /etc/resolv.conf ]]; then
        needs_fix=true
    elif grep -q '127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        needs_fix=true
    elif ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
        # File exists but has no nameserver lines (e.g. resolved uplink mode with no DNS)
        needs_fix=true
    fi
    if [[ "$needs_fix" == true ]]; then
        print_info "Updating /etc/resolv.conf with public DNS fallback"
        write_public_dns_resolver_file /etc/resolv.conf
        # Lock so systemd-resolved or package manager can't overwrite
        chattr +i /etc/resolv.conf 2>/dev/null || ignore_failure
    fi
}

configure_systemd_resolved_no_stub() {
    # Keep system DNS working while freeing port 53 from the local stub listener.
    if ! command -v systemctl &>/dev/null; then
        print_warn "systemctl not found; skipping resolver hardening"
        return 0
    fi

    if ! systemctl cat systemd-resolved.service &>/dev/null; then
        print_warn "systemd-resolved is not installed; skipping resolver hardening"
        return 0
    fi

    mkdir -p /etc/systemd/resolved.conf.d
    write_file_atomic /etc/systemd/resolved.conf.d/10-dnstm-no-stub.conf 0644 root root <<'EOF'
[Resolve]
DNSStubListener=no
DNS=8.8.8.8 1.1.1.1
EOF

    # Unlock resolv.conf, write direct nameservers (NOT a symlink to resolved),
    # then lock it so nothing (package manager, resolved restart) can overwrite it.
    write_public_dns_resolver_file /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || ignore_failure

    systemctl unmask systemd-resolved.service systemd-resolved.socket 2>/dev/null || ignore_failure
    systemctl enable systemd-resolved.service 2>/dev/null || ignore_failure
    systemctl restart systemd-resolved.service 2>/dev/null || ignore_failure

    # Verify DNS actually works
    sleep 1
    local dns_ok=false
    if getent hosts github.com &>/dev/null 2>&1; then
        dns_ok=true
    elif curl -sf --max-time 3 https://api.ipify.org &>/dev/null 2>&1; then
        dns_ok=true
    fi

    if [[ "$dns_ok" != "true" ]]; then
        print_warn "DNS not working — check /etc/resolv.conf"
        return 1
    fi

    return 0
}

write_service_override() {
    local unit="$1"
    local run_user="$2"
    local run_group="$3"
    local needs_bind_cap="${4:-no}"
    local dropin_dir="/etc/systemd/system/${unit}.d"
    local dropin_file="${dropin_dir}/20-hardening.conf"

    mkdir -p "$dropin_dir"

    write_file_atomic "$dropin_file" 0644 root root <<EOF
[Service]
User=${run_user}
Group=${run_group}
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ReadWritePaths=/etc/dnstm
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0077
$(if [[ "$needs_bind_cap" == "yes" ]]; then cat <<'CAPEOF'
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
CAPEOF
else cat <<'CAPEOF'
AmbientCapabilities=
CapabilityBoundingSet=
CAPEOF
fi)
EOF
}

unit_exists() {
    local unit="$1"
    systemctl cat "$unit" >/dev/null 2>&1
}

enable_autostart_units() {
    local dnstm_units unit
    dnstm_units=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^dnstm-.*\.service$/ {print $1}' || ignore_failure)
    for unit in $dnstm_units microsocks.service; do
        if ! unit_exists "$unit"; then
            continue
        fi
        if ! systemctl enable "$unit" >/dev/null 2>&1; then
            print_warn "Could not enable ${unit} for boot autostart"
        fi
    done
    print_ok "Boot autostart enabled for dnstm and microsocks services"
}

apply_service_hardening() {
    print_info "Applying least-privilege service hardening..."

    if ! id -u dnstm &>/dev/null; then
        if useradd --system --home /nonexistent --shell /usr/sbin/nologin dnstm 2>/dev/null; then
            print_ok "Created service account: dnstm"
        else
            print_fail "Could not create service account: dnstm"
            return 1
        fi
    fi

    if [[ -d /etc/dnstm ]]; then
        chown -R root:dnstm /etc/dnstm 2>/dev/null || ignore_failure
        find /etc/dnstm -type d -exec chmod 750 {} + 2>/dev/null || ignore_failure
        find /etc/dnstm -type f -exec chmod 640 {} + 2>/dev/null || ignore_failure
        find /etc/dnstm -type f \( -name "*.pub" -o -name "cert.pem" \) -exec chmod 644 {} + 2>/dev/null || ignore_failure
        find /etc/dnstm -type f \( -name "*.key" -o -name "server.key" \) -exec chmod 640 {} + 2>/dev/null || ignore_failure
        print_ok "Hardened /etc/dnstm ownership and permissions"
    else
        print_warn "/etc/dnstm not found yet; skipping file permission hardening"
    fi

    local dnstm_units
    dnstm_units=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^dnstm-.*\.service$/ {print $1}' || ignore_failure)
    if [[ -z "$dnstm_units" ]]; then
        print_warn "No dnstm systemd units found to harden"
        return 0
    fi

    local unit
    for unit in $dnstm_units; do
        if [[ "$unit" == "dnstm-dnsrouter.service" ]]; then
            write_service_override "$unit" "dnstm" "dnstm" "yes"
        else
            write_service_override "$unit" "dnstm" "dnstm" "no"
        fi
    done

    if unit_exists "microsocks.service"; then
        write_service_override "microsocks.service" "nobody" "nogroup" "no"
    fi

    systemctl daemon-reload 2>/dev/null || ignore_failure

    local hardening_ok=true
    for unit in $dnstm_units microsocks.service; do
        if ! unit_exists "$unit"; then
            continue
        fi
        if systemctl is-enabled "$unit" &>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
            if ! systemctl restart "$unit" 2>/dev/null; then
                print_warn "Failed to restart hardened unit: $unit — rolling back"
                local dropin="/etc/systemd/system/${unit}.d/20-hardening.conf"
                rm -f "$dropin"
                systemctl daemon-reload 2>/dev/null || ignore_failure
                systemctl reset-failed "$unit" 2>/dev/null || ignore_failure
                systemctl restart "$unit" 2>/dev/null || ignore_failure
                hardening_ok=false
            fi
        fi
    done

    if [[ "$hardening_ok" != "true" ]]; then
        print_warn "Some units could not be hardened; services restored without hardening"
        return 1
    fi

    enable_autostart_units
    print_ok "Applied systemd hardening overrides"
    return 0
}

# ─── Change MTU ──────────────────────────────────────────────────────────────────

do_change_mtu() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip DNSTT MTU override changes"
        return 0
    fi

    banner
    print_header "Change DNSTT MTU"

    if [[ $EUID -ne 0 ]]; then
        print_fail "Not running as root."
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed."
        return 1
    fi

    # Find DNSTT tunnels from dnstm
    local tunnel_output
    tunnel_output=$(dnstm tunnel list 2>/dev/null || ignore_failure)
    if [[ -z "$tunnel_output" ]]; then
        print_warn "No tunnels found."
        return 0
    fi

    # Find DNSTT service files by looking for dnstt-server in ExecStart
    local dnstt_svcs=()
    local dnstt_tags=()
    local svc_files
    svc_files=$(find /etc/systemd/system -maxdepth 1 -name 'dnstm*.service' -o -name 'dnsrouter*.service' 2>/dev/null || ignore_failure)
    # Also check for dnstm tunnel list tag-based discovery
    local all_tags
    all_tags=$(echo "$tunnel_output" | grep -oE 'tag=[^ ]+' | sed 's/tag=//' || ignore_failure)
    [[ -z "$all_tags" && -n "$tunnel_output" ]] && \
        all_tags=$(echo "$tunnel_output" | grep -oE '\b(slip|dnstt|noiz|xray)[a-z0-9_-]*' | sort -u || ignore_failure)

    # Method 1: Find services containing dnstt-server in ExecStart
    for svc_file in $svc_files; do
        if grep -q 'dnstt-server\|dnstt' "$svc_file" 2>/dev/null; then
            local svc_name
            svc_name=$(basename "$svc_file")
            local exec_line
            exec_line=$(grep '^ExecStart=' "$svc_file" 2>/dev/null | tail -1 || ignore_failure)
            # Only include if it actually runs dnstt-server (not router)
            if echo "$exec_line" | grep -q 'dnstt-server'; then
                dnstt_svcs+=("$svc_name")
                local tag_name
                tag_name=$(echo "$svc_name" | sed 's/^dnstm-tunnel-//;s/^dnstm-//;s/\.service$//')
                dnstt_tags+=("$tag_name")
            fi
        fi
    done

    # Method 2: If Method 1 found nothing, try from dnstm tunnel list
    if [[ ${#dnstt_svcs[@]} -eq 0 ]]; then
        for tag in $all_tags; do
            # Skip noiz tunnels — they don't support MTU
            if [[ "$tag" == noiz* ]]; then
                continue
            fi
            if echo "$tunnel_output" | grep -wF "$tag" | grep -qi "transport=dnstt\|dnstt"; then
                # Try common service name patterns
                local found_svc=""
                for pattern in "dnstm-tunnel-${tag}.service" "dnstm-${tag}.service"; do
                    if systemctl cat "$pattern" &>/dev/null; then
                        # Verify it actually runs dnstt-server, not noiz
                        if systemctl cat "$pattern" 2>/dev/null | grep -q 'dnstt-server'; then
                            found_svc="$pattern"
                            break
                        fi
                    fi
                done
                if [[ -n "$found_svc" ]]; then
                    dnstt_svcs+=("$found_svc")
                    dnstt_tags+=("$tag")
                fi
            fi
        done
    fi

    if [[ ${#dnstt_svcs[@]} -eq 0 ]]; then
        print_warn "No DNSTT tunnel services found. MTU only applies to DNSTT tunnels."
        return 0
    fi

    # Show current MTU for each DNSTT tunnel
    echo ""
    print_info "Current DNSTT tunnels and MTU values:"
    echo ""
    local i
    for i in "${!dnstt_svcs[@]}"; do
        local svc="${dnstt_svcs[$i]}"
        local tag="${dnstt_tags[$i]}"
        local exec_line
        exec_line=$(systemctl cat "$svc" 2>/dev/null | grep '^ExecStart=' | tail -1 || ignore_failure)
        local current_mtu
        current_mtu=$(echo "$exec_line" | grep -oE '\-mtu\s+[0-9]+' | grep -oE '[0-9]+' || ignore_failure)
        if [[ -z "$current_mtu" ]]; then
            current_mtu="default (1232)"
        fi
        echo -e "  ${BOLD}${tag}${NC}: MTU = ${GREEN}${current_mtu}${NC}  ${DIM}(${svc})${NC}"
    done

    echo ""
    local new_mtu
    new_mtu=$(prompt_input "Enter new MTU value for ALL DNSTT tunnels (512-1400)" "1100")
    new_mtu=$(echo "$new_mtu" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if ! [[ "$new_mtu" =~ ^[0-9]+$ ]] || [[ "$new_mtu" -lt 512 ]] || [[ "$new_mtu" -gt 1400 ]]; then
        print_fail "Invalid MTU value. Must be 512-1400."
        return 1
    fi

    echo ""
    print_info "Setting MTU to ${new_mtu} on all DNSTT tunnels..."

    local changed=0
    for i in "${!dnstt_svcs[@]}"; do
        local svc="${dnstt_svcs[$i]}"
        local tag="${dnstt_tags[$i]}"
        local exec_line
        exec_line=$(systemctl cat "$svc" 2>/dev/null | grep '^ExecStart=' | tail -1 || ignore_failure)
        if [[ -z "$exec_line" ]]; then
            print_warn "Could not read ExecStart for ${tag}, skipping"
            continue
        fi

        local new_exec
        if echo "$exec_line" | grep -qE '\-mtu\s+[0-9]+'; then
            # Replace existing MTU
            new_exec=$(echo "$exec_line" | sed -E "s/-mtu\s+[0-9]+/-mtu ${new_mtu}/")
        else
            # Add MTU after -udp :PORT
            new_exec=$(echo "$exec_line" | sed -E "s/(-udp\s+:[0-9]+)/\1 -mtu ${new_mtu}/")
        fi

        # Write override
        local override_dir="/etc/systemd/system/${svc}.d"
        mkdir -p "$override_dir"
        write_file_atomic "${override_dir}/mtu-override.conf" 0644 root root <<MTEOF
[Service]
ExecStart=
${new_exec}
MTEOF

        print_ok "${tag}: MTU → ${new_mtu}"
        ((changed += 1))
    done

    if [[ $changed -gt 0 ]]; then
        systemctl daemon-reload
        echo ""
        print_info "Restarting DNSTT tunnels..."
        for svc in "${dnstt_svcs[@]}"; do
            systemctl restart "$svc" 2>/dev/null || ignore_failure
        done
        sleep 2
        # Restart router to pick up changes
        if systemctl is-active dnstm-router &>/dev/null; then
            systemctl restart dnstm-router 2>/dev/null || ignore_failure
        fi
        echo ""
        print_ok "MTU updated to ${new_mtu} on ${changed} tunnel(s). Keys unchanged."
    else
        print_warn "No tunnels were modified."
    fi
}

# ─── --harden ────────────────────────────────────────────────────────────────────

do_harden() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip service hardening changes"
        return 0
    fi

    banner
    print_header "Security Hardening Mode"

    if [[ $EUID -ne 0 ]]; then
        print_fail "Not running as root. Please run with: sudo bash $0 --harden"
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the setup first before hardening."
        exit 1
    fi

    configure_systemd_resolved_no_stub || ignore_failure
    if apply_service_hardening; then
        print_ok "Runtime hardening applied"
    else
        print_warn "Runtime hardening reported issues; review systemctl status for dnstm units"
    fi

    echo ""
    print_info "Current unit users:"
    for unit in dnstm-dnsrouter.service dnstm-dnstt1.service dnstm-slip1.service dnstm-dnstt-ssh.service dnstm-slip-ssh.service microsocks.service; do
        if unit_exists "$unit"; then
            systemctl show -p User -p Group "$unit" 2>/dev/null || ignore_failure
        fi
    done
    echo ""
    print_ok "Hardening complete."
}

# ─── --remove-tunnel ─────────────────────────────────────────────────────────────
