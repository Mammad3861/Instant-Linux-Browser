#!/bin/bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Author: Mammad3861
# Version: 1.1.0 - Permission + Security + UX Fixes
# Description: Automated deployment for web-based browsers.
# ==========================================================

# UI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run with sudo or as root.${NC}"
   exit 1
fi

# Detect Timezone
SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker not found. Installing...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh && rm -f get-docker.sh
    fi
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

# Safer config base dir (not under /root)
CONFIG_BASE="/opt/instant-linux-browser"

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

install_browser() {
    local BROWSER=$1
    local IMAGE=$2
    local PORT=$3
    local SSL_PORT=$((PORT + 1))

    if container_exists "$BROWSER"; then
        echo -e "${RED}Error: $BROWSER is already running.${NC}"
    else
        echo -e "${CYAN}--- Configuration for $BROWSER ---${NC}"
        read -p "Enter UI Username (default: admin): " USERNAME
        USERNAME=${USERNAME:-admin}
        read -s -p "Enter UI Password: " PASSWORD
        echo -e "\n"

        check_docker

        echo -e "${YELLOW}Deploying $BROWSER... Please wait.${NC}"

        # Chromium requires specific flags to run in Docker environments
        local CHROME_STABILITY_FLAGS=""
        local EXTRA_CAPS=()
        local EXTRA_SECURITY=()

        if [[ "$BROWSER" == "chromium" ]]; then
            CHROME_STABILITY_FLAGS="--no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage --disable-setuid-sandbox"
            # Safer alternative to --privileged for chromium container needs:
            EXTRA_CAPS+=(--cap-add=SYS_ADMIN)
            EXTRA_SECURITY+=(--security-opt seccomp=unconfined)
        fi

        local PUID_PGID
        PUID_PGID="$(resolve_puid_pgid)"
        local PUID="${PUID_PGID%%:*}"
        local PGID="${PUID_PGID##*:}"

        # Prepare config directory with correct permissions
        local CONFIG_DIR="${CONFIG_BASE}/${BROWSER}/config"
        mkdir -p "$CONFIG_DIR"
        chown -R "${PUID}:${PGID}" "${CONFIG_BASE}/${BROWSER}" 2>/dev/null || true

        docker run -d \
            --name=$BROWSER \
            "${EXTRA_CAPS[@]}" \
            "${EXTRA_SECURITY[@]}" \
            -e PUID=$PUID -e PGID=$PGID \
            -e TZ=$SERVER_TZ \
            -e CUSTOM_USER=$USERNAME \
            -e PASSWORD=$PASSWORD \
            -e CHROME_FLAGS="$CHROME_STABILITY_FLAGS" \
            -p ${PORT}:3000 \
            -p ${SSL_PORT}:3001 \
            -v "${CONFIG_DIR}:/config" \
            --shm-size="2gb" \
            --restart unless-stopped \
            $IMAGE

        # Get IPv4 address
        IP=$(detect_ip)

        echo -e "${GREEN}================================================${NC}"
        echo -e "${GREEN}Deployment Successful!${NC}"
        echo -e "Access URL (HTTP) : ${CYAN}http://${IP}:${PORT}${NC}"
        echo -e "Access URL (HTTPS): ${CYAN}https://${IP}:${SSL_PORT}${NC}"
        echo -e "Credentials       : ${YELLOW}$USERNAME / $PASSWORD${NC}"
        echo -e "${YELLOW}Note: Accept the SSL warning in your browser.${NC}"
        echo -e "${GREEN}================================================${NC}"
    fi
}

uninstall_browser() {
    local BROWSER=$1
    echo -e "${YELLOW}Removing $BROWSER...${NC}"
    docker stop "$BROWSER" >/dev/null 2>&1 || true
    docker rm "$BROWSER" >/dev/null 2>&1 || true
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Display Menu
echo -e "${CYAN}==========================================${NC}"
echo -e "${GREEN}     Instant Linux Browser Installer${NC}"
echo -e "${CYAN}==========================================${NC}"
echo -e "1) Install Chromium (Port 3000)"
echo -e "2) Uninstall Chromium"
echo -e "3) Install Firefox (Port 4000)"
echo -e "4) Uninstall Firefox"
echo -e "5) Exit"
echo -e "${CYAN}==========================================${NC}"
read -p "Select an option [1-5]: " choice

case $choice in
    1) install_browser "chromium" "lscr.io/linuxserver/chromium:latest" "3000" ;;
    2) uninstall_browser "chromium" ;;
    3) install_browser "firefox" "lscr.io/linuxserver/firefox:latest" "4000" ;;
    4) uninstall_browser "firefox" ;;
    5) exit ;;
esac
