#!/bin/bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Version: 1.0.6 - Stability Update
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Use sudo!${NC}"
   exit 1
fi

SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Installing Docker...${NC}"
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
        read -p "Enter Username (default: admin): " USERNAME
        USERNAME=${USERNAME:-admin}
        read -p "Enter Password: " PASSWORD
        echo -e "\n"

        check_docker

        echo -e "${YELLOW}Deploying $BROWSER... Please wait.${NC}"
        
        # حذف تنظیمات قبلی برای اطمینان از سلامت فایل‌ها
        rm -rf "/root/${BROWSER}/config"

        docker run -d \
            --name=$BROWSER \
            --privileged \
            --ipc=host \
            --security-opt seccomp=unconfined \
            -e PUID=1000 -e PGID=1000 \
            -e TZ=$SERVER_TZ \
            -e CUSTOM_USER=$USERNAME \
            -e PASSWORD=$PASSWORD \
            -e CHROME_FLAGS="--no-sandbox --disable-dev-shm-usage" \
            -p ${PORT}:3000 \
            -p ${SSL_PORT}:3001 \
            -v "/root/${BROWSER}/config:/config" \
            --shm-size="2gb" \
            --restart unless-stopped \
            $IMAGE

        IP=$(curl -4 -s ifconfig.me)
        
        echo -e "${GREEN}================================================${NC}"
        echo -e "Deployment Successful!"
        echo -e "Access URL (HTTPS): ${CYAN}https://${IP}:${SSL_PORT}${NC}"
        echo -e "Credentials       : ${YELLOW}$USERNAME / $PASSWORD${NC}"
        echo -e "${YELLOW}Wait 10 seconds, then refresh your browser.${NC}"
        echo -e "${GREEN}================================================${NC}"
    fi
}

uninstall_browser() {
    local BROWSER=$1
    docker stop $BROWSER && docker rm $BROWSER
    rm -rf "/root/${BROWSER}"
    echo -e "${GREEN}$BROWSER removed.${NC}"
}

clear
echo -e "${CYAN}==========================================${NC}"
echo -e "       INSTANT LINUX BROWSER SUITE        "
echo -e "${CYAN}==========================================${NC}"
echo -e "1) Install Chromium"
echo -e "2) Uninstall Chromium"
echo -e "3) Install Firefox"
echo -e "4) Uninstall Firefox"
echo -e "5) Exit"
echo -e "${CYAN}==========================================${NC}"
read -p "Select [1-5]: " choice

case $choice in
    1) install_browser "chromium" "lscr.io/linuxserver/chromium:latest" "3000" ;;
    2) uninstall_browser "chromium" ;;
    3) install_browser "firefox" "lscr.io/linuxserver/firefox:latest" "4000" ;;
    4) uninstall_browser "firefox" ;;
    *) exit ;;
esac
