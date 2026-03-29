# shellcheck shell=bash

set -euo pipefail

if [[ -n "${DNSTM_XRAY_SH_LOADED:-}" ]]; then
    return 0
fi
readonly DNSTM_XRAY_SH_LOADED=1

install_3xui() {
    local admin_user="$1"
    local admin_pass="$2"
    local panel_port="$3"

    # Ensure sqlite3 is available (needed to set credentials after install)
    if ! command -v sqlite3 &>/dev/null; then
        print_info "Installing sqlite3 (needed for panel credential setup)..."
        apt-get install -y -qq sqlite3 2>/dev/null || ignore_failure
    fi

    print_info "Downloading and installing 3x-ui..."
    echo ""

    # Download the pinned install script
    local install_script
    install_script=$(mktemp)
    if ! fetch_verified_script "$THREE_X_UI_INSTALL_SCRIPT_URL" "$THREE_X_UI_INSTALL_SCRIPT_SHA256" "$install_script" "3x-ui ${THREE_X_UI_VERSION_PIN}"; then
        rm -f "$install_script"
        print_fail "Could not download 3x-ui install script."
        return 1
    fi

    # Run non-interactively with 'y' piped for prompts
    local install_log
    install_log=$(mktemp)
    if ! echo "y" | bash "$install_script" > "$install_log" 2>&1; then
        tail -5 "$install_log"
        rm -f "$install_log" "$install_script"
        print_fail "3x-ui installation failed."
        return 1
    fi
    tail -5 "$install_log"
    rm -f "$install_log" "$install_script"

    # Wait for service to start
    sleep 3

    if ! systemctl is-active --quiet x-ui 2>/dev/null; then
        print_fail "3x-ui service did not start."
        return 1
    fi
    print_ok "3x-ui installed and running"

    # Set custom credentials and port
    # IMPORTANT: if setting fails, we must output the ACTUAL values so the caller
    # uses correct credentials for the API (avoids mismatch)
    INSTALL_3XUI_ACTUAL_USER="$admin_user"
    INSTALL_3XUI_ACTUAL_PASS="$admin_pass"
    INSTALL_3XUI_ACTUAL_PORT="$panel_port"

    # --- Set credentials ---
    # Prefer x-ui binary (handles password hashing for v2.0+)
    local creds_set=false
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        if /usr/local/x-ui/x-ui setting -username "$admin_user" -password "$admin_pass" &>/dev/null; then
            print_ok "Set panel credentials: ${admin_user}"
            creds_set=true
        fi
    fi
    # Fallback to sqlite3 for older versions without the binary setting command
    if [[ "$creds_set" != "true" ]] && command -v sqlite3 &>/dev/null && [[ -f /etc/x-ui/x-ui.db ]]; then
        local sql_user="${admin_user//\'/\'\'}"
        local sql_pass="${admin_pass//\'/\'\'}"
        if echo "UPDATE users SET username='${sql_user}', password='${sql_pass}' WHERE id=1;" | sqlite3 /etc/x-ui/x-ui.db 2>/dev/null; then
            print_ok "Set panel credentials: ${admin_user} (via database)"
            creds_set=true
        fi
    fi
    if [[ "$creds_set" != "true" ]]; then
        print_warn "Could not set custom credentials. Using defaults: admin/admin"
        INSTALL_3XUI_ACTUAL_USER="admin"
        INSTALL_3XUI_ACTUAL_PASS="admin"
    fi

    # --- Set panel port ---
    local port_set=false
    # Try x-ui binary first
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        if /usr/local/x-ui/x-ui setting -port "$panel_port" &>/dev/null; then
            print_ok "Set panel port: ${panel_port}"
            port_set=true
        fi
    fi
    # Fallback to sqlite3
    if [[ "$port_set" != "true" ]] && command -v sqlite3 &>/dev/null && [[ -f /etc/x-ui/x-ui.db ]]; then
        local existing
        existing=$(sqlite3 /etc/x-ui/x-ui.db "SELECT COUNT(*) FROM settings WHERE key='webPort'" 2>/dev/null || echo "0")
        if [[ "$existing" -gt 0 ]]; then
            sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='${panel_port}' WHERE key='webPort'" 2>/dev/null && port_set=true
        else
            sqlite3 /etc/x-ui/x-ui.db "INSERT INTO settings (key, value) VALUES ('webPort', '${panel_port}')" 2>/dev/null && port_set=true
        fi
        [[ "$port_set" == "true" ]] && print_ok "Set panel port: ${panel_port}"
    fi
    if [[ "$port_set" != "true" ]]; then
        print_warn "Could not set panel port. Using default: 2053"
        INSTALL_3XUI_ACTUAL_PORT="2053"
    fi

    # Restart to apply credential and port changes
    systemctl restart x-ui 2>/dev/null || ignore_failure
    sleep 2

    if systemctl is-active --quiet x-ui 2>/dev/null; then
        print_ok "3x-ui restarted with new settings"
    else
        print_warn "3x-ui may need manual restart: systemctl restart x-ui"
    fi
}

# Install raw Xray (headless, no web panel).
# Creates a minimal Xray setup with just the binary and config.
# Usage: install_xray_headless

install_xray_headless() {
    print_info "Installing Xray (headless mode, no web panel)..."

    # Check if Xray binary already exists
    if command -v xray &>/dev/null || [[ -f /usr/local/bin/xray ]]; then
        print_ok "Xray binary already installed"
    else
        # Install via official script — capture output to check exit code properly
        local install_log
        install_log=$(mktemp)
        local install_script
        install_script=$(mktemp)
        if ! fetch_verified_script "$XRAY_INSTALL_SCRIPT_URL" "$XRAY_INSTALL_SCRIPT_SHA256" "$install_script" "Xray installer"; then
            rm -f "$install_script" "$install_log"
            print_fail "Could not download Xray install script."
            return 1
        fi
        if ! bash "$install_script" install --version "$XRAY_VERSION_PIN" > "$install_log" 2>&1; then
            tail -5 "$install_log"
            rm -f "$install_log" "$install_script"
            print_fail "Xray installation failed."
            return 1
        fi
        tail -3 "$install_log"
        rm -f "$install_log" "$install_script"

        # Verify the binary was actually installed
        if ! command -v xray &>/dev/null && [[ ! -f /usr/local/bin/xray ]]; then
            print_fail "Xray binary not found after installation."
            return 1
        fi
        print_ok "Xray binary installed"
    fi

    # Ensure the config directory exists
    mkdir -p /usr/local/etc/xray

    # Create a minimal config with just an empty inbounds array
    # (the actual inbound will be added by create_headless_xray_inbound)
    if [[ ! -f /usr/local/etc/xray/config.json ]]; then
        write_file_atomic /usr/local/etc/xray/config.json 0600 root root <<'XRAYEOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
XRAYEOF
        print_ok "Created minimal Xray config"
    fi

    # Enable and start the service
    systemctl enable xray 2>/dev/null || ignore_failure
    systemctl start xray 2>/dev/null || ignore_failure

    if systemctl is-active --quiet xray 2>/dev/null; then
        print_ok "Xray service running (headless)"
    else
        print_warn "Xray service may need manual start: systemctl start xray"
    fi
}

# Create an inbound directly in Xray config.json (headless mode, no panel).
# Usage: create_headless_xray_inbound
# Requires: XRAY_PROTOCOL, XRAY_INBOUND_PORT
# Sets: XRAY_UUID or XRAY_PASSWORD

create_headless_xray_inbound() {
    local config_file="/usr/local/etc/xray/config.json"

    if [[ ! -f "$config_file" ]]; then
        print_fail "Xray config not found at ${config_file}"
        return 1
    fi

    # Generate credentials
    XRAY_UUID=""
    XRAY_PASSWORD=""
    if [[ "$XRAY_PROTOCOL" == "vless" || "$XRAY_PROTOCOL" == "vmess" ]]; then
        XRAY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    else
        XRAY_PASSWORD=$(openssl rand -hex 16)
    fi

    # Build the new inbound JSON
    local new_inbound
    case "$XRAY_PROTOCOL" in
        vless)
            new_inbound=$(jq -nc --arg uuid "$XRAY_UUID" --argjson port "$XRAY_INBOUND_PORT" '{
                "listen": "127.0.0.1", "port": $port, "protocol": "vless",
                "settings": {"clients": [{"id": $uuid, "flow": ""}], "decryption": "none"},
                "streamSettings": {"network": "tcp", "security": "none"},
                "tag": "dnstt-vless"
            }')
            ;;
        shadowsocks)
            new_inbound=$(jq -nc --arg pass "$XRAY_PASSWORD" --argjson port "$XRAY_INBOUND_PORT" '{
                "listen": "127.0.0.1", "port": $port, "protocol": "shadowsocks",
                "settings": {"method": "chacha20-ietf-poly1305", "password": $pass, "network": "tcp,udp"},
                "tag": "dnstt-shadowsocks"
            }')
            ;;
        vmess)
            new_inbound=$(jq -nc --arg uuid "$XRAY_UUID" --argjson port "$XRAY_INBOUND_PORT" '{
                "listen": "127.0.0.1", "port": $port, "protocol": "vmess",
                "settings": {"clients": [{"id": $uuid, "alterId": 0}]},
                "streamSettings": {"network": "tcp", "security": "none"},
                "tag": "dnstt-vmess"
            }')
            ;;
        trojan)
            new_inbound=$(jq -nc --arg pass "$XRAY_PASSWORD" --argjson port "$XRAY_INBOUND_PORT" '{
                "listen": "127.0.0.1", "port": $port, "protocol": "trojan",
                "settings": {"clients": [{"password": $pass}]},
                "streamSettings": {"network": "tcp", "security": "none"},
                "tag": "dnstt-trojan"
            }')
            ;;
    esac

    # Backup original config
    cp "$config_file" "${config_file}.bak.$(date +%s)" 2>/dev/null || ignore_failure

    # Add inbound to the config using jq
    local tmp_config
    tmp_config=$(mktemp)
    if jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$config_file" > "$tmp_config" 2>/dev/null; then
        mv "$tmp_config" "$config_file"
        chmod 600 "$config_file"
        print_ok "Added inbound: ${XRAY_PROTOCOL} on 127.0.0.1:${XRAY_INBOUND_PORT}"
    else
        rm -f "$tmp_config"
        print_fail "Failed to update Xray config."
        return 1
    fi

    # Restart Xray to apply
    systemctl restart xray 2>/dev/null || ignore_failure
    sleep 1
    if systemctl is-active --quiet xray 2>/dev/null; then
        print_ok "Xray restarted with new inbound"
    else
        print_warn "Xray may need manual restart: systemctl restart xray"
    fi
}

# Detect if an Xray panel (3x-ui) is installed on this server.
# Sets XRAY_PANEL_TYPE to "3xui" or "none"
# Sets XRAY_PANEL_PORT if detected

detect_xray_panel() {
    XRAY_PANEL_TYPE="none"
    XRAY_PANEL_PORT=""
    XRAY_PANEL_RUNNING=false

    # Check for 3x-ui (native install)
    local found_3xui=false
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        found_3xui=true
        XRAY_PANEL_RUNNING=true
    elif systemctl list-unit-files 2>/dev/null | grep -q 'x-ui'; then
        found_3xui=true
    elif [[ -d /usr/local/x-ui ]]; then
        found_3xui=true
    elif command -v x-ui &>/dev/null; then
        found_3xui=true
    fi

    # Check for Docker-based 3x-ui
    if [[ "$found_3xui" == false ]] && command -v docker &>/dev/null; then
        if docker ps 2>/dev/null | grep -qi 'x-ui\|3x-ui'; then
            found_3xui=true
            XRAY_PANEL_RUNNING=true
        fi
    fi

    if [[ "$found_3xui" == true ]]; then
        XRAY_PANEL_TYPE="3xui"

        # Warn if service exists but is not running
        if [[ "$XRAY_PANEL_RUNNING" == false ]]; then
            print_warn "3x-ui is installed but NOT running."
            print_info "Start it with: systemctl start x-ui"
            echo ""
        fi

        # Try to detect panel port
        # Method 1: Parse x-ui config.json
        if [[ -f /usr/local/x-ui/config.json ]]; then
            XRAY_PANEL_PORT=$(jq -r '.port // .webPort // empty' /usr/local/x-ui/config.json 2>/dev/null || ignore_failure)
        fi

        # Method 2: Check x-ui.db for webPort setting
        if [[ -z "$XRAY_PANEL_PORT" ]] && command -v sqlite3 &>/dev/null; then
            if [[ -f /etc/x-ui/x-ui.db ]]; then
                XRAY_PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort'" 2>/dev/null || ignore_failure)
            fi
        fi
        # Method 2b: Query x-ui binary directly
        if [[ -z "$XRAY_PANEL_PORT" ]]; then
            XRAY_PANEL_PORT=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null | grep -Ei '^\s*port:' | awk -F': ' '{print $2}' | tr -d '[:space:]' || ignore_failure)
            [[ -z "$XRAY_PANEL_PORT" ]] && \
                XRAY_PANEL_PORT=$(x-ui settings 2>/dev/null | grep -Ei '^\s*port:' | awk -F': ' '{print $2}' | tr -d '[:space:]' || ignore_failure)
        fi
        # Validate port is numeric
        if [[ -n "$XRAY_PANEL_PORT" && ! "$XRAY_PANEL_PORT" =~ ^[0-9]+$ ]]; then
            XRAY_PANEL_PORT=""
        fi

        # Method 3: Try common 3x-ui ports (skip 443 — too likely to be nginx)
        if [[ -z "$XRAY_PANEL_PORT" ]]; then
            for port in 2053 54321 2087 2083; do
                if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                    XRAY_PANEL_PORT="$port"
                    break
                fi
            done
        fi

        # Method 4: Fall back to default
        XRAY_PANEL_PORT="${XRAY_PANEL_PORT:-2053}"

        # Detect web base path (3x-ui v2.0+ sets a random base path by default)
        XRAY_PANEL_BASEPATH=""
        # Method 1: Parse config.json
        if [[ -f /usr/local/x-ui/config.json ]]; then
            XRAY_PANEL_BASEPATH=$(jq -r '.webBasePath // empty' /usr/local/x-ui/config.json 2>/dev/null || ignore_failure)
        fi
        # Method 2: Query sqlite database
        if [[ -z "$XRAY_PANEL_BASEPATH" ]] && command -v sqlite3 &>/dev/null && [[ -f /etc/x-ui/x-ui.db ]]; then
            XRAY_PANEL_BASEPATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath'" 2>/dev/null || ignore_failure)
        fi
        # Method 3: Try to read from x-ui process environment or binary output
        if [[ -z "$XRAY_PANEL_BASEPATH" ]]; then
            # Some 3x-ui versions expose base path in config output
            local xui_config_output
            xui_config_output=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null || x-ui setting -show 2>/dev/null || ignore_failure)
            if [[ -n "$xui_config_output" ]]; then
                XRAY_PANEL_BASEPATH=$(echo "$xui_config_output" | grep -i 'webBasePath\|basePath' | sed 's/.*:[[:space:]]*//' | head -1 || ignore_failure)
            fi
        fi
        # Method 4: Parse from running process cmdline or env
        if [[ -z "$XRAY_PANEL_BASEPATH" ]]; then
            local _xui_pid
            _xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || ignore_failure)
            if [[ -n "$_xui_pid" && -f "/proc/${_xui_pid}/environ" ]]; then
                XRAY_PANEL_BASEPATH=$(tr '\0' '\n' < "/proc/${_xui_pid}/environ" 2>/dev/null | grep -i 'basepath\|base_path' | sed 's/.*=//' | head -1 || ignore_failure)
            fi
        fi
        # Normalize: strip whitespace and leading/trailing slashes
        XRAY_PANEL_BASEPATH=$(echo "${XRAY_PANEL_BASEPATH:-}" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||;s|^/||;s|/$||')
    fi
}

# Get 3x-ui admin credentials. Tries to read from DB first, then asks user.
# Sets XRAY_ADMIN_USER and XRAY_ADMIN_PASS

get_3xui_credentials() {
    XRAY_ADMIN_USER=""
    XRAY_ADMIN_PASS=""

    # Try to read from database
    if [[ -z "$XRAY_ADMIN_USER" || -z "$XRAY_ADMIN_PASS" ]]; then
        if command -v sqlite3 &>/dev/null && [[ -f /etc/x-ui/x-ui.db ]]; then
            XRAY_ADMIN_USER=$(sqlite3 /etc/x-ui/x-ui.db "SELECT username FROM users LIMIT 1" 2>/dev/null || ignore_failure)
            XRAY_ADMIN_PASS=$(sqlite3 /etc/x-ui/x-ui.db "SELECT password FROM users LIMIT 1" 2>/dev/null || ignore_failure)
        fi
    fi

    # Detect bcrypt-hashed passwords (3x-ui v2.0+ hashes by default)
    # Hashed passwords start with $2a$, $2b$, or $2y$ and cannot be used as plaintext
    if [[ -n "$XRAY_ADMIN_PASS" && "$XRAY_ADMIN_PASS" == \$2[aby]\$* ]]; then
        print_warn "Password in database is hashed (3x-ui v2.0+). Manual entry required."
        XRAY_ADMIN_PASS=""
    fi

    if [[ -n "$XRAY_ADMIN_USER" && -n "$XRAY_ADMIN_PASS" ]]; then
        print_ok "Read credentials from 3x-ui database"
        return 0
    fi

    # Ask user — keep DB username if we have it, only ask for what's missing
    echo ""
    echo -e "  ${BOLD}3x-ui Panel Credentials${NC}"
    echo -e "  ${DIM}(needed to create the Xray inbound via API)${NC}"
    echo ""
    if [[ -z "$XRAY_ADMIN_USER" ]]; then
        XRAY_ADMIN_USER=$(prompt_input "Panel username" "admin")
    else
        echo -e "  ${DIM}Username from database: ${XRAY_ADMIN_USER}${NC}"
    fi
    echo ""
    read -rsp "  Panel password [admin]: " XRAY_ADMIN_PASS
    XRAY_ADMIN_PASS="${XRAY_ADMIN_PASS:-admin}"
    echo ""

    if [[ -z "$XRAY_ADMIN_USER" ]]; then
        print_fail "Username cannot be empty."
        return 1
    fi
}

# Let user choose which Xray protocol to use for the inbound.
# Sets XRAY_PROTOCOL

pick_xray_protocol() {
    echo ""
    echo -e "  ${BOLD}Xray Protocol:${NC}"
    echo -e "  ${BOLD}1)${NC}  VLESS        ${DIM}(lightweight, recommended)${NC}"
    echo -e "  ${BOLD}2)${NC}  Shadowsocks  ${DIM}(widely supported, simple)${NC}"
    echo -e "  ${BOLD}3)${NC}  VMess        ${DIM}(V2Ray protocol)${NC}"
    echo -e "  ${BOLD}4)${NC}  Trojan       ${DIM}(HTTPS-like)${NC}"
    echo ""
    local choice
    choice=$(prompt_input "Select protocol (1-4)" "1")
    case "$choice" in
        1) XRAY_PROTOCOL="vless" ;;
        2) XRAY_PROTOCOL="shadowsocks" ;;
        3) XRAY_PROTOCOL="vmess" ;;
        4) XRAY_PROTOCOL="trojan" ;;
        *)
            print_fail "Invalid selection. Use 1-4."
            return 1
            ;;
    esac
    print_ok "Protocol: ${XRAY_PROTOCOL}"
}

# Auto-find a free port for the Xray inbound, let user override.
# Sets XRAY_INBOUND_PORT

pick_xray_port() {
    local port
    # Find a free port
    local attempts=0
    while true; do
        port=$((RANDOM % 50000 + 10000))
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            break
        fi
        attempts=$((attempts + 1))
        if [[ $attempts -ge 50 ]]; then
            port=18443
            break
        fi
    done

    echo ""
    XRAY_INBOUND_PORT=$(prompt_input "Xray inbound port (internal only, not exposed)" "$port")

    # Validate
    if ! [[ "$XRAY_INBOUND_PORT" =~ ^[0-9]+$ ]] || [[ "$XRAY_INBOUND_PORT" -lt 1 ]] || [[ "$XRAY_INBOUND_PORT" -gt 65535 ]]; then
        print_fail "Invalid port number. Must be between 1 and 65535."
        return 1
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${XRAY_INBOUND_PORT} "; then
        print_warn "Port ${XRAY_INBOUND_PORT} is already in use. Continuing anyway (may be intended)."
    fi

    print_ok "Inbound port: ${XRAY_INBOUND_PORT} (127.0.0.1 only)"
}

# Create a new inbound on the 3x-ui panel via its API.
# Requires: XRAY_ADMIN_USER, XRAY_ADMIN_PASS, XRAY_PANEL_PORT, XRAY_PROTOCOL, XRAY_INBOUND_PORT
# Sets: XRAY_UUID (for vless/vmess) or XRAY_PASSWORD (for ss/trojan)

create_3xui_inbound() {
    local base_segment=""
    [[ -n "${XRAY_PANEL_BASEPATH:-}" ]] && base_segment="/${XRAY_PANEL_BASEPATH}"
    local cookie_jar
    cookie_jar=$(mktemp)
    chmod 600 "$cookie_jar" 2>/dev/null || ignore_failure

    # Ensure cookie jar is cleaned up on any exit path
    trap 'rm -f "${cookie_jar:-}"; trap - RETURN' RETURN

    # Generate credentials for the inbound
    XRAY_UUID=""
    XRAY_PASSWORD=""
    if [[ "$XRAY_PROTOCOL" == "vless" || "$XRAY_PROTOCOL" == "vmess" ]]; then
        XRAY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    else
        XRAY_PASSWORD=$(openssl rand -hex 16)
    fi

    # Auto-detect panel URL: try http, then https, with and without base path
    # Also try localhost in case 127.0.0.1 doesn't resolve (IPv6-only systems)
    print_info "Logging in to 3x-ui panel..."
    if [[ -n "$base_segment" ]]; then
        print_info "Detected web base path: ${base_segment}"
    fi
    local panel_url=""
    local login_resp=""
    local try_urls=()

    # Build list of URLs to try — with base path, without, and also try
    # /panel prefix (some 3x-ui versions use /{basepath}/panel/... routes)
    local _addrs=("127.0.0.1" "localhost")
    for _addr in "${_addrs[@]}"; do
        if [[ -n "$base_segment" ]]; then
            try_urls+=("http://${_addr}:${XRAY_PANEL_PORT}${base_segment}")
            try_urls+=("https://${_addr}:${XRAY_PANEL_PORT}${base_segment}")
        fi
        try_urls+=("http://${_addr}:${XRAY_PANEL_PORT}")
        try_urls+=("https://${_addr}:${XRAY_PANEL_PORT}")
    done

    # Wait for panel to become ready (it may have just been installed/restarted)
    local _wait_attempts=0
    while [[ $_wait_attempts -lt 5 ]]; do
        if ss -tlnp 2>/dev/null | grep -q ":${XRAY_PANEL_PORT} "; then
            break
        fi
        _wait_attempts=$((_wait_attempts + 1))
        if [[ $_wait_attempts -eq 1 ]]; then
            print_info "Waiting for panel to start on port ${XRAY_PANEL_PORT}..."
        fi
        [[ $_wait_attempts -lt 5 ]] && sleep 2
    done

    # Also detect actual listening port from x-ui process if our port doesn't match
    if ! ss -tlnp 2>/dev/null | grep -q ":${XRAY_PANEL_PORT} "; then
        local _actual_port
        _actual_port=$(ss -tlnp 2>/dev/null | grep 'x-ui\|x\.ui' | grep -oE ':[0-9]+' | head -1 | tr -d ':' || ignore_failure)
        if [[ -n "$_actual_port" && "$_actual_port" != "$XRAY_PANEL_PORT" ]]; then
            print_warn "Panel not on port ${XRAY_PANEL_PORT}, found on port ${_actual_port} — trying that"
            XRAY_PANEL_PORT="$_actual_port"
            # Rebuild URLs with correct port
            try_urls=()
            for _addr in "${_addrs[@]}"; do
                if [[ -n "$base_segment" ]]; then
                    try_urls+=("http://${_addr}:${XRAY_PANEL_PORT}${base_segment}")
                    try_urls+=("https://${_addr}:${XRAY_PANEL_PORT}${base_segment}")
                fi
                try_urls+=("http://${_addr}:${XRAY_PANEL_PORT}")
                try_urls+=("https://${_addr}:${XRAY_PANEL_PORT}")
            done
        fi
    fi

    for try_url in "${try_urls[@]}"; do
        login_resp=$(curl -s -L -k -c "$cookie_jar" -X POST "${try_url}/login" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "username=${XRAY_ADMIN_USER}" \
            --data-urlencode "password=${XRAY_ADMIN_PASS}" \
            --connect-timeout 5 --max-time 10 2>/dev/null || ignore_failure)
        # Only accept JSON responses (not HTML error pages or empty)
        if [[ -n "$login_resp" ]] && echo "$login_resp" | jq . &>/dev/null; then
            panel_url="$try_url"
            break
        fi
        # Clear cookie jar between attempts
        : > "$cookie_jar"
    done

    if [[ -z "$panel_url" ]]; then
        print_fail "Could not connect to 3x-ui panel on port ${XRAY_PANEL_PORT}"
        # Show what's actually listening for debugging
        local _listening
        _listening=$(ss -tlnp 2>/dev/null | grep -i 'x-ui\|x\.ui' || ignore_failure)
        if [[ -n "$_listening" ]]; then
            print_info "Panel process found but login failed:"
            print_info "  ${_listening}"
            # Diagnostic: probe the panel to find what's actually responding
            local _diag_url _diag_resp _diag_err
            for _diag_url in "https://127.0.0.1:${XRAY_PANEL_PORT}" "http://127.0.0.1:${XRAY_PANEL_PORT}"; do
                _diag_err=$(curl -s -k --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" "${_diag_url}/" 2>&1 || ignore_failure)
                if [[ "$_diag_err" =~ ^[0-9]+$ && "$_diag_err" != "000" ]]; then
                    print_info "Panel responds on ${_diag_url} (HTTP ${_diag_err})"
                    # Try to get the actual login page to see if base path redirect happens
                    _diag_resp=$(curl -s -k -L --connect-timeout 3 --max-time 5 "${_diag_url}/" 2>/dev/null | head -c 500 || ignore_failure)
                    # Check if response contains a redirect to a base path
                    local _detected_base
                    _detected_base=$(echo "$_diag_resp" | grep -oE 'href="(/[^"]+)/"' | head -1 | sed 's/href="//;s/\/"$//' || ignore_failure)
                    if [[ -n "$_detected_base" && "$_detected_base" != "/" ]]; then
                        print_info "Detected redirect to base path: ${_detected_base}"
                        print_info "Retrying login with base path..."
                        login_resp=$(curl -s -L -k -c "$cookie_jar" -X POST "${_diag_url}${_detected_base}/login" \
                            -H "Content-Type: application/x-www-form-urlencoded" \
                            --data-urlencode "username=${XRAY_ADMIN_USER}" \
                            --data-urlencode "password=${XRAY_ADMIN_PASS}" \
                            --connect-timeout 5 --max-time 10 2>/dev/null || ignore_failure)
                        if [[ -n "$login_resp" ]] && echo "$login_resp" | jq . &>/dev/null; then
                            panel_url="${_diag_url}${_detected_base}"
                            print_ok "Found panel at ${panel_url}"
                            break
                        fi
                    fi
                    break
                fi
            done
        else
            print_info "No x-ui process found listening on any port"
            print_info "Try: systemctl restart x-ui && sleep 3 && sudo bash $0 --add-xray"
        fi
        # If diagnostic probe found the panel, continue; otherwise fail
        if [[ -z "$panel_url" ]]; then
            if [[ -n "$base_segment" ]]; then
                print_info "Web base path '${base_segment}' was detected — verify it matches your panel"
            fi
            print_info "Check: systemctl status x-ui"
            print_info "Debug: curl -k https://127.0.0.1:${XRAY_PANEL_PORT}/"
            return 1
        fi
    fi

    local login_success
    login_success=$(echo "$login_resp" | jq -r '.success // false' 2>/dev/null || echo "false")
    if [[ "$login_success" != "true" ]]; then
        print_fail "Login failed. Check username/password."
        print_info "Response: $(echo "$login_resp" | jq -r '.msg // "unknown error"' 2>/dev/null || echo "$login_resp")"
        return 1
    fi
    print_ok "Logged in to 3x-ui"

    # Build inbound settings JSON based on protocol
    local settings stream_settings sniffing_settings remark
    remark="DNSTT-${XRAY_PROTOCOL}-${XRAY_INBOUND_PORT}"

    sniffing_settings='{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}'
    stream_settings='{"network":"tcp","security":"none","tcpSettings":{"header":{"type":"none"}}}'

    local client_email="dnstt-${XRAY_INBOUND_PORT}"

    case "$XRAY_PROTOCOL" in
        vless)
            settings=$(jq -nc --arg uuid "$XRAY_UUID" --arg email "$client_email" '{
                "clients": [{"id": $uuid, "flow": "", "email": $email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true}],
                "decryption": "none",
                "fallbacks": []
            }')
            ;;
        shadowsocks)
            settings=$(jq -nc --arg pass "$XRAY_PASSWORD" '{
                "method": "chacha20-ietf-poly1305",
                "password": $pass,
                "network": "tcp,udp",
                "clients": []
            }')
            ;;
        vmess)
            settings=$(jq -nc --arg uuid "$XRAY_UUID" --arg email "$client_email" '{
                "clients": [{"id": $uuid, "alterId": 0, "email": $email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true}]
            }')
            ;;
        trojan)
            settings=$(jq -nc --arg pass "$XRAY_PASSWORD" --arg email "$client_email" '{
                "clients": [{"password": $pass, "email": $email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true}],
                "fallbacks": []
            }')
            ;;
    esac

    # Create inbound via API
    print_info "Creating inbound: ${XRAY_PROTOCOL} on 127.0.0.1:${XRAY_INBOUND_PORT}..."
    local inbound_data
    inbound_data=$(jq -nc \
        --arg remark "$remark" \
        --argjson port "$XRAY_INBOUND_PORT" \
        --arg protocol "$XRAY_PROTOCOL" \
        --arg settings "$settings" \
        --arg stream "$stream_settings" \
        --arg sniffing "$sniffing_settings" \
        '{
            "up": 0, "down": 0,
            "total": 0,
            "remark": $remark,
            "enable": true,
            "expiryTime": 0,
            "listen": "127.0.0.1",
            "port": $port,
            "protocol": $protocol,
            "settings": $settings,
            "streamSettings": $stream,
            "sniffing": $sniffing
        }')

    local create_resp
    create_resp=$(curl -s -L -k -b "$cookie_jar" -X POST "${panel_url}/panel/api/inbounds/add" \
        -H "Content-Type: application/json" \
        -d "$inbound_data" \
        --max-time 10 2>/dev/null || ignore_failure)

    if [[ -z "$create_resp" ]]; then
        print_fail "No response from panel when creating inbound."
        return 1
    fi

    local create_success
    create_success=$(echo "$create_resp" | jq -r '.success // false' 2>/dev/null || echo "false")
    if [[ "$create_success" != "true" ]]; then
        print_fail "Failed to create inbound."
        print_info "Response: $(echo "$create_resp" | jq -r '.msg // "unknown error"' 2>/dev/null || echo "$create_resp")"
        return 1
    fi

    print_ok "Created inbound: ${remark} (127.0.0.1:${XRAY_INBOUND_PORT})"
}

# Create a systemd drop-in override to redirect the DNSTT tunnel upstream
# from microsocks to the Xray inbound port.
# Usage: create_xray_service_override <tag> <xray_port> <domain>

create_xray_service_override() {
    local tag="$1"
    local xray_port="$2"
    local domain="$3"
    local service="dnstm-${tag}.service"
    local dropin_dir="/etc/systemd/system/${service}.d"
    local dropin_file="${dropin_dir}/10-xray-upstream.conf"

    # Parse original ExecStart to get the tunnel's listening port and key path
    # Use 'systemctl show' for the resolved ExecStart (avoids drop-in merging issues)
    local orig_exec
    orig_exec=$(systemctl cat "$service" 2>/dev/null | grep '^ExecStart=/' | head -1 || ignore_failure)
    # Fallback: if drop-in already exists, grep for the binary path line
    if [[ -z "$orig_exec" ]]; then
        orig_exec=$(systemctl cat "$service" 2>/dev/null | grep '^ExecStart=.*dnstt-server' | tail -1 || ignore_failure)
    fi

    if [[ -z "$orig_exec" ]]; then
        print_fail "Could not read ExecStart from ${service}"
        return 1
    fi

    # Extract the listening port (-udp :PORT part) — no Perl regex needed
    local tunnel_port
    tunnel_port=$(echo "$orig_exec" | grep -oE '\-udp[[:space:]]+[^ ]+' | grep -oE '[0-9]+$' || ignore_failure)
    if [[ -z "$tunnel_port" ]]; then
        print_fail "Could not detect tunnel listening port from service"
        return 1
    fi

    # Extract the privkey path
    local privkey_path
    privkey_path=$(echo "$orig_exec" | sed -n 's/.*-privkey-file[[:space:]]\+\([^[:space:]]\+\).*/\1/p' || ignore_failure)
    if [[ -z "$privkey_path" ]]; then
        privkey_path="/etc/dnstm/tunnels/${tag}/server.key"
    fi

    # Extract MTU flag if present (e.g., -mtu 1100)
    local mtu_arg=""
    local orig_mtu
    orig_mtu=$(echo "$orig_exec" | grep -oE '\-mtu[[:space:]]+[0-9]+' || ignore_failure)
    if [[ -n "$orig_mtu" ]]; then
        mtu_arg=" ${orig_mtu}"
    fi

    # Extract the dnstt-server binary path (first token after ExecStart=)
    local dnstt_bin
    dnstt_bin=$(echo "$orig_exec" | sed 's/^ExecStart=[-+!@]*//;s/[[:space:]].*//' || ignore_failure)
    if [[ -z "$dnstt_bin" || ! -f "$dnstt_bin" ]]; then
        # Fallback to common locations
        for bin_path in /usr/local/bin/dnstt-server /usr/bin/dnstt-server; do
            if [[ -f "$bin_path" ]]; then
                dnstt_bin="$bin_path"
                break
            fi
        done
    fi

    if [[ -z "$dnstt_bin" ]]; then
        print_fail "Could not find dnstt-server binary"
        return 1
    fi

    if ! mkdir -p "$dropin_dir" 2>/dev/null; then
        print_fail "Could not create drop-in directory: ${dropin_dir}"
        return 1
    fi
    write_file_atomic "$dropin_file" 0644 root root <<EOF || { print_fail "Could not write service override: ${dropin_file}"; return 1; }
[Service]
ExecStart=
ExecStart=${dnstt_bin} -udp :${tunnel_port}${mtu_arg} -privkey-file ${privkey_path} ${domain} 127.0.0.1:${xray_port}
EOF

    print_ok "Created service override: ${service} → 127.0.0.1:${xray_port}"
}

# Generate a client share URI for the Xray tunnel.
# Usage: generate_xray_client_uri <protocol> <server_ip> <port> <uuid_or_pass> [remark]
# Returns the URI string

generate_xray_client_uri() {
    local protocol="$1"
    local server_ip="$2"
    local port="$3"
    local credential="$4"
    local remark="${5:-DNSTT-Xray}"

    # URL-encode the remark (pure bash, no python dependency)
    local encoded_remark=""
    local i c
    for (( i=0; i<${#remark}; i++ )); do
        c="${remark:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) encoded_remark+="$c" ;;
            *) encoded_remark+=$(printf '%%%02X' "'$c") ;;
        esac
    done

    # Handle IPv6 addresses — wrap in brackets for URIs
    local host="$server_ip"
    if [[ "$server_ip" == *:* ]]; then
        host="[${server_ip}]"
    fi

    case "$protocol" in
        vless)
            echo "vless://${credential}@${host}:${port}?encryption=none&type=tcp&security=none#${encoded_remark}"
            ;;
        shadowsocks)
            local method="chacha20-ietf-poly1305"
            # SIP002 requires URL-safe base64 (RFC 4648 section 5): +/ → -_, no padding
            local encoded
            encoded=$(echo -n "${method}:${credential}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
            echo "ss://${encoded}@${host}:${port}#${encoded_remark}"
            ;;
        vmess)
            local vmess_json
            vmess_json=$(jq -nc \
                --arg ip "$server_ip" \
                --arg port "$port" \
                --arg uuid "$credential" \
                --arg remark "$remark" \
                '{
                    "v": "2",
                    "ps": $remark,
                    "add": $ip,
                    "port": $port,
                    "id": $uuid,
                    "aid": "0",
                    "net": "tcp",
                    "type": "none",
                    "host": "",
                    "path": "",
                    "tls": "",
                    "scy": "auto"
                }')
            echo "vmess://$(echo -n "$vmess_json" | base64 -w0)"
            ;;
        trojan)
            echo "trojan://${credential}@${host}:${port}?type=tcp&security=none#${encoded_remark}"
            ;;
    esac
}

# Save Xray tunnel config to /etc/dnstm/xray/
# Usage: save_xray_config <tag>

save_xray_config() {
    local tag="$1"
    local config_dir="/etc/dnstm/xray"
    local config_file="${config_dir}/${tag}.conf"

    if ! mkdir -p "$config_dir" 2>/dev/null; then
        print_warn "Could not create config directory: ${config_dir}"
        return 1
    fi
    chmod 700 "$config_dir" 2>/dev/null || ignore_failure
    # Create file with restrictive permissions before writing any secrets
    # Use subshell umask to ensure touch fallback is also restrictive
    install -m 600 /dev/null "$config_file" 2>/dev/null || (umask 077; touch "$config_file")
    chmod 600 "$config_file" 2>/dev/null || ignore_failure
    # Use printf %q to safely quote all values (handles special chars)
    {
        printf 'XRAY_TAG=%q\n' "$tag"
        printf 'XRAY_PORT=%q\n' "$XRAY_INBOUND_PORT"
        printf 'XRAY_PROTOCOL=%q\n' "$XRAY_PROTOCOL"
        printf 'XRAY_UUID=%q\n' "$XRAY_UUID"
        printf 'XRAY_PASSWORD=%q\n' "$XRAY_PASSWORD"
        printf 'XRAY_PANEL=%q\n' "$XRAY_PANEL_TYPE"
        printf 'XRAY_DOMAIN=%q\n' "x.${DOMAIN}"
    } > "$config_file" || { print_warn "Could not write config: ${config_file}"; return 1; }
    print_ok "Saved config: ${config_file}"
}

# ─── NoizDNS Binary Download ──────────────────────────────────────────────────

# Download and verify the NoizDNS server binary if not already installed.
# Returns 0 if binary is available (already existed or freshly downloaded), 1 otherwise.

do_add_xray() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_notice "skip Xray tunnel integration"
        return 0
    fi

    banner

    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${CROSS} Not running as root. Please run with: sudo bash $0 --add-xray"
        exit 1
    fi

    if ! command -v dnstm &>/dev/null; then
        print_fail "dnstm is not installed. Run the full setup first: sudo bash $0"
        exit 1
    fi

    print_header "Xray Backend via DNS Tunnel"

    echo ""
    echo -e "  ${BOLD}How this works:${NC}"
    echo -e "  ${DIM}This connects your existing Xray panel (3x-ui) to a DNSTT tunnel.${NC}"
    echo -e "  ${DIM}A new internal-only Xray inbound is created on 127.0.0.1, then a${NC}"
    echo -e "  ${DIM}DNSTT tunnel is set up to forward DNS traffic to that inbound.${NC}"
    echo ""
    echo -e "  ${DIM}Flow: Phone (SlipNet+Nekobox) → DNS tunnel → Xray inbound → Internet${NC}"
    echo ""

    # Ensure required tools are available
    if ! command -v curl &>/dev/null; then
        print_fail "curl is required but not installed. Install it: apt-get install curl"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_info "Installing jq..."
        if apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq >/dev/null 2>&1; then
            print_ok "Installed jq"
        else
            print_fail "Failed to install jq. Install it manually: apt-get install jq"
            exit 1
        fi
    fi

    # Detect server IP
    SERVER_IP=$(fetch_public_ipv4 2>/dev/null || ignore_failure)
    if [[ -n "$SERVER_IP" ]]; then
        print_ok "Server IP: ${SERVER_IP}"
    else
        print_warn "Could not detect server IP"
        SERVER_IP=$(prompt_input "Enter server IP manually" "")
        if [[ -z "$SERVER_IP" ]]; then
            print_fail "Server IP is required."
            exit 1
        fi
    fi

    # Show current tunnels
    echo ""
    print_info "Current tunnels:"
    echo ""
    dnstm tunnel list 2>/dev/null || print_info "(none)"
    echo ""

    # 1. Detect Xray panel
    print_info "Detecting Xray panel..."
    detect_xray_panel

    if [[ "$XRAY_PANEL_TYPE" == "none" ]]; then
        echo ""
        print_warn "No Xray installation detected on this server."
        echo ""
        echo -e "  ${BOLD}How would you like to set up Xray?${NC}"
        echo -e "  ${BOLD}1)${NC}  Full panel (3x-ui)   ${DIM}— web dashboard, user management, traffic stats${NC}"
        echo -e "  ${BOLD}2)${NC}  Headless (Xray only) ${DIM}— no web panel, lightweight, config-based${NC}"
        echo -e "  ${BOLD}0)${NC}  Cancel"
        echo ""
        local install_choice
        install_choice=$(prompt_input "Select (0-2)" "1")

        case "$install_choice" in
            1)
                # Full panel install
                echo ""
                echo -e "  ${BOLD}3x-ui Panel Setup${NC}"
                echo -e "  ${DIM}Choose admin credentials and panel port.${NC}"
                echo ""
                local new_user new_pass new_port
                new_user=$(prompt_input "Panel admin username" "admin")
                echo ""
                new_pass=$(prompt_input "Panel admin password" "password")
                echo ""
                new_port=$(prompt_input "Panel web port" "2053")
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]]; then
                    new_port=2053
                fi
                echo ""

                install_3xui "$new_user" "$new_pass" "$new_port" || return 1

                # Use ACTUAL values (may differ from requested if sqlite3 failed)
                XRAY_PANEL_TYPE="3xui"
                XRAY_PANEL_PORT="${INSTALL_3XUI_ACTUAL_PORT}"
                XRAY_PANEL_RUNNING=true
                XRAY_ADMIN_USER="${INSTALL_3XUI_ACTUAL_USER}"
                XRAY_ADMIN_PASS="${INSTALL_3XUI_ACTUAL_PASS}"

                echo ""
                echo -e "  ${BOLD}Panel Access${NC}"
                echo -e "  ${DIM}────────────────────────────────────────${NC}"
                echo -e "  URL:       ${GREEN}http://${SERVER_IP}:${XRAY_PANEL_PORT}${NC}"
                echo -e "  Username:  ${GREEN}${XRAY_ADMIN_USER}${NC}"
                echo -e "  Password:  ${GREEN}${XRAY_ADMIN_PASS}${NC}"
                echo ""
                ;;
            2)
                # Headless install
                echo ""
                install_xray_headless || return 1
                XRAY_PANEL_TYPE="headless"
                XRAY_PANEL_RUNNING=true
                echo ""
                ;;
            0|*)
                echo ""
                print_info "Cancelled."
                return 0
                ;;
        esac
    else
        local _detect_msg="Detected: 3x-ui (port ${XRAY_PANEL_PORT})"
        [[ -n "${XRAY_PANEL_BASEPATH:-}" ]] && _detect_msg+=", base path: /${XRAY_PANEL_BASEPATH}"
        print_ok "$_detect_msg"
    fi

    # 2. Get panel credentials (skip for headless — no panel API needed)
    if [[ "$XRAY_PANEL_TYPE" == "3xui" && -z "${XRAY_ADMIN_USER:-}" ]]; then
        get_3xui_credentials || return 1
    fi

    # 3. Choose protocol
    pick_xray_protocol || return 1

    # 4. Pick port for internal inbound
    pick_xray_port || return 1

    # 5. Get domain
    echo ""
    echo -e "  ${BOLD}Domain Configuration${NC}"
    echo -e "  ${DIM}The Xray tunnel will use subdomain: x.<your-domain>${NC}"
    echo ""

    # Try to detect domain from existing tunnels
    local detected_domain=""
    detected_domain=$(dnstm tunnel list 2>/dev/null | grep -o 'domain=[^ ]*' | head -1 | sed 's/domain=//' | sed 's/^[^.]*\.//' || ignore_failure)

    if [[ -n "$detected_domain" ]]; then
        DOMAIN=$(prompt_input "Domain" "$detected_domain")
    else
        DOMAIN=$(prompt_input "Enter your domain (e.g. example.com)" "")
    fi

    if [[ -z "$DOMAIN" ]]; then
        print_fail "Domain is required."
        return 1
    fi
    print_ok "Tunnel domain: x.${DOMAIN}"

    # Check if x.DOMAIN tunnel already exists (prevent duplicates)
    if dnstm tunnel list 2>/dev/null | grep -q "domain=x\.${DOMAIN}"; then
        print_fail "A tunnel for x.${DOMAIN} already exists."
        print_info "Remove it first with: sudo bash $0 --remove-tunnel"
        return 1
    fi

    # 6. Create Xray inbound
    echo ""
    if [[ "$XRAY_PANEL_TYPE" == "headless" ]]; then
        create_headless_xray_inbound || return 1
    else
        create_3xui_inbound || return 1
    fi

    # 7. Create DNSTT tunnel via dnstm
    echo ""

    # Determine tag — check existing xray tags and increment (exact match)
    local xray_num=1
    while dnstm_tag_exists "xray${xray_num}"; do
        xray_num=$((xray_num + 1))
    done
    local tag="xray${xray_num}"

    print_info "Creating DNSTT tunnel: ${tag} (x.${DOMAIN})..."
    local mtu_flag=""
    if [[ -n "${DNSTT_MTU:-}" ]]; then
        mtu_flag="--mtu ${DNSTT_MTU}"
    fi
    # shellcheck disable=SC2086
    local create_output
    create_output=$(dnstm tunnel add --transport dnstt --backend socks --domain "x.${DOMAIN}" --tag "$tag" $mtu_flag 2>&1) || ignore_failure
    echo "$create_output"

    if ! dnstm_tag_exists "${tag}"; then
        print_fail "Tunnel creation failed."
        if [[ "$XRAY_PANEL_TYPE" == "headless" ]]; then
            print_info "Note: Xray inbound on port ${XRAY_INBOUND_PORT} was added to config.json but the tunnel failed."
            print_info "Remove it manually: edit /usr/local/etc/xray/config.json"
        else
            print_info "Note: Xray inbound on port ${XRAY_INBOUND_PORT} was created in 3x-ui but the tunnel failed."
            print_info "Remove it manually from the panel dashboard if needed."
        fi
        return 1
    fi
    print_ok "Created tunnel: ${tag}"

    # 8. Override upstream to point at Xray instead of microsocks
    echo ""
    print_info "Redirecting tunnel upstream to Xray..."
    if ! create_xray_service_override "$tag" "$XRAY_INBOUND_PORT" "x.${DOMAIN}"; then
        # Rollback: remove the tunnel we just created
        print_warn "Service override failed. Rolling back tunnel..."
        dnstm tunnel stop --tag "$tag" 2>/dev/null || ignore_failure
        dnstm tunnel remove --tag "$tag" 2>/dev/null || ignore_failure
        if [[ "$XRAY_PANEL_TYPE" == "headless" ]]; then
            print_info "Note: Xray inbound on port ${XRAY_INBOUND_PORT} was added to config.json but not cleaned up."
            print_info "Remove it manually: edit /usr/local/etc/xray/config.json"
        else
            print_info "Note: Xray inbound on port ${XRAY_INBOUND_PORT} was NOT removed from 3x-ui panel."
            print_info "Remove it manually from the panel dashboard if needed."
        fi
        return 1
    fi

    # 9. Reload and start
    if ! systemctl daemon-reload 2>/dev/null; then
        print_warn "systemctl daemon-reload failed — continuing anyway"
    fi
    print_info "Starting tunnel: ${tag}..."
    # Use restart (not start) to ensure the service override takes effect
    # If the tunnel was auto-started by dnstm, 'start' would be a no-op
    if systemctl restart "dnstm-${tag}.service" 2>/dev/null; then
        print_ok "Started: ${tag}"
    elif dnstm tunnel start --tag "$tag" 2>/dev/null; then
        print_ok "Started: ${tag}"
    else
        print_warn "Could not start tunnel. Check: dnstm tunnel logs --tag ${tag}"
    fi

    print_info "Restarting DNS Router..."
    dnstm router stop 2>/dev/null || ignore_failure
    sleep 1
    if dnstm router start 2>/dev/null; then
        print_ok "DNS Router restarted"
    else
        print_warn "DNS Router restart may have issues. Check: dnstm router logs"
    fi

    # 10. Save config
    save_xray_config "$tag" || print_warn "Could not save Xray config (tunnel is running but config not persisted)"

    # 11. Show DNSTT public key
    local pubkey=""
    if [[ -f "/etc/dnstm/tunnels/${tag}/server.pub" ]]; then
        pubkey=$(cat "/etc/dnstm/tunnels/${tag}/server.pub" 2>/dev/null || ignore_failure)
    fi

    # 12. Summary
    echo ""
    echo ""
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}  XRAY BACKEND TUNNEL CREATED  ${NC}"
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Server IP :  ${GREEN}${SERVER_IP}${NC}"
    echo -e "  Domain    :  ${GREEN}x.${DOMAIN}${NC}"
    echo -e "  Tag       :  ${GREEN}${tag}${NC}"
    echo ""
    echo -e "  ${BOLD}Xray Inbound${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Protocol  :  ${GREEN}${XRAY_PROTOCOL}${NC}"
    echo -e "  Port      :  ${GREEN}${XRAY_INBOUND_PORT}${NC} ${DIM}(127.0.0.1 only)${NC}"
    if [[ -n "$XRAY_UUID" ]]; then
        echo -e "  UUID      :  ${GREEN}${XRAY_UUID}${NC}"
    fi
    if [[ -n "$XRAY_PASSWORD" ]]; then
        echo -e "  Password  :  ${GREEN}${XRAY_PASSWORD}${NC}"
    fi
    echo ""

    if [[ -n "$pubkey" ]]; then
        echo -e "  ${BOLD}DNSTT Public Key${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}${pubkey}${NC}"
        echo ""
    fi

    # Generate client URI
    local credential
    if [[ -n "$XRAY_UUID" ]]; then
        credential="$XRAY_UUID"
    else
        credential="$XRAY_PASSWORD"
    fi
    # Use 127.0.0.1 as address — client connects through DNSTT tunnel (SlipNet),
    # so traffic exits on the server side where Xray listens on localhost only
    local client_uri
    client_uri=$(generate_xray_client_uri "$XRAY_PROTOCOL" "127.0.0.1" "$XRAY_INBOUND_PORT" "$credential" "DNSTT-${XRAY_PROTOCOL}")

    echo -e "  ${BOLD}Client URI (for Nekobox)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}${client_uri}${NC}"
    echo ""

    # Generate slipnet:// URL for this tunnel (include SOCKS auth if configured)
    if [[ -n "$pubkey" ]]; then
        local s_user="" s_pass=""
        detect_socks_auth 2>/dev/null || ignore_failure
        if [[ "${SOCKS_AUTH:-}" == true ]]; then
            s_user="${SOCKS_USER:-}"
            s_pass="${SOCKS_PASS:-}"
        fi
        local slipnet_url
        slipnet_url=$(generate_slipnet_url "dnstt" "x" "$pubkey" "" "" "$s_user" "$s_pass")
        echo -e "  ${BOLD}SlipNet URL (for DNSTT tunnel)${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}${slipnet_url}${NC}"
        echo ""
    fi

    echo -e "  ${BOLD}Required DNS Record (Cloudflare)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  Type: ${YELLOW}NS${NC}  │  Name: ${YELLOW}x${NC}  │  Value: ${YELLOW}ns.${DOMAIN}${NC}"
    echo -e "  ${DIM}Proxy: OFF (grey cloud)${NC}"
    echo ""

    echo -e "  ${BOLD}Client Setup (Nekobox + SlipNet)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${DIM}1. Import SlipNet URL above into SlipNet app${NC}"
    echo -e "  ${DIM}2. Enable 'Proxy Only Mode' in SlipNet (SOCKS on 127.0.0.1:1080)${NC}"
    echo -e "  ${DIM}3. In Nekobox, add new proxy using the Client URI above${NC}"
    echo -e "  ${DIM}4. In Nekobox, chain it through SlipNet's SOCKS proxy${NC}"
    echo -e "  ${DIM}5. Enable 'UDP over TCP' in both configs${NC}"
    echo -e "  ${DIM}6. Bypass SlipNet from Nekobox routing to avoid loops${NC}"
    echo ""
    echo -e "  ${DIM}Management: sudo bash $0 --manage${NC}"
    echo -e "  ${DIM}Status:     sudo bash $0 --status${NC}"
    echo ""
}

# ─── --manage ────────────────────────────────────────────────────────────────────
