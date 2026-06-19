#!/usr/bin/env bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Author: Mammad3861
# Version: 1.2.1 - Stable menu/curl dispatch + Docker reliability fixes
# Description: Deploy web-accessible Chromium and Firefox containers.
# ==========================================================

set -o pipefail

# UI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_BASE="${CONFIG_BASE:-/opt/instant-linux-browser}"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS:---no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage --disable-setuid-sandbox}"

info() { echo -e "${CYAN}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

# Root check
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "This script must be run with sudo or as root. Example: curl -fsSL URL | sudo bash"
fi

# Detect Timezone
SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

# Use the real terminal for prompts. This keeps the menu working even when
# the script is executed with: curl -fsSL .../browser.sh | sudo bash
TTY_INPUT=""
if [[ -r /dev/tty ]]; then
    TTY_INPUT="/dev/tty"
fi

prompt_text() {
    local prompt="$1"
    local default_value="${2:-}"
    local value=""

    if [[ -n "$TTY_INPUT" ]]; then
        read -r -p "$prompt" value < "$TTY_INPUT"
    else
        read -r -p "$prompt" value || true
    fi

    echo "${value:-$default_value}"
}

prompt_secret() {
    local prompt="$1"
    local value=""

    if [[ -n "$TTY_INPUT" ]]; then
        read -r -s -p "$prompt" value < "$TTY_INPUT"
        echo > /dev/tty
    else
        read -r -s -p "$prompt" value || true
        echo
    fi

    echo "$value"
}

is_debian_like() {
    command -v apt-get >/dev/null 2>&1
}

install_basic_packages() {
    if ! is_debian_like; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update failed. Check DNS, apt mirrors, or outbound network access."
    apt-get install -y --no-install-recommends ca-certificates curl gnupg || die "Failed to install ca-certificates/curl/gnupg."
}

check_docker() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi

    if ! is_debian_like; then
        die "Docker is not installed. Install Docker for this Linux distribution, then run this script again."
    fi

    warn "Docker not found. Installing Docker from the Ubuntu/Debian package repositories..."
    install_basic_packages
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y docker.io || die "Failed to install Docker. Install Docker manually and run this script again."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker >/dev/null 2>&1 || true
    fi
}

ensure_docker_ready() {
    check_docker

    if ! docker info >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start docker >/dev/null 2>&1 || true
        fi
    fi

    docker info >/dev/null 2>&1 || die "Docker is installed but not running/reachable. Start Docker and run this script again."
}

# Resolve PUID/PGID (prefer the sudo user; fallback safely)
resolve_puid_pgid() {
    local puid pgid
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        puid=$(id -u "$SUDO_USER" 2>/dev/null)
        pgid=$(id -g "$SUDO_USER" 2>/dev/null)
    fi

    if [[ -z "${puid:-}" || -z "${pgid:-}" ]]; then
        if command -v getent >/dev/null 2>&1 && getent passwd 1000 >/dev/null 2>&1; then
            puid=1000
            pgid=$(getent passwd 1000 | cut -d: -f4)
        else
            puid=0
            pgid=0
        fi
    fi

    echo "$puid:$pgid"
}

# Detect a usable IP for display (local first, then public)
detect_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]] && command -v curl >/dev/null 2>&1; then
        ip=$(curl -4 -s --max-time 4 ifconfig.me 2>/dev/null)
    fi
    echo "${ip:-YOUR_SERVER_IP}"
}

# Exact container-name existence check (avoid grep partial matches)
container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xq "$1"
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

check_port_available() {
    local port="$1"
    if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
        die "Port $port is already in use. Stop the existing service or edit the port in browser.sh."
    fi

    if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        die "Port $port is already in use. Stop the existing service or edit the port in browser.sh."
    fi

    if command -v netstat >/dev/null 2>&1 && netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
        die "Port $port is already in use. Stop the existing service or edit the port in browser.sh."
    fi

    if docker ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(^|[[:space:],])[^[:space:],]*:${port}->"; then
        die "Port $port is already in use. Stop the existing service or edit the port in browser.sh."
    fi
}

normalize_arch() {
    local arch="${1:-}"
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

detect_arch() {
    uname -m 2>/dev/null || echo unknown
}

show_arch_info() {
    local raw_arch normalized_arch
    raw_arch="$(detect_arch)"
    normalized_arch="$(normalize_arch "$raw_arch")"

    if [[ "$normalized_arch" == "unsupported" ]]; then
        die "Unsupported architecture: $raw_arch. Instant Linux Browser supports amd64/x86_64 and arm64/aarch64 Linux servers."
    fi

    info "Detected architecture: $normalized_arch ($raw_arch)"
}

install_browser() {
    local browser="$1"
    local image="$2"
    local port="$3"
    local ssl_port=$((port + 1))

    ensure_docker_ready
    show_arch_info

    if container_exists "$browser"; then
        die "$browser container already exists. Use the uninstall option first if you want to recreate it."
    fi

    check_port_available "$port"
    check_port_available "$ssl_port"

    echo -e "${CYAN}--- Configuration for $browser ---${NC}"
    local username=""
    local password=""

    if [[ -n "${ILB_USERNAME+x}" ]]; then
        username="$ILB_USERNAME"
    else
        username=$(prompt_text "Enter UI Username (default: admin): " "admin")
    fi
    username="${username:-admin}"

    if [[ -n "${ILB_PASSWORD+x}" ]]; then
        password="$ILB_PASSWORD"
    else
        password=$(prompt_secret "Enter UI Password: ")
    fi

    if [[ -z "$password" ]]; then
        warn "Empty UI password selected. Use a firewall or reverse proxy allow-list if this server is reachable from the internet."
    fi

    info "Pulling $image..."
    docker pull "$image" || die "Failed to pull $image. Check internet access, DNS, Docker, and whether the image supports this CPU architecture."

    local puid_pgid puid pgid config_dir
    puid_pgid="$(resolve_puid_pgid)"
    puid="${puid_pgid%%:*}"
    pgid="${puid_pgid##*:}"

    config_dir="${CONFIG_BASE}/${browser}/config"
    mkdir -p "$config_dir"
    chown -R "${puid}:${pgid}" "${CONFIG_BASE}/${browser}" 2>/dev/null || true

    local extra_caps=()
    local extra_security=()
    local browser_env=()

    if [[ "$browser" == "chromium" ]]; then
        # These flags help Chromium start on restricted VPS/Docker environments.
        extra_caps+=(--cap-add=SYS_ADMIN)
        extra_security+=(--security-opt seccomp=unconfined)
        browser_env+=(-e "CHROME_CLI=$CHROMIUM_FLAGS" -e "CHROME_FLAGS=$CHROMIUM_FLAGS")
        info "Applying Chromium flags through CHROME_CLI and CHROME_FLAGS: $CHROMIUM_FLAGS"
    fi

    info "Deploying $browser... Please wait."
    if ! docker run -d \
        --name="$browser" \
        "${extra_caps[@]}" \
        "${extra_security[@]}" \
        -e "PUID=$puid" \
        -e "PGID=$pgid" \
        -e "TZ=$SERVER_TZ" \
        -e "CUSTOM_USER=$username" \
        -e "PASSWORD=$password" \
        "${browser_env[@]}" \
        -p "${port}:3000" \
        -p "${ssl_port}:3001" \
        -v "${config_dir}:/config" \
        --shm-size="2gb" \
        --restart unless-stopped \
        "$image"; then
        echo "Docker failed to start $browser."
        if container_exists "$browser"; then
            echo "Recent logs:"
            docker logs --tail 80 "$browser" 2>/dev/null || true
        fi
        die "Check ports, image availability, Docker permissions, and the logs above if present."
    fi

    sleep 4
    if ! container_running "$browser"; then
        echo -e "${RED}$browser did not start successfully.${NC}"
        echo "Recent logs:"
        docker logs --tail 80 "$browser" 2>/dev/null || true
        die "Container exited. Check the logs above."
    fi

    local ip
    ip=$(detect_ip)

    success "================================================"
    success "Deployment Successful!"
    echo -e "Access URL (HTTP) : ${CYAN}http://${ip}:${port}${NC}"
    echo -e "Access URL (HTTPS): ${CYAN}https://${ip}:${ssl_port}${NC}"
    echo -e "Credentials       : ${YELLOW}$username / $password${NC}"
    echo -e "${YELLOW}Note: Accept the SSL warning in your browser.${NC}"
    success "================================================"
}

uninstall_browser() {
    local browser="$1"
    info "Removing $browser..."
    ensure_docker_ready
    docker stop "$browser" >/dev/null 2>&1 || true
    docker rm "$browser" >/dev/null 2>&1 || true
    success "Cleanup complete. Persistent config was kept at ${CONFIG_BASE}/${browser}/config."
}

show_status() {
    ensure_docker_ready
    show_arch_info
    echo -e "${CYAN}Config base:${NC} ${CONFIG_BASE}"
    echo -e "${CYAN}--- Containers ---${NC}"
    docker ps -a --filter "name=chromium" --filter "name=firefox" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

show_menu() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN}     Instant Linux Browser Installer${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "1) Install Chromium (HTTP 3000 / HTTPS 3001)"
    echo -e "2) Uninstall Chromium"
    echo -e "3) Install Firefox (HTTP 4000 / HTTPS 4001)"
    echo -e "4) Uninstall Firefox"
    echo -e "5) Show Status"
    echo -e "6) Exit"
    echo -e "${CYAN}==========================================${NC}"
}

read_menu_choice() {
    local choice=""
    if [[ -n "$TTY_INPUT" ]]; then
        read -r -p "Select an option [1-6]: " choice < "$TTY_INPUT"
    else
        die "No interactive terminal was found. Download the script first and run 'sudo bash browser.sh', or run with ILB_ACTION=install-chromium."
    fi
    echo "$choice"
}

run_action() {
    local choice="$1"
    case "$choice" in
        1|chromium|install-chromium)
            install_browser "chromium" "lscr.io/linuxserver/chromium:latest" "3000"
            ;;
        2|uninstall-chromium|remove-chromium)
            uninstall_browser "chromium"
            ;;
        3|firefox|install-firefox)
            install_browser "firefox" "lscr.io/linuxserver/firefox:latest" "4000"
            ;;
        4|uninstall-firefox|remove-firefox)
            uninstall_browser "firefox"
            ;;
        5|status|diagnostics|diag)
            show_status
            ;;
        6|exit|quit)
            exit 0
            ;;
        *)
            die "Invalid option: ${choice:-empty}. Use 1-6, install-chromium, uninstall-chromium, install-firefox, uninstall-firefox, or status."
            ;;
    esac
}

main() {
    local action="${ILB_ACTION:-${1:-}}"

    if [[ -n "$action" ]]; then
        run_action "$action"
        return
    fi

    show_menu
    action=$(read_menu_choice)
    run_action "$action"
}

main "$@"
