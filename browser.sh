#!/bin/bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Author: Mammad3861
# Version: 1.0.3
# Description: Professional automated deployment for 
#              Chromium and Firefox Web-GUI containers.
# ==========================================================

# UI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' 

# Root Privilege Check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root or with sudo.${NC}"
   exit 1
fi


SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

# Check and Install Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker not found. Installing latest version...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
        echo -e "${GREEN}Docker installed successfully.${NC}"
    fi
}

# Deploy Browser
install_browser() {
    local BROWSER=$1
    local IMAGE=$2
    local PORT=$3
    
    if docker ps -a | grep -q "$BROWSER"; then
        echo -e "${RED}Error: $BROWSER is already deployed on this server.${NC}"
    else
        echo -e "${CYAN}--- Configuration for $BROWSER ---${NC}"
        read -p "Enter UI Username (default: admin): " USERNAME
        USERNAME=${USERNAME:-admin}
        
        # Masked password input
        read -sp "Enter UI Password: " PASSWORD
        echo -e "\n"

        check_docker

        echo -e "${YELLOW}Pulling image and starting container...${NC}"
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

        # Get Public IP
        IP=$(curl -s ifconfig.me)
        
        echo -e "${GREEN}================================================${NC}"
        echo -e "${GREEN}Deployment Successful!${NC}"
        echo -e "Access URL: ${CYAN}http://${IP}:${PORT}${NC}"
        echo -e "Credentials: ${YELLOW}$USERNAME / [Your Password]${NC}"
        echo -e "${GREEN}================================================${NC}"
    fi
}

# Remove Browser
uninstall_browser() {
    local BROWSER=$1
    if docker ps -a | grep -q "$BROWSER"; then
        echo -e "${YELLOW}Stopping and removing $BROWSER...${NC}"
        docker stop $BROWSER && docker rm $BROWSER
        echo -e "${GREEN}$BROWSER has been uninstalled.${NC}"
    else
        echo -e "${RED}Error: $BROWSER is not found on this system.${NC}"
    fi
}

# --- Main Menu ---
clear
echo -e "${CYAN}==========================================${NC}"
echo -e "       INSTANT LINUX BROWSER SUITE        "
echo -e "       Server TZ: ${YELLOW}$SERVER_TZ${NC}       "
echo -e "${CYAN}==========================================${NC}"
echo -e "1) ${GREEN}Install Chromium${NC} (Port 3000)"
echo -e "2) ${RED}Uninstall Chromium${NC}"
echo -e "3) ${GREEN}Install Firefox${NC} (Port 4000)"
echo -e "4) ${RED}Uninstall Firefox${NC}"
echo -e "5) Exit"
echo -e "${CYAN}==========================================${NC}"
read -p "Select an option [1-5]: " choice

case $choice in
    1) install_browser "chromium" "lscr.io/linuxserver/chromium:latest" "3000" ;;
    2) uninstall_browser "chromium" ;;
    3) install_browser "firefox" "lscr.io/linuxserver/firefox:latest" "4000" ;;
    4) uninstall_browser "firefox" ;;
    5) echo "Exiting..."; exit ;;
    *) echo -e "${RED}Invalid input. Please try again.${NC}" ;;
esac
