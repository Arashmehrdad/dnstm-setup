# shellcheck shell=bash

set -euo pipefail

if [[ -n "${DNSTM_UI_SH_LOADED:-}" ]]; then
    return 0
fi
readonly DNSTM_UI_SH_LOADED=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CHECK="${GREEN}[✓]${NC}"
CROSS="${RED}[✗]${NC}"
WARN="${YELLOW}[!]${NC}"
INFO="${CYAN}[i]${NC}"

print_header() {
    local title="$1"
    local width=60
    local line
    line=$(printf '─%.0s' $(seq 1 $width))
    echo ""
    echo -e "${BOLD}${CYAN}┌${line}┐${NC}"
    printf "${BOLD}${CYAN}│${NC} %-$((width - 1))s${BOLD}${CYAN}│${NC}\n" "$title"
    echo -e "${BOLD}${CYAN}└${line}┘${NC}"
    echo ""
}

print_step() {
    local step=$1
    local title="$2"
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}[${step}/${TOTAL_STEPS}]${NC}  ${BOLD}${title}${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_ok() {
    echo -e "  ${CHECK} $1"
}

print_fail() {
    echo -e "  ${CROSS} $1"
}

print_warn() {
    echo -e "  ${WARN} $1"
}

print_info() {
    echo -e "  ${INFO} $1"
}

print_box() {
    local lines=("$@")
    # Calculate width from longest line
    local width=58
    for l in "${lines[@]}"; do
        local len=${#l}
        if (( len + 2 > width )); then
            width=$((len + 2))
        fi
    done
    local line
    line=$(printf '─%.0s' $(seq 1 $width))
    echo -e "  ${DIM}┌${line}┐${NC}"
    for l in "${lines[@]}"; do
        printf "  ${DIM}│${NC} %-$((width - 1))s${DIM}│${NC}\n" "$l"
    done
    echo -e "  ${DIM}└${line}┘${NC}"
}

# Check if a tunnel tag exists in dnstm tunnel list output.
# Handles both `tag=name` and bare `name` formats in the output.
# Usage: dnstm_tag_exists <tag>

prompt_yn() {
    local question="$1"
    local default="${2:-n}"
    local yn_hint
    if [[ "$default" == "y" ]]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi
    while true; do
        echo ""
        echo -ne "  ${BOLD}${question}${NC} ${yn_hint} ${DIM}[h=help]${NC} "
        read -r answer </dev/tty 2>/dev/null || read -r answer
        answer=${answer:-$default}
        if [[ "$answer" =~ ^[Hh]$ ]]; then
            show_help_menu
            continue
        fi
        if [[ "$answer" =~ ^[Yy] ]]; then
            return 0
        else
            return 1
        fi
    done
}

prompt_input() {
    local question="$1"
    local default="${2:-}"
    local result
    while true; do
        if [[ -n "$default" ]]; then
            echo -ne "  ${BOLD}${question}${NC} [${default}] ${DIM}(h=help)${NC}: " >&2
        else
            echo -ne "  ${BOLD}${question}${NC} ${DIM}(h=help)${NC}: " >&2
        fi
        read -r result </dev/tty 2>/dev/null || read -r result
        result=${result:-$default}
        if [[ "$result" =~ ^[Hh]$ ]]; then
            show_help_menu >&2
            continue
        fi
        echo "$result"
        return
    done
}

banner() {
    local w=54
    local border empty
    border=$(printf '═%.0s' $(seq 1 $w))
    empty=$(printf ' %.0s' $(seq 1 $w))
    local ver_text="dnstm-setup v${VERSION}"
    local sub_text="Interactive DNS Tunnel Setup"
    local vl=$(( (w - ${#ver_text}) / 2 ))
    local vr=$(( w - ${#ver_text} - vl ))
    local sl=$(( (w - ${#sub_text}) / 2 ))
    local sr=$(( w - ${#sub_text} - sl ))
    echo ""
    echo -e "${BOLD}${CYAN}"
    printf "  ╔%s╗\n" "$border"
    printf "  ║%s║\n" "$empty"
    printf "  ║%${vl}s%s%${vr}s║\n" "" "$ver_text" ""
    printf "  ║%${sl}s%s%${sr}s║\n" "" "$sub_text" ""
    printf "  ║%s║\n" "$empty"
    printf "  ╚%s╝\n" "$border"
    echo -e "${NC}"
}

# ─── Help System ──────────────────────────────────────────────────────────────

help_topic_header() {
    local title="$1"
    local width=58
    local line
    line=$(printf '─%.0s' $(seq 1 $width))
    # Compensate for multi-byte chars: pad width = visual width + (bytes - chars)
    local byte_len=${#title}
    local byte_count
    byte_count=$(printf '%s' "$title" | wc -c)
    local pad_width=$(( width - 1 + byte_count - byte_len ))
    echo ""
    echo -e "  ${BOLD}${CYAN}┌${line}┐${NC}"
    printf "  ${BOLD}${CYAN}│${NC} ${BOLD}%-${pad_width}s${BOLD}${CYAN}│${NC}\n" "$title"
    echo -e "  ${BOLD}${CYAN}└${line}┘${NC}"
    echo ""
}

help_press_enter() {
    echo ""
    echo -ne "  ${DIM}Press Enter to go back...${NC}"
    if ! read -r </dev/tty 2>/dev/null; then
        read -r || ignore_failure "read help prompt"
    fi
}

help_topic_domain() {
    help_topic_header "1. Domains & DNS Basics"
    echo -e "  ${BOLD}What is a domain?${NC}"
    echo "  A domain (e.g. example.com) is a human-readable address"
    echo "  on the internet. DNS tunneling uses domains to encode"
    echo "  data inside DNS queries, making your traffic look like"
    echo "  normal DNS resolution."
    echo ""
    echo -e "  ${BOLD}Why do you need one?${NC}"
    echo "  DNS tunnels work by making DNS queries for subdomains"
    echo "  of YOUR domain. The DNS system routes these queries to"
    echo "  your server, which decodes the hidden data. Without a"
    echo "  domain you own, you can't receive these queries."
    echo ""
    echo -e "  ${BOLD}How DNS delegation works${NC}"
    echo "  When you create NS records pointing t.example.com to"
    echo "  ns.example.com (your server), you tell the global DNS"
    echo "  system: 'For any query about t.example.com, ask my"
    echo "  server directly.' This is how tunnel traffic finds you."
    echo ""
    echo -e "  ${BOLD}Where to buy a domain${NC}"
    echo "  - Namecheap (namecheap.com) — cheap, privacy included"
    echo "  - Cloudflare Registrar — at-cost pricing"
    echo "  - Any registrar works, but you MUST use Cloudflare DNS"
    echo "    (free plan) to manage your records"
    echo ""
    echo -e "  ${BOLD}Subdomains used by this script${NC}"
    echo "  If your domain is example.com:"
    echo "    t.example.com   ->  Slipstream + SOCKS tunnel"
    echo "    d.example.com   ->  DNSTT + SOCKS tunnel"
    echo "    s.example.com   ->  Slipstream + SSH tunnel"
    echo "    ds.example.com  ->  DNSTT + SSH tunnel"
    help_press_enter
}

help_topic_dns_records() {
    help_topic_header "2. DNS Records (Cloudflare Setup)"
    echo -e "  ${BOLD}What are DNS records?${NC}"
    echo "  DNS records are entries that tell the internet how to"
    echo "  find services for your domain."
    echo ""
    echo -e "  ${BOLD}A Record (Address Record)${NC}"
    echo "  Maps a name to an IP address."
    echo "  We create:  ns.yourdomain.com -> your server IP"
    echo "  This tells the internet where your DNS server lives."
    echo ""
    echo -e "  ${BOLD}NS Record (Name Server Record)${NC}"
    echo "  Delegates a subdomain to another DNS server."
    echo "  We create:  t.yourdomain.com NS -> ns.yourdomain.com"
    echo "  This tells the internet: 'For queries about t, ask"
    echo "  the server at ns.yourdomain.com (your VPS).'"
    echo ""
    echo -e "  ${BOLD}Why 'DNS Only' (grey cloud)?${NC}"
    echo "  Cloudflare's proxy (orange cloud) intercepts traffic."
    echo "  DNS tunneling requires queries to reach YOUR server"
    echo "  directly. If the proxy is ON, queries go to Cloudflare"
    echo "  instead and tunneling breaks completely."
    echo ""
    echo -e "  ${BOLD}Why 4 subdomains?${NC}"
    echo "  Each tunnel type needs its own subdomain so the DNS"
    echo "  Router can route them to the right tunnel:"
    echo "    t   -> Slipstream + SOCKS  (fastest, QUIC-based)"
    echo "    d   -> DNSTT + SOCKS       (classic, Noise protocol)"
    echo "    s   -> Slipstream + SSH    (SSH over DNS)"
    echo "    ds  -> DNSTT + SSH         (SSH over DNSTT)"
    echo ""
    echo -e "  ${BOLD}Common mistakes${NC}"
    echo "  - Using 'tns' instead of 'ns' for the A record name"
    echo "  - Leaving Cloudflare proxy ON (must be grey cloud)"
    echo "  - Setting NS values to the IP instead of ns.domain"
    echo "  - Forgetting to click Save after adding records"
    help_press_enter
}

help_topic_port53() {
    help_topic_header "3. Port 53 & systemd-resolved"
    echo -e "  ${BOLD}What is port 53?${NC}"
    echo "  Port 53 is the standard port for all DNS traffic."
    echo "  Every DNS query in the world is sent to port 53."
    echo "  Censors almost never block it because it would break"
    echo "  DNS for everyone."
    echo ""
    echo -e "  ${BOLD}Why do DNS tunnels need port 53?${NC}"
    echo "  When a DNS resolver (like 8.8.8.8) forwards a query"
    echo "  to your server, it always sends it to port 53. Your"
    echo "  tunnel server must listen on port 53 to receive these"
    echo "  queries. There is no way to use a different port."
    echo ""
    echo -e "  ${BOLD}What is systemd-resolved?${NC}"
    echo "  systemd-resolved is Ubuntu's built-in DNS cache. It"
    echo "  listens on 127.0.0.53:53 to handle local DNS lookups."
    echo "  Since it occupies port 53, it must be stopped before"
    echo "  the DNS tunnel server can bind to that port."
    echo ""
    echo -e "  ${BOLD}Is it safe to disable?${NC}"
    echo "  Yes! We replace it with 8.8.8.8 (Google DNS) in"
    echo "  /etc/resolv.conf. Your server still resolves domain"
    echo "  names normally — it just queries Google DNS directly"
    echo "  instead of using the local cache."
    help_press_enter
}

help_topic_dnstm() {
    help_topic_header "4. dnstm — DNS Tunnel Manager"
    echo -e "  ${BOLD}What is dnstm?${NC}"
    echo "  A command-line tool that installs, configures, and"
    echo "  manages DNS tunnel servers. Handles all the complex"
    echo "  setup automatically."
    echo ""
    echo -e "  ${BOLD}What is 'multi mode'?${NC}"
    echo "  Multi mode lets multiple tunnels share port 53 through"
    echo "  a DNS Router. The router reads incoming DNS queries and"
    echo "  routes them to the correct tunnel based on subdomain."
    echo ""
    echo -e "  ${BOLD}What gets installed${NC}"
    echo "  - slipstream-server   QUIC-based tunnel binary"
    echo "  - dnstt-server        Classic DNS tunnel binary"
    echo "  - microsocks          SOCKS5 proxy (auto-assigned port)"
    echo "  - systemd services    Auto-start tunnels on boot"
    echo "  - DNS Router          Multiplexes port 53"
    echo ""
    echo -e "  ${BOLD}How the DNS Router works${NC}"
    echo "  All DNS queries arrive at port 53. The router inspects"
    echo "  the domain name: if it's for t.example.com, it sends"
    echo "  the query to Slipstream. If it's for d.example.com,"
    echo "  it routes to DNSTT. Each tunnel decodes the data and"
    echo "  forwards it through microsocks to the internet."
    help_press_enter
}

help_topic_ssh() {
    help_topic_header "5. SSH Tunnel Users"
    echo -e "  ${BOLD}What is an SSH tunnel user?${NC}"
    echo "  A restricted account that can ONLY create SSH port-"
    echo "  forwarding tunnels. Cannot run commands, access a"
    echo "  shell, or browse the filesystem."
    echo ""
    echo -e "  ${BOLD}How is it different from a regular user?${NC}"
    echo "  A regular user (like root) has full server access."
    echo "  An SSH tunnel user can ONLY forward ports. Even if"
    echo "  the password is leaked, no one can access your server."
    echo ""
    echo -e "  ${BOLD}How Slipstream + SSH works${NC}"
    echo "  Client -> DNS query -> DNS resolver -> Your server"
    echo "   -> Slipstream (decodes DNS) -> SSH connection"
    echo "   -> SSH port forwarding (-D) -> Internet"
    echo ""
    echo -e "  ${BOLD}SSH vs SOCKS backend${NC}"
    echo "  SOCKS (t/d tunnels):"
    echo "    - Faster, no authentication needed"
    echo "    - Anyone who knows the domain can connect"
    echo "  SSH (s/ds tunnels):"
    echo "    - Requires username + password to connect"
    echo "    - Only authorized users can use it"
    echo "    - Slightly slower (SSH encryption overhead)"
    echo ""
    echo -e "  ${BOLD}Username & password${NC}"
    echo "  - The username/password are shared with ALL your users"
    echo "  - Keep the username simple (e.g. 'tunnel', 'vpn')"
    echo "  - Use a memorable password, NOT your root password"
    echo "  - Even if leaked, the account is port-forwarding only"
    help_press_enter
}

help_topic_architecture() {
    help_topic_header "6. Architecture & How It Works"
    echo -e "  ${BOLD}The Big Picture${NC}"
    echo "  DNS tunneling encodes your internet traffic inside DNS"
    echo "  queries. Since DNS is almost never blocked, it provides"
    echo "  a reliable channel even during internet shutdowns."
    echo ""
    echo -e "  ${BOLD}Data Flow${NC}"
    echo ""
    echo "    Phone (SlipNet app)"
    echo "      |"
    echo "      v"
    echo "    DNS Query (looks like normal DNS traffic)"
    echo "      |"
    echo "      v"
    echo "    Public DNS Resolver (8.8.8.8, 1.1.1.1, etc.)"
    echo "      |"
    echo "      v"
    echo "    Your Server, Port 53"
    echo "      |"
    echo "      v"
    echo "    DNS Router --+--> t   --> Slipstream --+--> microsocks"
    echo "                 +--> d   --> DNSTT -------+    (SOCKS5)"
    echo "                 +--> s   --> Slip+SSH ----+       |"
    echo "                 +--> ds  --> DNSTT+SSH ---+       v"
    echo "                                              Internet"
    echo ""
    echo -e "  ${BOLD}Protocols${NC}"
    echo "  Slipstream: QUIC-based, TLS encryption, ~63 KB/s"
    echo "  DNSTT:      Noise protocol, Curve25519 keys, ~42 KB/s"
    echo ""
    echo -e "  ${BOLD}Why DNS?${NC}"
    echo "  DNS is the internet's phone book. EVERY device needs"
    echo "  it to work, so censors almost never block it. By hiding"
    echo "  traffic inside DNS queries, you can bypass blocks that"
    echo "  shut down VPNs, Tor, and other tools."
    help_press_enter
}

help_topic_about() {
    help_topic_header "About dnstm-setup"
    echo -e "  ${BOLD}Made By SamNet Technologies - Saman${NC}"
    echo ""
    echo -e "  ${BOLD}dnstm-setup${NC} v${VERSION}"
    echo "  Interactive DNS Tunnel Setup Wizard"
    echo ""
    echo "  Automates the complete setup of DNS tunnel servers"
    echo "  for censorship-resistant internet access. Designed"
    echo "  to help people in restricted regions stay connected."
    echo ""
    echo -e "  ${BOLD}Links${NC}"
    echo "  dnstm-setup   github.com/SamNet-dev/dnstm-setup"
    echo "  dnstm          github.com/net2share/dnstm"
    echo "  sshtun-user    github.com/net2share/sshtun-user"
    echo "  SlipNet        github.com/anonvector/SlipNet"
    echo ""
    echo -e "  ${BOLD}Manual Guide (Farsi)${NC}"
    echo "  telegra.ph/Complete-Guide-to-Setting-Up-a-DNS-Tunnel-03-04"
    echo ""
    echo -e "  ${BOLD}Donate${NC}"
    echo "  www.samnet.dev/donate"
    echo ""
    echo -e "  ${BOLD}License${NC}"
    echo "  MIT License"
    help_press_enter
}

show_help_menu() {
    while true; do
        help_topic_header "Help — Pick a Topic"
        echo -e "  ${BOLD}1${NC}  Domains & DNS Basics"
        echo -e "  ${BOLD}2${NC}  DNS Records (Cloudflare Setup)"
        echo -e "  ${BOLD}3${NC}  Port 53 & systemd-resolved"
        echo -e "  ${BOLD}4${NC}  dnstm — DNS Tunnel Manager"
        echo -e "  ${BOLD}5${NC}  SSH Tunnel Users"
        echo -e "  ${BOLD}6${NC}  Architecture & How It Works"
        echo ""
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}7${NC}  About"
        echo ""
        echo -ne "  ${DIM}Pick a topic (1-7) or Enter to go back: ${NC}"
        read -r choice
        case "${choice:-}" in
            1) help_topic_domain ;;
            2) help_topic_dns_records ;;
            3) help_topic_port53 ;;
            4) help_topic_dnstm ;;
            5) help_topic_ssh ;;
            6) help_topic_architecture ;;
            7) help_topic_about ;;
            *)
                if [[ -n "${choice:-}" ]]; then
                    echo -e "  ${WARN} Invalid choice. Please pick 1–7 or Enter to go back."
                fi
                echo ""
                return
                ;;
        esac
    done
}

# ─── --help ─────────────────────────────────────────────────────────────────────

show_help() {
    banner
    echo -e "${BOLD}DESCRIPTION${NC}"
    echo "  dnstm-setup automates the complete setup of DNS tunnel servers for"
    echo "  censorship-resistant internet access. It installs and configures dnstm"
    echo "  (DNS Tunnel Manager) with Slipstream and DNSTT protocols, sets up SOCKS"
    echo "  and SSH tunnels, and verifies everything works end-to-end."
    echo ""
    echo -e "${BOLD}PREREQUISITES${NC}"
    echo "  - A VPS running Ubuntu/Debian with root access"
    echo "  - A domain managed on Cloudflare"
    echo "  - curl installed on the server"
    echo ""
    echo -e "${BOLD}USAGE${NC}"
    echo "  sudo dnstm-setup                       Run interactive setup"
    echo "  sudo dnstm-setup --manage              Post-setup management menu"
    echo "  sudo dnstm-setup --add-domain          Add a backup domain to existing setup"
    echo "  sudo dnstm-setup --mtu 1200            Set DNSTT MTU (default: 1232)"
    echo "  sudo dnstm-setup --add-tunnel          Add a single tunnel interactively"
    echo "  sudo dnstm-setup --add-xray            Connect existing Xray panel via DNS tunnel"
    echo "  sudo dnstm-setup --remove-tunnel [tag] Remove a specific tunnel"
    echo "  sudo dnstm-setup --harden              Apply security hardening only"
    echo "  sudo dnstm-setup --uninstall           Remove everything"
    echo "  sudo dnstm-setup --status              Show all tunnels & share URLs"
    echo "  sudo dnstm-setup --monitor             Monitor tunnel usage & connections"
    echo "  dnstm-setup --help                     Show this help"
    echo "  dnstm-setup --about                    Show project info"
    echo ""
    echo -e "${BOLD}FLAGS${NC}"
    echo "  --help         Show this help message"
    echo "  --about        Show project information and credits"
    echo "  --manage       Interactive management menu (all post-setup actions)"
    echo "  --status       Show all tunnels, credentials, and share URLs"
    echo "  --monitor      Show tunnel process stats, connections, and recent logs"
    echo "  --add-tunnel   Add a single tunnel (interactive: choose transport, backend, domain)"
    echo "  --add-xray     Connect existing 3x-ui panel to DNS tunnel (auto-detect + create inbound)"
    echo "  --remove-tunnel [tag]  Remove a specific tunnel (interactive if no tag given)"
    echo "  --add-domain   Add another domain to an existing server (backup/fallback)"
    echo "  --users        Manage SSH tunnel users (add, list, update, delete)"
    echo "  --mtu <value>  Set DNSTT MTU size (512-1400, default: 1232)"
    echo "  --harden       Apply service and resolver hardening to an existing setup"
    echo "  --update       Refresh the installed tree from the default branch"
    echo "  --dry-run      Show planned changes without mutating the system"
    echo "  --debug        Enable verbose logging"
    echo "  --log-file <path>  Write logs to a custom file (default: /var/log/dnstm-setup.log)"
    echo "  --uninstall    Remove all installed components"
    echo ""
    echo -e "${BOLD}WHAT THIS SCRIPT SETS UP${NC}"
    echo "  1. Slipstream + SOCKS tunnel  (fastest, ~63 KB/s)"
    echo "  2. DNSTT + SOCKS tunnel       (classic, ~42 KB/s)"
    echo "  3. Slipstream + SSH tunnel    (SSH over DNS)"
    echo "  4. DNSTT + SSH tunnel         (SSH over DNSTT)"
    echo "  5. microsocks SOCKS5 proxy    (auto-installed by dnstm)"
    echo "  6. SSH tunnel user (optional)"
    echo ""
    echo -e "${BOLD}CLIENT APP${NC}"
    echo "  SlipNet (Android): https://github.com/anonvector/SlipNet/releases"
    echo ""
}

# ─── --about ────────────────────────────────────────────────────────────────────

show_about() {
    banner
    echo -e "${BOLD}ABOUT${NC}"
    echo ""
    echo "  dnstm-setup is an interactive installer for DNS tunnel servers."
    echo "  It provides a guided, step-by-step setup process with colored"
    echo "  output, progress tracking, and automated verification."
    echo ""
    echo -e "${BOLD}HOW DNS TUNNELING WORKS${NC}"
    echo ""
    echo "  DNS tunneling encodes data inside DNS queries and responses."
    echo "  Since DNS is almost never blocked (even during internet shutdowns),"
    echo "  it provides a reliable channel for internet access. Your traffic"
    echo "  flows through public DNS resolvers to your tunnel server, which"
    echo "  decodes it and forwards it to the internet."
    echo ""
    echo "  Architecture:"
    echo ""
    echo "    Client (SlipNet)"
    echo "      --> DNS Query"
    echo "        --> Public Resolver (8.8.8.8)"
    echo "          --> Your Server (Port 53)"
    echo "            --> DNS Router"
    echo "              --> Tunnel --> Internet"
    echo ""
    echo -e "${BOLD}SUPPORTED PROTOCOLS${NC}"
    echo ""
    echo "  Slipstream  QUIC-based DNS tunnel with TLS encryption"
    echo "              Uses self-signed certificates (cert.pem/key.pem)"
    echo "              Speed: ~63 KB/s"
    echo ""
    echo "  DNSTT       Classic DNS tunnel using Noise protocol"
    echo "              Uses Curve25519 key pairs (server.key/server.pub)"
    echo "              Speed: ~42 KB/s"
    echo ""
    echo -e "${BOLD}RELATED PROJECTS${NC}"
    echo ""
    echo "  dnstm          https://github.com/net2share/dnstm"
    echo "  sshtun-user    https://github.com/net2share/sshtun-user"
    echo "  SlipNet        https://github.com/anonvector/SlipNet/releases"
    echo ""
    echo -e "${BOLD}LICENSE${NC}"
    echo ""
    echo "  MIT License"
    echo ""
    echo -e "${BOLD}AUTHOR${NC}"
    echo ""
    echo "  Made By SamNet Technologies - Saman"
    echo "  https://github.com/SamNet-dev"
    echo ""
}

# ─── SOCKS Auth Detection Helper ──────────────────────────────────────────────

# Detect SOCKS5 auth state from dnstm backend status.
# Sets globals: SOCKS_AUTH (true/false), SOCKS_USER, SOCKS_PASS
# Returns 0 if auth is enabled, 1 otherwise.
