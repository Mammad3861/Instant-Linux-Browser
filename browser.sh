#!/usr/bin/env bash

# ==========================================================
# Project: Instant Linux Browser (Docker-based)
# Author: Mammad3861
# Version: 1.2.2 - Chromium compatibility and startup checks
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
CHROMIUM_FLAGS="${CHROMIUM_FLAGS:---no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox}"
CADDY_CONTAINER="instant-linux-browser-caddy"
CADDY_NETWORK="instant-linux-browser"
CADDY_IMAGE="caddy:2-alpine"
CADDY_MANAGED_LABEL="com.instant-linux-browser.managed=true"

info() { echo -e "${CYAN}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This action must be run with sudo or as root."
}

# Detect Timezone
SERVER_TZ=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

# Open the controlling terminal once so streamed scripts can still prompt.
TTY_FD=""
if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then
    :
fi

prompt_text() {
    local result_var="$1"
    local prompt="$2"
    local default_value="${3:-}"
    local value=""

    if [[ -n "$TTY_FD" ]]; then
        printf "%s" "$prompt" >&"$TTY_FD"
        if ! IFS= read -r value <&"$TTY_FD"; then
            die "Username input ended or was interrupted."
        fi
    else
        printf "%s" "$prompt"
        if ! IFS= read -r value; then
            die "Username input ended or was interrupted."
        fi
    fi

    printf -v "$result_var" '%s' "${value:-$default_value}"
}

prompt_secret() {
    local result_var="$1"
    local prompt="$2"
    local value=""

    if [[ -n "$TTY_FD" ]]; then
        printf "%s" "$prompt" >&"$TTY_FD"
        if ! IFS= read -r -s value <&"$TTY_FD"; then
            printf "\n" >&"$TTY_FD"
            die "Password input ended or was interrupted."
        fi
        printf "\n" >&"$TTY_FD"
    else
        printf "%s" "$prompt"
        if ! IFS= read -r -s value; then
            printf "\n"
            die "Password input ended or was interrupted."
        fi
        printf "\n"
    fi

    printf -v "$result_var" '%s' "$value"
}

prompt_access_mode() {
    local result_var="$1"
    local choice=""

    if [[ -n "$TTY_FD" ]]; then
        printf '%s\n' \
            "1) Server IP - HTTPS with a browser certificate warning" \
            "2) Automatic sslip.io hostname - trusted HTTPS without owning a domain" \
            "3) Custom domain - trusted HTTPS using your own DNS" >&"$TTY_FD"
        printf "Select access mode [1]: " >&"$TTY_FD"
        if ! IFS= read -r choice <&"$TTY_FD"; then
            die "Access mode input ended or was interrupted."
        fi
    else
        printf '%s\n' \
            "1) Server IP - HTTPS with a browser certificate warning" \
            "2) Automatic sslip.io hostname - trusted HTTPS without owning a domain" \
            "3) Custom domain - trusted HTTPS using your own DNS"
        printf "Select access mode [1]: "
        if ! IFS= read -r choice; then
            die "Access mode input ended or was interrupted."
        fi
    fi

    case "$choice" in
        ""|1)
            printf -v "$result_var" '%s' "ip"
            ;;
        2)
            printf -v "$result_var" '%s' "sslip"
            ;;
        3)
            printf -v "$result_var" '%s' "domain"
            ;;
        *)
            die "Invalid access mode selection: $choice. Use 1, 2, or 3."
            ;;
    esac
}

prompt_custom_domain() {
    local result_var="$1"
    local value=""

    if [[ -n "$TTY_FD" ]]; then
        printf "Custom domain for automatic HTTPS: " >&"$TTY_FD"
        if ! IFS= read -r value <&"$TTY_FD"; then
            die "Domain input ended or was interrupted."
        fi
    else
        printf "Custom domain for automatic HTTPS: "
        if ! IFS= read -r value; then
            die "Domain input ended or was interrupted."
        fi
    fi

    printf -v "$result_var" '%s' "$value"
}

validate_domain() {
    local domain="$1"
    local label
    local -a labels

    [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
    [[ ! "$domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    case "$domain" in
        localhost|*.localhost|*.local|*.internal|*.home.arpa)
            return 1
            ;;
    esac

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

validate_public_ipv4() {
    local ip="$1"
    local first second third fourth octet

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r first second third fourth <<< "$ip"

    for octet in "$first" "$second" "$third" "$fourth"; do
        [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
        ((10#$octet <= 255)) || return 1
    done

    ((first != 0 && first != 10 && first != 127)) || return 1
    ! ((first == 100 && second >= 64 && second <= 127)) || return 1
    ! ((first == 169 && second == 254)) || return 1
    ! ((first == 172 && second >= 16 && second <= 31)) || return 1
    ! ((first == 192 && second == 0 && third == 0)) || return 1
    ! ((first == 192 && second == 0 && third == 2)) || return 1
    ! ((first == 192 && second == 88 && third == 99)) || return 1
    ! ((first == 192 && second == 168)) || return 1
    ! ((first == 198 && (second == 18 || second == 19))) || return 1
    ! ((first == 198 && second == 51 && third == 100)) || return 1
    ! ((first == 203 && second == 0 && third == 113)) || return 1
    ((first < 224)) || return 1
}

detect_public_ipv4() {
    local result_var="$1"
    local detected_ipv4=""

    command -v curl >/dev/null 2>&1 || die "Automatic sslip.io mode requires curl to detect the server's public IPv4 address."
    if ! detected_ipv4="$(curl -4 -fsS --connect-timeout 3 --max-time 5 https://ifconfig.me/ip 2>/dev/null)"; then
        die "Automatic sslip.io mode could not detect the server's public IPv4 address within 5 seconds."
    fi
    validate_public_ipv4 "$detected_ipv4" || die "Automatic sslip.io mode requires a publicly routable IPv4 address, but detection returned a missing, malformed, or non-public value."

    printf -v "$result_var" '%s' "$detected_ipv4"
}

resolve_access_mode() {
    local result_var="$1"
    local resolved_mode=""

    if [[ -n "${ILB_ACCESS_MODE+x}" ]]; then
        resolved_mode="$ILB_ACCESS_MODE"
    elif [[ -n "${ILB_DOMAIN:-}" ]]; then
        resolved_mode="domain"
    elif [[ -n "${ILB_DOMAIN+x}" ]]; then
        resolved_mode="ip"
    elif [[ -n "$TTY_FD" ]]; then
        prompt_access_mode resolved_mode
    else
        resolved_mode="ip"
    fi

    case "$resolved_mode" in
        ip|sslip|domain)
            ;;
        *)
            die "Invalid ILB_ACCESS_MODE value: ${resolved_mode:-empty}. Use ip, sslip, or domain exactly as shown."
            ;;
    esac

    if [[ "$resolved_mode" != "domain" && -n "${ILB_DOMAIN:-}" ]]; then
        die "ILB_DOMAIN cannot be used with ILB_ACCESS_MODE=$resolved_mode. Use ILB_ACCESS_MODE=domain or remove ILB_DOMAIN."
    fi

    printf -v "$result_var" '%s' "$resolved_mode"
}

resolve_access_hostname() {
    local browser="$1"
    local access_mode="$2"
    local result_var="$3"
    local resolved_hostname=""
    local public_ipv4=""

    case "$access_mode" in
        ip)
            ;;
        sslip)
            detect_public_ipv4 public_ipv4
            resolved_hostname="${browser}.${public_ipv4//./-}.sslip.io"
            ;;
        domain)
            if [[ -n "${ILB_DOMAIN:-}" ]]; then
                resolved_hostname="$ILB_DOMAIN"
            elif [[ -n "$TTY_FD" ]]; then
                prompt_custom_domain resolved_hostname
            else
                die "ILB_ACCESS_MODE=domain requires a non-empty ILB_DOMAIN when no controlling terminal is available."
            fi

            resolved_hostname="${resolved_hostname,,}"
            validate_domain "$resolved_hostname" || die "Invalid ILB_DOMAIN value. Use a fully qualified hostname without a scheme, path, port, wildcard, or whitespace."
            ;;
    esac

    printf -v "$result_var" '%s' "$resolved_hostname"
}

validate_acme_email() {
    local email="$1"
    [[ -z "$email" || "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]
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

# Resolve PUID/PGID (prefer the sudo user; fallback to the conventional host user)
resolve_puid_pgid() {
    local puid pgid
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        puid=$(id -u "$SUDO_USER" 2>/dev/null)
        pgid=$(id -g "$SUDO_USER" 2>/dev/null)
    fi

    puid="${puid:-1000}"
    pgid="${pgid:-1000}"

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

run_docker_diagnostics() {
    timeout 5 docker "$@"
}

chromium_process_running() {
    docker exec "$1" sh -c 'ps -eo comm=,args= 2>/dev/null | grep -Eq "[c]hromium|[c]hrome"' >/dev/null 2>&1
}

print_recent_logs() {
    local container="$1"
    local secret="${2:-}"
    local line

    if [[ -z "$secret" ]]; then
        docker logs --tail 80 "$container" 2>&1 || true
        return
    fi

    while IFS= read -r line; do
        printf '%s\n' "${line//"$secret"/[REDACTED]}"
    done < <(docker logs --tail 80 "$container" 2>&1 || true)
}

print_chromium_failure() {
    local reason="$1"
    local secret="${2:-}"
    echo -e "${RED}Chromium startup check failed: $reason${NC}" >&2
    echo "Recent container logs:" >&2
    print_recent_logs chromium "$secret"
    echo "Debug: sudo docker ps -a --filter name=chromium" >&2
    echo "Debug: sudo docker exec chromium ps -eo pid,comm,args" >&2
}

verify_chromium_startup() {
    local secret="${1:-}"
    local attempt

    for ((attempt = 1; attempt <= 30; attempt++)); do
        if ! container_running chromium; then
            print_chromium_failure "the Docker container exited" "$secret"
            return 1
        fi

        if chromium_process_running chromium; then
            info "Chromium process detected."
            return 0
        fi

        sleep 1
    done

    print_chromium_failure "the container is running but no Chromium process was found" "$secret"
    return 1
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

caddy_route_file() {
    printf '%s/proxy/sites/%s.caddy' "$CONFIG_BASE" "$1"
}

container_is_project_managed() {
    [[ "$(docker inspect -f '{{ index .Config.Labels "com.instant-linux-browser.managed" }}' "$1" 2>/dev/null || true)" == "true" ]]
}

network_exists() {
    docker network inspect "$CADDY_NETWORK" >/dev/null 2>&1
}

network_is_project_managed() {
    [[ "$(docker network inspect -f '{{ index .Labels "com.instant-linux-browser.managed" }}' "$CADDY_NETWORK" 2>/dev/null || true)" == "true" ]]
}

ensure_proxy_directories() {
    mkdir -p \
        "${CONFIG_BASE}/proxy/sites" \
        "${CONFIG_BASE}/proxy/data" \
        "${CONFIG_BASE}/proxy/config" || die "Failed to create Caddy configuration directories under ${CONFIG_BASE}/proxy."
    chmod 700 \
        "${CONFIG_BASE}/proxy/data" \
        "${CONFIG_BASE}/proxy/config" || die "Failed to protect Caddy data directories under ${CONFIG_BASE}/proxy."
}

ensure_proxy_network() {
    if network_exists; then
        network_is_project_managed || die "A Docker network named $CADDY_NETWORK exists but is not managed by Instant Linux Browser."
        return 0
    fi

    docker network create --label "$CADDY_MANAGED_LABEL" "$CADDY_NETWORK" >/dev/null || die "Failed to create Docker network $CADDY_NETWORK."
}

write_atomic_file() {
    local path="$1"
    local content="$2"
    local temporary="${path}.tmp.$$"

    if ! printf '%s' "$content" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi

    if ! mv -f -- "$temporary" "$path"; then
        rm -f -- "$temporary"
        return 1
    fi
}

write_caddy_main_config() {
    local email="$1"
    local content

    if [[ -n "$email" ]]; then
        content=$'{\n\temail '"$email"$'\n}\n\nimport /etc/caddy/sites/*.caddy\n'
    else
        content=$'import /etc/caddy/sites/*.caddy\n'
    fi

    write_atomic_file "${CONFIG_BASE}/proxy/Caddyfile" "$content"
}

write_caddy_route() {
    local browser="$1"
    local domain="$2"
    local route_file
    local content

    route_file="$(caddy_route_file "$browser")"
    content="${domain} {"$'\n\treverse_proxy '"${browser}:3000"$'\n}\n'
    write_atomic_file "$route_file" "$content"
}

configured_route_domain() {
    local browser="$1"
    local route_file
    local first_line=""

    route_file="$(caddy_route_file "$browser")"
    [[ -f "$route_file" ]] || return 1
    IFS= read -r first_line < "$route_file" || true
    printf '%s\n' "${first_line%%[[:space:]]*}"
}

assert_domain_available() {
    local browser="$1"
    local domain="$2"
    local other_browser other_domain

    for other_browser in chromium firefox; do
        [[ "$other_browser" == "$browser" ]] && continue
        other_domain="$(configured_route_domain "$other_browser" 2>/dev/null || true)"
        if [[ "$other_domain" == "$domain" ]]; then
            die "Domain $domain is already assigned to $other_browser."
        fi
    done
}

validate_caddy_config() {
    if container_exists "$CADDY_CONTAINER" && container_running "$CADDY_CONTAINER"; then
        docker exec -w /etc/caddy "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    else
        docker run --rm \
            -v "${CONFIG_BASE}/proxy:/etc/caddy:ro" \
            "$CADDY_IMAGE" \
            caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    fi
}

reload_caddy() {
    docker exec -w /etc/caddy "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}

wait_for_caddy_startup() {
    local attempt

    for attempt in {1..5}; do
        container_running "$CADDY_CONTAINER" || return 1
        [[ "$attempt" -eq 5 ]] && return 0
        sleep 1
    done
}

print_caddy_failure() {
    local reason="$1"

    echo -e "${RED}Caddy setup failed: $reason${NC}" >&2
    if container_exists "$CADDY_CONTAINER"; then
        echo "Recent Caddy logs:" >&2
        docker logs --tail 80 "$CADDY_CONTAINER" 2>&1 || true
    fi
    echo "Debug: sudo docker logs $CADDY_CONTAINER" >&2
    echo "Debug: sudo docker exec -w /etc/caddy $CADDY_CONTAINER caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" >&2
}

start_or_reload_caddy() {
    if container_exists "$CADDY_CONTAINER"; then
        container_is_project_managed "$CADDY_CONTAINER" || return 1
        if ! container_running "$CADDY_CONTAINER"; then
            docker start "$CADDY_CONTAINER" >/dev/null || return 1
            container_running "$CADDY_CONTAINER" || return 1
        fi
        reload_caddy
        return
    fi

    if ! docker run -d \
        --name="$CADDY_CONTAINER" \
        --label "$CADDY_MANAGED_LABEL" \
        --network="$CADDY_NETWORK" \
        -p "80:80" \
        -p "443:443" \
        -v "${CONFIG_BASE}/proxy:/etc/caddy:ro" \
        -v "${CONFIG_BASE}/proxy/data:/data" \
        -v "${CONFIG_BASE}/proxy/config:/config" \
        --restart unless-stopped \
        "$CADDY_IMAGE"; then
        return 1
    fi

    wait_for_caddy_startup
}

prepare_domain_proxy() {
    ensure_proxy_directories

    if container_exists "$CADDY_CONTAINER"; then
        container_is_project_managed "$CADDY_CONTAINER" || die "A container named $CADDY_CONTAINER exists but is not managed by Instant Linux Browser."
    else
        check_port_available 80
        check_port_available 443
        info "Pulling $CADDY_IMAGE..."
        docker pull "$CADDY_IMAGE" || die "Failed to pull $CADDY_IMAGE."
    fi

    ensure_proxy_network
}

restore_config_file() {
    local path="$1"
    local backup="$2"

    if [[ -n "$backup" ]]; then
        mv -f -- "$backup" "$path"
    else
        rm -f -- "$path"
    fi
}

configure_caddy_route() {
    local browser="$1"
    local domain="$2"
    local email="$3"
    local main_file="${CONFIG_BASE}/proxy/Caddyfile"
    local route_file
    local main_backup=""
    local route_backup=""
    local caddy_preexisting=0

    route_file="$(caddy_route_file "$browser")"
    assert_domain_available "$browser" "$domain"

    if [[ -f "$main_file" ]]; then
        main_backup="${main_file}.backup.$$"
        cp -p -- "$main_file" "$main_backup" || return 1
    fi
    if [[ -f "$route_file" ]]; then
        route_backup="${route_file}.backup.$$"
        cp -p -- "$route_file" "$route_backup" || {
            [[ -z "$main_backup" ]] || rm -f -- "$main_backup"
            return 1
        }
    fi
    if container_exists "$CADDY_CONTAINER"; then
        caddy_preexisting=1
    fi

    if [[ ! -f "$main_file" || -n "$email" ]]; then
        if ! write_caddy_main_config "$email"; then
            restore_config_file "$main_file" "$main_backup"
            restore_config_file "$route_file" "$route_backup"
            return 1
        fi
    fi
    if ! write_caddy_route "$browser" "$domain"; then
        restore_config_file "$main_file" "$main_backup"
        restore_config_file "$route_file" "$route_backup"
        return 1
    fi

    if ! validate_caddy_config; then
        restore_config_file "$main_file" "$main_backup"
        restore_config_file "$route_file" "$route_backup"
        print_caddy_failure "configuration validation failed"
        return 1
    fi

    if ! start_or_reload_caddy; then
        restore_config_file "$main_file" "$main_backup"
        restore_config_file "$route_file" "$route_backup"
        print_caddy_failure "container start or reload failed"
        if [[ "$caddy_preexisting" -eq 1 ]] && container_running "$CADDY_CONTAINER"; then
            reload_caddy >/dev/null 2>&1 || true
        elif container_exists "$CADDY_CONTAINER" && container_is_project_managed "$CADDY_CONTAINER"; then
            docker rm -f "$CADDY_CONTAINER" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    [[ -z "$main_backup" ]] || rm -f -- "$main_backup"
    [[ -z "$route_backup" ]] || rm -f -- "$route_backup"
}

proxy_routes_remain() {
    compgen -G "${CONFIG_BASE}/proxy/sites/*.caddy" >/dev/null
}

cleanup_proxy_network() {
    container_exists chromium && return 0
    container_exists firefox && return 0
    container_exists "$CADDY_CONTAINER" && return 0
    network_exists || return 0
    network_is_project_managed || return 0
    docker network rm "$CADDY_NETWORK" >/dev/null 2>&1 || true
}

remove_caddy_route() {
    local browser="$1"
    local route_file
    local backup

    route_file="$(caddy_route_file "$browser")"
    [[ -f "$route_file" ]] || return 0
    backup="${route_file}.removed.$$"
    mv -- "$route_file" "$backup" || return 1

    if proxy_routes_remain; then
        if container_exists "$CADDY_CONTAINER"; then
            if ! container_is_project_managed "$CADDY_CONTAINER"; then
                mv -f -- "$backup" "$route_file"
                return 1
            fi
            if ! validate_caddy_config || ! start_or_reload_caddy; then
                mv -f -- "$backup" "$route_file"
                reload_caddy >/dev/null 2>&1 || true
                return 1
            fi
        fi
    elif container_exists "$CADDY_CONTAINER"; then
        if ! container_is_project_managed "$CADDY_CONTAINER"; then
            mv -f -- "$backup" "$route_file"
            return 1
        fi
        if ! docker stop "$CADDY_CONTAINER" >/dev/null || ! docker rm "$CADDY_CONTAINER" >/dev/null; then
            mv -f -- "$backup" "$route_file"
            docker start "$CADDY_CONTAINER" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    rm -f -- "$backup"
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
    local access_mode=""
    local access_hostname=""
    local acme_email="${ILB_ACME_EMAIL:-}"

    require_root
    show_arch_info

    echo -e "${CYAN}--- Configuration for $browser ---${NC}"
    local username=""
    local password=""

    if [[ -n "${ILB_USERNAME+x}" ]]; then
        username="$ILB_USERNAME"
    else
        prompt_text username "Enter UI Username (default: admin): " "admin"
    fi
    username="${username:-admin}"

    if [[ -n "${ILB_PASSWORD+x}" ]]; then
        password="$ILB_PASSWORD"
    else
        prompt_secret password "Enter UI Password: "
    fi

    resolve_access_mode access_mode
    resolve_access_hostname "$browser" "$access_mode" access_hostname

    if [[ -z "$password" ]]; then
        warn "Empty UI password selected. Use a firewall or reverse proxy allow-list if this server is reachable from the internet."
    fi

    if [[ "$access_mode" != "ip" ]]; then
        validate_acme_email "$acme_email" || die "Invalid ILB_ACME_EMAIL value."
        assert_domain_available "$browser" "$access_hostname"
    fi

    ensure_docker_ready
    if container_exists "$browser"; then
        die "$browser container already exists. Use the uninstall option first if you want to recreate it."
    fi

    check_port_available "$port"
    check_port_available "$ssl_port"

    if [[ "$access_mode" != "ip" ]]; then
        prepare_domain_proxy
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

    local browser_env=()
    local browser_network=()
    local browser_ports=(-p "${port}:3000" -p "${ssl_port}:3001")

    if [[ "$browser" == "chromium" ]]; then
        browser_env+=(-e "PIXELFLUX_WAYLAND=false" -e "CHROME_CLI=$CHROMIUM_FLAGS" -e "CHROME_FLAGS=$CHROMIUM_FLAGS")
        info "Applying Chromium flags through CHROME_CLI and CHROME_FLAGS: $CHROMIUM_FLAGS"
    fi

    if [[ "$access_mode" != "ip" ]]; then
        browser_network=(--network="$CADDY_NETWORK")
        browser_ports=(-p "127.0.0.1:${port}:3000" -p "127.0.0.1:${ssl_port}:3001")
    fi

    info "Deploying $browser... Please wait."
    if ! docker run -d \
        --name="$browser" \
        -e "PUID=$puid" \
        -e "PGID=$pgid" \
        -e "TZ=$SERVER_TZ" \
        -e "CUSTOM_USER=$username" \
        -e "PASSWORD=$password" \
        "${browser_env[@]}" \
        "${browser_network[@]}" \
        "${browser_ports[@]}" \
        -v "${config_dir}:/config" \
        --shm-size="2gb" \
        --restart unless-stopped \
        "$image"; then
        echo "Docker failed to start $browser."
        if container_exists "$browser"; then
            echo "Recent logs:"
            print_recent_logs "$browser" "$password"
        fi
        die "Check ports, image availability, Docker permissions, and the logs above if present."
    fi

    if ! container_running "$browser"; then
        echo -e "${RED}$browser did not start successfully.${NC}"
        echo "Recent logs:"
        print_recent_logs "$browser" "$password"
        die "Container exited. Check the logs above."
    fi

    if [[ "$browser" == "chromium" ]]; then
        verify_chromium_startup "$password" || die "Chromium is not ready. Check the logs and debug commands above."
    fi

    if [[ "$access_mode" != "ip" ]] && ! configure_caddy_route "$browser" "$access_hostname" "$acme_email"; then
        docker stop "$browser" >/dev/null 2>&1 || true
        docker rm "$browser" >/dev/null 2>&1 || true
        cleanup_proxy_network
        die "Trusted HTTPS proxy setup failed. The new $browser container was removed; persistent browser and Caddy data were kept."
    fi

    local ip

    success "================================================"
    success "Deployment Successful!"
    if [[ "$access_mode" != "ip" ]]; then
        echo -e "Browser URL (HTTPS): ${CYAN}https://${access_hostname}${NC}"
    else
        ip=$(detect_ip)
        echo -e "Browser URL (HTTPS): ${CYAN}https://${ip}:${ssl_port}${NC}"
        echo -e "HTTP (proxy-only) : ${CYAN}http://${ip}:${port}${NC}"
    fi
    echo -e "Credentials       : ${YELLOW}configured for $username${NC}"
    if [[ "$access_mode" == "domain" ]]; then
        echo "Caddy manages certificate issuance and renewal for this domain."
        warn "DNS must point to this server, and inbound ports 80 and 443 must be reachable."
    elif [[ "$access_mode" == "sslip" ]]; then
        echo "Caddy manages certificate issuance and renewal for this sslip.io hostname."
        warn "sslip.io is a third-party DNS service, and this hostname exposes the server IP."
        warn "Inbound ports 80 and 443 must be publicly reachable."
        warn "Public CA or sslip.io rate limits may prevent certificate issuance."
        warn "Use a custom domain for stable long-term production deployments."
    else
        echo -e "${YELLOW}Note: This mode uses a self-signed certificate, so your browser may show a certificate warning.${NC}"
    fi
    success "================================================"
}

uninstall_browser() {
    local browser="$1"
    local had_domain_route=0

    [[ -f "$(caddy_route_file "$browser")" ]] && had_domain_route=1
    info "Removing $browser..."
    require_root
    ensure_docker_ready
    remove_caddy_route "$browser" || die "Failed to remove the $browser domain route safely. Check Caddy logs and configuration."
    if container_exists "$browser"; then
        docker stop "$browser" >/dev/null 2>&1 || true
        if ! docker rm "$browser" >/dev/null 2>&1 && container_exists "$browser"; then
            die "Failed to remove the $browser container."
        fi
    fi
    cleanup_proxy_network
    if [[ "$had_domain_route" -eq 1 ]]; then
        success "Cleanup complete. Persistent browser and Caddy data were kept under ${CONFIG_BASE}."
    else
        success "Cleanup complete. Persistent config was kept at ${CONFIG_BASE}/${browser}/config."
    fi
}

show_diagnostics() {
    local status

    show_arch_info
    echo -e "${CYAN}Config base:${NC} ${CONFIG_BASE}"
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker: not installed"
        return 0
    fi

    if ! command -v timeout >/dev/null 2>&1; then
        echo "Docker: diagnostics timeout command is unavailable"
        return 0
    fi

    echo "Checking Docker daemon (up to 5 seconds)..."
    if run_docker_diagnostics info >/dev/null 2>&1; then
        :
    else
        status=$?
        if [[ "$status" -eq 124 ]]; then
            echo "Docker: daemon check timed out after 5 seconds"
        else
            echo "Docker: installed but not reachable"
        fi
        return 0
    fi

    echo "Docker: reachable"
    echo -e "${CYAN}--- Containers ---${NC}"
    if run_docker_diagnostics ps -a --filter "name=chromium" --filter "name=firefox" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'; then
        :
    else
        status=$?
        if [[ "$status" -eq 124 ]]; then
            echo "Docker: container query timed out after 5 seconds"
        else
            echo "Docker: container query failed"
        fi
    fi
}

show_menu() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN}     Instant Linux Browser Installer${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "1) Install Chromium (HTTPS 3001; HTTP 3000 proxy-only)"
    echo -e "2) Uninstall Chromium"
    echo -e "3) Install Firefox (HTTPS 4001; HTTP 4000 proxy-only)"
    echo -e "4) Uninstall Firefox"
    echo -e "5) Diagnostics"
    echo -e "6) Exit"
    echo -e "${CYAN}==========================================${NC}"
}

read_menu_choice() {
    local choice=""
    if [[ -n "$TTY_FD" ]]; then
        printf "Select an option [1-6]: " >&"$TTY_FD"
        read -r choice <&"$TTY_FD"
    else
        die "No action and no controlling terminal. Use ILB_ACTION=install-chromium or download the script first."
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
            show_diagnostics
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

    if [[ -z "$TTY_FD" ]]; then
        die "No action and no controlling terminal. Use ILB_ACTION=install-chromium or download the script first."
    fi

    show_menu
    action=$(read_menu_choice)
    run_action "$action"
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
