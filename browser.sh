#!/bin/bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Author: Mammad3861
# Version: 1.0.7 - Browser Launch Fix
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
        sudo sh get-docker.sh && rm get-docker.sh
    fi
}

install_browser() {
    local BROWSER=$1
    local IMAGE=$2
    local PORT=$3
    local SSL_PORT=$((PORT + 1))
    
    if docker ps -a | grep -q "$BROWSER"; then
        echo -e "${RED}Error: $BROWSER is already running.${NC}"
    else
        echo -e "${CYAN}--- Configuration for $BROWSER ---${NC}"
        read -p "Enter UI Username (default: admin): " USERNAME
        USERNAME=${USERNAME:-admin}
        read -p "Enter UI Password: " PASSWORD
        echo -e "\n"

        check_docker

        echo -e "${YELLOW}Deploying $BROWSER... Please wait.${NC}"
        
        # Chromium requires specific flags to run in Docker environments
        local CHROME_STABILITY_FLAGS=""
        if [[ "$BROWSER" == "chromium" ]]; then
            CHROME_STABILITY_FLAGS="--no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage --disable-setuid-sandbox"
        fi

        docker run -d \
            --name=$BROWSER \
            --privileged \
            --ipc=host \
            --security-opt seccomp=unconfined \
            -e PUID=1000 -e PGID=1000 \
            -e TZ=$SERVER_TZ \
            -e CUSTOM_USER=$USERNAME \
            -e PASSWORD=$PASSWORD \
            -e CHROME_FLAGS="$CHROME_STABILITY_FLAGS" \
            -p ${PORT}:3000 \
            -p ${SSL_PORT}:3001 \
            -v "/root/${BROWSER}/config:/config" \
            --shm-size="2gb" \
            --restart unless-stopped \
            $IMAGE

        # Get IPv4 address
        IP=$(curl -4 -s ifconfig.me)
        
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
    docker stop $BROWSER && docker rm $BROWSER
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Main Menu
clear
echo -e "${CYAN}==========================================${NC}"
echo -e "       INSTANT LINUX BROWSER SUITE        "
echo -e "       Server TZ: ${YELLOW}$SERVER_TZ${NC}       "
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
