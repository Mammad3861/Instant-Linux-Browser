#!/usr/bin/env bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Author: Mammad3861
# Version: 1.2.0 - Server hardening + Chromium diagnostics
# Description: Automated deployment for web-based browsers.
# ==========================================================

set -o pipefail

# UI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_BASE="${CONFIG_BASE:-/opt/instant-linux-browser}"
DEFAULT_CHROMIUM_FLAGS="--no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --disable-gpu"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS:-$DEFAULT_CHROMIUM_FLAGS}"

APT_CHROMIUM_DEPS=(
    ca-certificates
    curl
    fonts-liberation
    libatk-bridge2.0-0
    libatk1.0-0
    libcups2
    libdbus-1-3
    libdrm2
    libgbm1
    libgtk-3-0
    libnspr4
    libnss3
    libx11-xcb1
    libxcomposite1
    libxdamage1
    libxrandr2
    xdg-utils
)

die() {
    echo -e "${RED}Error: $*${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}Warning: $*${NC}" >&2
}

info() {
    echo -e "${CYAN}$*${NC}"
}

success() {
    echo -e "${GREEN}$*${NC}"
}

# Root check
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "This script must be run with sudo or as root."
fi

# Detect Timezone
SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

is_debian_like() {
    command -v apt-get >/dev/null 2>&1
}

apt_package_exists() {
    apt-cache show "$1" >/dev/null 2>&1
}

append_if_available() {
    local package=$1
    local target_name=$2
    if apt_package_exists "$package"; then
        eval "$target_name+=(\"$package\")"
        return 0
    fi
    return 1
}

install_apt_packages() {
    local packages=("$@")
    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update failed. Check DNS, apt mirrors, or outbound network access."
    apt-get install -y --no-install-recommends "${packages[@]}" || die "Failed to install required apt packages: ${packages[*]}"
}

install_headless_chromium_deps() {
    if ! is_debian_like; then
        warn "apt-get was not found. Skipping host Chromium dependency install; Docker images still include their own browser dependencies."
        return 0
    fi

    local packages=("${APT_CHROMIUM_DEPS[@]}")
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update failed. Check DNS, apt mirrors, or outbound network access."

    # Ubuntu 24.04+ ships libasound2t64, while older Debian/Ubuntu releases use libasound2.
    if ! append_if_available "libasound2t64" packages; then
        append_if_available "libasound2" packages || warn "Neither libasound2t64 nor libasound2 was found in apt metadata."
    fi

    info "Installing host packages commonly required by headless Chromium..."
    apt-get install -y --no-install-recommends "${packages[@]}" || die "Failed to install required Chromium host packages: ${packages[*]}"
}

check_docker() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi

    info "Docker not found. Installing Docker..."
    if ! command -v curl >/dev/null 2>&1; then
        if is_debian_like; then
            install_apt_packages ca-certificates curl
        else
            die "curl is required to install Docker automatically. Install Docker manually and rerun this script."
        fi
    fi

    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || die "Failed to download Docker installer. Check DNS or outbound HTTPS access."
    sh /tmp/get-docker.sh || die "Docker installer failed. Install Docker manually and rerun this script."
    rm -f /tmp/get-docker.sh
}

ensure_docker_ready() {
    check_docker

    if ! docker info >/dev/null 2>&1; then
        die "Docker is installed but not reachable. Start Docker with 'systemctl start docker' and rerun this script."
    fi
}

detect_browser_binary() {
    local candidate
    for candidate in "${CHROME_BIN:-}" "${PUPPETEER_EXECUTABLE_PATH:-}" \
        /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome \
        /usr/bin/google-chrome-stable /snap/bin/chromium; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

print_browser_diagnostics() {
    local detected_browser
    echo -e "${CYAN}--- Browser diagnostics ---${NC}"

    if detected_browser=$(detect_browser_binary); then
        echo "Host browser binary: $detected_browser"
    else
        echo "Host browser binary: not found"
        echo "This is OK for Docker deployment because the browser runs inside the container."
    fi

    [[ -n "${CHROME_BIN:-}" ]] && echo "CHROME_BIN=$CHROME_BIN"
    [[ -n "${PUPPETEER_EXECUTABLE_PATH:-}" ]] && echo "PUPPETEER_EXECUTABLE_PATH=$PUPPETEER_EXECUTABLE_PATH"
    [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]] && echo "PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH"
    echo "Chromium launch flags: $CHROMIUM_FLAGS"
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
    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -s --max-time 4 ifconfig.me 2>/dev/null)
    fi
    echo "${ip:-YOUR_SERVER_IP}"
}

# Exact container-name existence check (avoid grep partial matches)
container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xq "$1"
}

check_port_available() {
    local port=$1
    if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$port )" | grep -q ":$port"; then
        die "Port $port is already in use. Stop the existing service or change the port in browser.sh."
    fi
}

print_container_failure_help() {
    local browser=$1
    echo -e "${RED}$browser did not start successfully.${NC}"
    echo "Useful checks:"
    echo "  docker logs $browser"
    echo "  docker inspect $browser --format '{{.State.Status}} {{.State.Error}}'"
    if [[ "$browser" == "chromium" ]]; then
        echo "Chromium is started with: $CHROMIUM_FLAGS"
        echo "If the host blocks sandboxing, keep --no-sandbox and --disable-setuid-sandbox enabled."
    fi
}

verify_container_running() {
    local browser=$1
    local state
    sleep 4
    state=$(docker inspect -f '{{.State.Running}}' "$browser" 2>/dev/null || echo "false")
    if [[ "$state" != "true" ]]; then
        print_container_failure_help "$browser"
        docker logs --tail 80 "$browser" 2>/dev/null || true
        return 1
    fi
}

verify_container_browser_binary() {
    local browser=$1
    local binary_check='command -v chromium-browser || command -v chromium || command -v google-chrome || command -v firefox'

    if ! docker exec "$browser" sh -lc "$binary_check" >/dev/null 2>&1; then
        warn "Could not find a browser binary inside the $browser container. Check 'docker logs $browser' for image startup errors."
        return 1
    fi
}

install_browser() {
    local browser=$1
    local image=$2
    local port=$3
    local ssl_port=$((port + 1))

    ensure_docker_ready

    if container_exists "$browser"; then
        die "$browser already exists. Use the uninstall option first if you want to recreate it."
    fi

    check_port_available "$port"
    check_port_available "$ssl_port"

    local username="${ILB_USERNAME:-}"
    local password="${ILB_PASSWORD:-}"

    echo -e "${CYAN}--- Configuration for $browser ---${NC}"
    if [[ -z "$username" && -t 0 ]]; then
        read -r -p "Enter UI Username (default: admin): " username
    fi
    username=${username:-admin}

    if [[ -z "$password" && -t 0 ]]; then
        read -r -s -p "Enter UI Password: " password
        echo
    fi

    if [[ -z "$password" ]]; then
        warn "Empty UI password selected. Use a firewall or reverse proxy allow-list if this server is reachable from the internet."
    fi

    if [[ "$browser" == "chromium" ]]; then
        install_headless_chromium_deps
        print_browser_diagnostics
    fi

    info "Pulling $image..."
    docker pull "$image" || die "Failed to pull $image. Check Docker Hub/GHCR access, DNS, and server architecture."

    local puid_pgid
    puid_pgid="$(resolve_puid_pgid)"
    local puid="${puid_pgid%%:*}"
    local pgid="${puid_pgid##*:}"

    local config_dir="${CONFIG_BASE}/${browser}/config"
    mkdir -p "$config_dir"
    chown -R "${puid}:${pgid}" "${CONFIG_BASE}/${browser}" 2>/dev/null || true

    local extra_caps=()
    local extra_security=()
    local browser_env=()

    if [[ "$browser" == "chromium" ]]; then
        extra_caps+=(--cap-add=SYS_ADMIN)
        extra_security+=(--security-opt seccomp=unconfined)
        # linuxserver/chromium has used CHROME_CLI for startup flags; keep CHROME_FLAGS too
        # for compatibility with older community guidance and derived images.
        browser_env+=(-e "CHROME_CLI=$CHROMIUM_FLAGS" -e "CHROME_FLAGS=$CHROMIUM_FLAGS")
    fi

    info "Deploying $browser..."
    if ! docker run -d \
        --name="$browser" \
        "${extra_caps[@]}" \
        "${extra_security[@]}" \
        -e "PUID=$puid" -e "PGID=$pgid" \
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
        die "Docker failed to start $browser. Check image availability, free ports, and Docker permissions."
    fi

    verify_container_running "$browser" || exit 1
    verify_container_browser_binary "$browser" || true

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
    local browser=$1
    info "Removing $browser..."
    ensure_docker_ready
    docker stop "$browser" >/dev/null 2>&1 || true
    docker rm "$browser" >/dev/null 2>&1 || true
    success "Cleanup complete."
}

show_menu() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN}     Instant Linux Browser Installer${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo "1) Install Chromium (Port 3000)"
    echo "2) Uninstall Chromium"
    echo "3) Install Firefox (Port 4000)"
    echo "4) Uninstall Firefox"
    echo "5) Diagnostics"
    echo "6) Exit"
    echo -e "${CYAN}==========================================${NC}"
}

show_menu
read -r -p "Select an option [1-6]: " choice

case "$choice" in
    1) install_browser "chromium" "lscr.io/linuxserver/chromium:latest" "3000" ;;
    2) uninstall_browser "chromium" ;;
    3) install_browser "firefox" "lscr.io/linuxserver/firefox:latest" "4000" ;;
    4) uninstall_browser "firefox" ;;
    5) print_browser_diagnostics ;;
    6) exit 0 ;;
    *) die "Invalid option: ${choice:-empty}" ;;
esac
