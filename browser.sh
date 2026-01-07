#!/bin/bash

# ==========================================================
# Project: Linux Browser Suite (Docker-based)
# Author: Mammad3861
# Description: Interactive script to install/uninstall 
#              web-based browsers (Chromium/Firefox)
# ==========================================================

# UI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' 


SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

# Check and Install Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker not found. Installing now...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
    fi
}

# Deploy Browser
install_browser() {
    local BROWSER=$1
    local IMAGE=$2
    local PORT=$3
    
    if docker ps -a | grep -q "$BROWSER"; then
        echo -e "${RED}Error: $BROWSER is already running.${NC}"
    else
        echo -e "${GREEN}--- Configuration for $BROWSER ---${NC}"
        read -p "Enter UI Username (default: admin): " USERNAME
        USERNAME=${USERNAME:-admin}
        read -sp "Enter UI Password: " PASSWORD
        echo -e "\n"

        check_docker

        docker run -d \
            --name=$BROWSER \
            --security-opt seccomp=unconfined \
            -e PUID=1000 \
            -e PGID=1000 \
            -e TZ=$SERVER_TZ \
            -e CUSTOM_USER=$USERNAME \
            -e PASSWORD=$PASSWORD \
            -p ${PORT}:3000 \
            -v "/root/${BROWSER}/config:/config" \
            --shm-size="1gb" \
            --restart unless-stopped \
            $IMAGE

        IP=$(curl -s ifconfig.me)
        echo -e "${GREEN}Deployment Successful!${NC}"
        echo -e "Access URL: http://${IP}:${PORT}"
        echo -e "Credentials: $USERNAME / [Your Password]"
    fi
}

# Remove Browser
uninstall_browser() {
    local BROWSER=$1
    if docker ps -a | grep -q "$BROWSER"; then
        echo -e "${RED}Removing $BROWSER...${NC}"
        docker stop $BROWSER && docker rm $BROWSER
        echo -e "${GREEN}Done.${NC}"
    else
        echo -e "Error: $BROWSER is not installed."
    fi
}

# Main Menu
clear
echo "=========================================="
echo "      LINUX BROWSER INSTALLER v1.0        "
echo "      Timezone: $SERVER_TZ                "
echo "=========================================="
echo "1) Install Chromium (Port 3000)"
echo "2) Uninstall Chromium"
echo "3) Install Firefox (Port 4000)"
echo "4) Uninstall Firefox"
echo "5) Exit"
echo "=========================================="
read -p "Select an option [1-5]: " choice

case $choice in
    1) install_browser "chromium" "lscr.io/linuxserver/chromium:latest" "3000" ;;
    2) uninstall_browser "chromium" ;;
    3) install_browser "firefox" "lscr.io/linuxserver/firefox:latest" "4000" ;;
    4) uninstall_browser "firefox" ;;
    5) exit ;;
    *) echo "Invalid input." ;;
esac
