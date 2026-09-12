#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/browser.sh"
TEMP_DIR="$(mktemp -d)"
MOCK_BIN="$TEMP_DIR/bin"
MOCK_LOG="$TEMP_DIR/docker.log"
MOCK_CURL_LOG="$TEMP_DIR/curl.log"
export MOCK_LOG MOCK_CURL_LOG

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local expected="$1"
    local file="$2"
    grep -Fq -- "$expected" "$file" || fail "Expected '$expected' in $file"
}

assert_not_contains() {
    local unexpected="$1"
    local file="$2"
    if grep -Fq -- "$unexpected" "$file"; then
        fail "Did not expect '$unexpected' in $file"
    fi
}

argument_index() {
    local argument="$1"
    awk -F '\t' -v argument="$argument" '{ for (field_index = 1; field_index <= NF; field_index++) if ($field_index == argument) { print field_index; exit } }' "$RUN_RECORD"
}

assert_environment_before_image() {
    local argument="$1"
    local argument_index_value
    local environment_flag_index

    argument_index_value="$(argument_index "$argument")"
    environment_flag_index=$((argument_index_value - 1))

    [[ -n "$argument_index_value" && "$argument_index_value" -lt "$IMAGE_INDEX" ]] || fail "$argument must occur before the image"
    [[ "$(awk -F '\t' -v field="$environment_flag_index" '{ print $field }' "$RUN_RECORD")" == "-e" ]] || fail "$argument must be preceded by -e"
}

record_run_with_argument() {
    local argument="$1"
    local output="$2"

    awk -F '\t' -v argument="$argument" '$2 == "run" { for (field_index = 3; field_index <= NF; field_index++) if ($field_index == argument) { print; found = 1; exit } } END { exit !found }' "$MOCK_LOG" > "$output"
}

mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -eu

{
    printf 'docker'
    for argument in "$@"; do
        if [[ "$argument" == PASSWORD=* ]]; then
            printf '\tPASSWORD=[REDACTED]'
        else
            printf '\t%s' "$argument"
        fi
    done
    printf '\n'
} >> "$MOCK_LOG"

case "${1:-}" in
    info|pull|stop|start)
        exit 0
        ;;
    run)
        if [[ "${MOCK_TRACK_CADDY:-0}" == "1" && "$*" == *'--name=instant-linux-browser-caddy'* ]]; then
            : > "${MOCK_CADDY_STATE:?}"
        fi
        exit 0
        ;;
    rm)
        if [[ "${MOCK_TRACK_CADDY:-0}" == "1" && "$*" == *'instant-linux-browser-caddy'* ]]; then
            rm -f -- "${MOCK_CADDY_STATE:?}"
        fi
        exit 0
        ;;
    ps)
        if [[ "$*" == *'{{.Names}}'* && -n "${MOCK_EXISTING_CONTAINERS:-}" ]]; then
            printf '%s\n' "${MOCK_EXISTING_CONTAINERS//,/$'\n'}"
        fi
        if [[ "$*" == *'{{.Names}}'* && "${MOCK_TRACK_CADDY:-0}" == "1" && -f "${MOCK_CADDY_STATE:-}" ]]; then
            printf '%s\n' 'instant-linux-browser-caddy'
        fi
        exit 0
        ;;
    inspect)
        if [[ "$*" == *'Config.Labels'* ]]; then
            printf '%s\n' "${MOCK_CADDY_MANAGED:-true}"
        elif [[ "${MOCK_CADDY_EXIT_AFTER_FIRST_CHECK:-0}" == "1" && "$*" == *'State.Running'* && "$*" == *'instant-linux-browser-caddy'* ]]; then
            check_count=0
            [[ ! -f "${MOCK_CADDY_INSPECT_COUNT_FILE:-}" ]] || read -r check_count < "$MOCK_CADDY_INSPECT_COUNT_FILE"
            check_count=$((check_count + 1))
            printf '%s\n' "$check_count" > "${MOCK_CADDY_INSPECT_COUNT_FILE:?}"
            if [[ "$check_count" -eq 1 ]]; then
                printf 'true\n'
            else
                printf 'false\n'
            fi
        else
            printf 'true\n'
        fi
        exit 0
        ;;
    exec)
        if [[ "$*" == *' caddy '* ]]; then
            if [[ "${MOCK_CADDY_RELOAD_FAIL:-0}" == "1" && "$*" == *' caddy reload '* ]]; then
                exit 1
            fi
            exit 0
        fi
        [[ "${MOCK_CHROMIUM_PROCESS:-1}" == "1" ]]
        ;;
    network)
        case "${2:-}" in
            inspect)
                [[ "${MOCK_NETWORK_EXISTS:-0}" == "1" ]] || exit 1
                if [[ "$*" == *'Labels'* ]]; then
                    printf '%s\n' "${MOCK_NETWORK_MANAGED:-true}"
                fi
                ;;
            create|rm)
                exit 0
                ;;
        esac
        ;;
    logs)
        printf '%s\n' "${MOCK_LOG_LINE:-mock container log}"
        ;;
    *)
        exit 0
        ;;
esac
MOCK_DOCKER
chmod +x "$MOCK_BIN/docker"

cat > "$MOCK_BIN/timeout" <<'MOCK_TIMEOUT'
#!/usr/bin/env bash
set -eu

seconds="$1"
shift

if [[ "${MOCK_DOCKER_INFO_TIMEOUT:-0}" == "1" && "${1:-}" == "docker" && "${2:-}" == "info" ]]; then
    exit 124
fi

exec "$@"
MOCK_TIMEOUT
chmod +x "$MOCK_BIN/timeout"

cat > "$MOCK_BIN/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -eu

{
    printf 'curl'
    printf '\t%s' "$@"
    printf '\n'
} >> "$MOCK_CURL_LOG"

[[ "${MOCK_CURL_FAIL:-0}" != "1" ]] || exit 1
printf '%s\n' "${MOCK_PUBLIC_IPV4-138.124.35.156}"
MOCK_CURL
chmod +x "$MOCK_BIN/curl"

bash -n "$SCRIPT"

NO_ACTION_OUTPUT="$TEMP_DIR/no-action.out"
if (
    source "$SCRIPT"
    if [[ -n "$TTY_FD" ]]; then
        exec {TTY_FD}>&-
    fi
    TTY_FD=""
    main
) > "$NO_ACTION_OUTPUT" 2>&1; then
    fail "A non-interactive run without an action succeeded"
fi
assert_contains "No action and no controlling terminal" "$NO_ACTION_OUTPUT"

INVALID_OUTPUT="$TEMP_DIR/invalid.out"
if PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" invalid-action > "$INVALID_OUTPUT" 2>&1; then
    fail "An invalid action succeeded"
fi
assert_contains "Invalid option: invalid-action" "$INVALID_OUTPUT"

DIAGNOSTICS_OUTPUT="$TEMP_DIR/diagnostics.out"
PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" diagnostics > "$DIAGNOSTICS_OUTPUT" 2>&1
PATH="$MOCK_BIN:$PATH" ILB_ACTION=diagnostics bash "$SCRIPT" > /dev/null 2>&1
assert_contains "Checking Docker daemon (up to 5 seconds)..." "$DIAGNOSTICS_OUTPUT"
assert_contains "--- Containers ---" "$DIAGNOSTICS_OUTPUT"

PIPED_DIAGNOSTICS_OUTPUT="$TEMP_DIR/piped-diagnostics.out"
cat "$SCRIPT" | PATH="$MOCK_BIN:$PATH" ILB_ACTION=diagnostics bash > "$PIPED_DIAGNOSTICS_OUTPUT" 2>&1
assert_contains "--- Containers ---" "$PIPED_DIAGNOSTICS_OUTPUT"
assert_not_contains "apt-get" "$MOCK_LOG"
assert_not_contains "systemctl" "$MOCK_LOG"

if command -v script >/dev/null 2>&1; then
    TTY_OUTPUT="$TEMP_DIR/tty.out"
    printf '5\n' | PATH="$MOCK_BIN:$PATH" script -qec "cat '$SCRIPT' | bash" /dev/null > "$TTY_OUTPUT" 2>&1 || fail "Streamed interactive diagnostics failed"
    assert_contains "Instant Linux Browser Installer" "$TTY_OUTPUT"
    assert_contains "--- Containers ---" "$TTY_OUTPUT"

    run_streamed_install() {
        local input="$1"
        local output="$2"
        local wrapper_command streamed_command
        shift 2

        wrapper_command='source /dev/stdin; require_root() { :; }; detect_arch() { echo x86_64; }; detect_ip() { echo 127.0.0.1; }; sleep() { :; }; main'
        printf -v streamed_command 'cat %q | bash -c %q' "$SCRIPT" "$wrapper_command"

        printf '%s' "$input" | env PATH="$MOCK_BIN:$PATH" CONFIG_BASE="$TEMP_DIR/streamed-config" "$@" script -qec "$streamed_command" /dev/null > "$output" 2>&1
    }

    : > "$MOCK_LOG"
    SEQUENTIAL_CREDENTIALS_OUTPUT="$TEMP_DIR/sequential-credentials.out"
    run_streamed_install $'1\nstreamed-user\nstreamed-password\n\n' "$SEQUENTIAL_CREDENTIALS_OUTPUT" || fail "Streamed interactive credential install failed"
    assert_contains "Enter UI Username (default: admin):" "$SEQUENTIAL_CREDENTIALS_OUTPUT"
    assert_contains "Enter UI Password:" "$SEQUENTIAL_CREDENTIALS_OUTPUT"
    assert_contains "Select access mode [1]:" "$SEQUENTIAL_CREDENTIALS_OUTPUT"
    assert_contains "self-signed certificate" "$SEQUENTIAL_CREDENTIALS_OUTPUT"
    # script may record pre-fed PTY input before read -s disables terminal echo.
    assert_contains $'docker\tpull\tlscr.io/linuxserver/chromium:latest' "$MOCK_LOG"
    assert_contains $'docker\trun' "$MOCK_LOG"
    assert_contains $'CUSTOM_USER=streamed-user' "$MOCK_LOG"
    assert_not_contains $'docker\tnetwork\tcreate' "$MOCK_LOG"

    : > "$MOCK_LOG"
    USERNAME_ONLY_OUTPUT="$TEMP_DIR/username-only.out"
    run_streamed_install $'1\npassword-only\n\n' "$USERNAME_ONLY_OUTPUT" ILB_USERNAME=provided-user || fail "Streamed password prompt with ILB_USERNAME failed"
    assert_not_contains "Enter UI Username" "$USERNAME_ONLY_OUTPUT"
    assert_contains "Enter UI Password:" "$USERNAME_ONLY_OUTPUT"
    assert_contains $'CUSTOM_USER=provided-user' "$MOCK_LOG"

    : > "$MOCK_LOG"
    ENV_CREDENTIALS_OUTPUT="$TEMP_DIR/env-credentials.out"
    run_streamed_install $'1\n' "$ENV_CREDENTIALS_OUTPUT" ILB_USERNAME=environment-user ILB_PASSWORD=environment-password ILB_DOMAIN= || fail "Environment credential install failed"
    assert_not_contains "Enter UI Username" "$ENV_CREDENTIALS_OUTPUT"
    assert_not_contains "Enter UI Password" "$ENV_CREDENTIALS_OUTPUT"
    assert_not_contains "Select access mode" "$ENV_CREDENTIALS_OUTPUT"
    assert_contains $'CUSTOM_USER=environment-user' "$MOCK_LOG"

    : > "$MOCK_LOG"
    STREAMED_SSLIP_OUTPUT="$TEMP_DIR/streamed-sslip.out"
    run_streamed_install $'1\nsslip-user\nsslip-password\n2\n' "$STREAMED_SSLIP_OUTPUT" MOCK_PUBLIC_IPV4=138.124.35.156 || fail "Streamed sslip.io selection failed"
    assert_contains "Select access mode [1]:" "$STREAMED_SSLIP_OUTPUT"
    assert_contains "https://chromium.138-124-35-156.sslip.io" "$STREAMED_SSLIP_OUTPUT"
    assert_contains "sslip.io is a third-party DNS service" "$STREAMED_SSLIP_OUTPUT"
    assert_contains $'docker\tnetwork\tcreate\t--label\tcom.instant-linux-browser.managed=true\tinstant-linux-browser' "$MOCK_LOG"

    : > "$MOCK_LOG"
    STREAMED_DOMAIN_OUTPUT="$TEMP_DIR/streamed-domain.out"
    run_streamed_install $'1\ndomain-user\ndomain-password\n3\nstreamed.example.com\n' "$STREAMED_DOMAIN_OUTPUT" || fail "Streamed custom-domain selection failed"
    assert_contains "Custom domain for automatic HTTPS:" "$STREAMED_DOMAIN_OUTPUT"
    assert_contains "https://streamed.example.com" "$STREAMED_DOMAIN_OUTPUT"
else
    echo "SKIP: streamed TTY tests require the util-linux script command"
fi

export PATH="$MOCK_BIN:$PATH"
export MOCK_LOG
export CONFIG_BASE="$TEMP_DIR/config"
source "$SCRIPT"

declare -f prompt_secret | grep -Fq -- 'read -r -s value' || fail "Password prompt must use silent read mode"

if declare -f show_diagnostics | grep -Eq 'check_docker|ensure_docker_ready|apt-get|systemctl'; then
    fail "Diagnostics must not install or start Docker"
fi

require_root() { :; }
detect_arch() { echo x86_64; }
detect_ip() { echo 203.0.113.10; }
sleep() { :; }
check_port_available() { :; }

if [[ -n "$TTY_FD" ]]; then
    exec {TTY_FD}>&-
fi
TTY_FD=""

assert_prompt_mode() {
    local input="$1"
    local expected="$2"
    local selected_mode=""

    prompt_access_mode selected_mode <<< "$input" > /dev/null
    [[ "$selected_mode" == "$expected" ]] || fail "Interactive selection '$input' did not resolve to $expected"
}

assert_prompt_mode "" ip
assert_prompt_mode 1 ip
assert_prompt_mode 2 sslip
assert_prompt_mode 3 domain

PROMPTED_DOMAIN=""
prompt_custom_domain PROMPTED_DOMAIN <<< "Prompted.Example.COM" > /dev/null
[[ "$PROMPTED_DOMAIN" == "Prompted.Example.COM" ]] || fail "Interactive custom-domain input was not captured"

unset ILB_ACCESS_MODE ILB_DOMAIN
RESOLVED_MODE=""
resolve_access_mode RESOLVED_MODE
[[ "$RESOLVED_MODE" == "ip" ]] || fail "Non-interactive installation did not default to IP mode"

ILB_DOMAIN=
resolve_access_mode RESOLVED_MODE
[[ "$RESOLVED_MODE" == "ip" ]] || fail "Explicit empty ILB_DOMAIN did not select IP mode"
unset ILB_DOMAIN

ILB_DOMAIN=Browser.Example.COM
resolve_access_mode RESOLVED_MODE
[[ "$RESOLVED_MODE" == "domain" ]] || fail "Legacy ILB_DOMAIN did not select domain mode"
LEGACY_DOMAIN=""
resolve_access_hostname chromium "$RESOLVED_MODE" LEGACY_DOMAIN
[[ "$LEGACY_DOMAIN" == "browser.example.com" ]] || fail "Legacy domain was not normalized to lowercase"
unset ILB_DOMAIN

for EXPLICIT_MODE in ip sslip; do
    ILB_ACCESS_MODE="$EXPLICIT_MODE"
    resolve_access_mode RESOLVED_MODE
    [[ "$RESOLVED_MODE" == "$EXPLICIT_MODE" ]] || fail "ILB_ACCESS_MODE=$EXPLICIT_MODE was not preserved"
done

ILB_ACCESS_MODE=domain
ILB_DOMAIN=Explicit.Example.COM
resolve_access_mode RESOLVED_MODE
EXPLICIT_DOMAIN=""
resolve_access_hostname firefox "$RESOLVED_MODE" EXPLICIT_DOMAIN
[[ "$EXPLICIT_DOMAIN" == "explicit.example.com" ]] || fail "Explicit domain mode did not resolve its hostname"
unset ILB_ACCESS_MODE ILB_DOMAIN

for INVALID_MODE in "" IP SSLIP custom; do
    if (ILB_ACCESS_MODE="$INVALID_MODE" resolve_access_mode INVALID_RESULT) > /dev/null 2>&1; then
        fail "Invalid access mode was accepted: ${INVALID_MODE:-empty}"
    fi
done

for CONFLICT_MODE in ip sslip; do
    if (ILB_ACCESS_MODE="$CONFLICT_MODE" ILB_DOMAIN=conflict.example.com resolve_access_mode CONFLICT_RESULT) > /dev/null 2>&1; then
        fail "ILB_ACCESS_MODE=$CONFLICT_MODE accepted a conflicting ILB_DOMAIN"
    fi
done

: > "$MOCK_LOG"
if (ILB_ACCESS_MODE=IP ILB_USERNAME=admin ILB_PASSWORD=preflight-secret install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > /dev/null 2>&1; then
    fail "Invalid access mode reached installation"
fi
[[ ! -s "$MOCK_LOG" ]] || fail "Invalid access mode contacted Docker before failing"

: > "$MOCK_LOG"
if (ILB_ACCESS_MODE=sslip ILB_DOMAIN=conflict.example.com ILB_USERNAME=admin ILB_PASSWORD=preflight-secret install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > /dev/null 2>&1; then
    fail "Conflicting access mode reached installation"
fi
[[ ! -s "$MOCK_LOG" ]] || fail "Conflicting access mode contacted Docker before failing"

MISSING_DOMAIN_OUTPUT="$TEMP_DIR/missing-domain.out"
if (
    TTY_FD=""
    ILB_ACCESS_MODE=domain
    unset ILB_DOMAIN
    resolve_access_mode MISSING_MODE
    resolve_access_hostname chromium "$MISSING_MODE" MISSING_HOSTNAME
) > "$MISSING_DOMAIN_OUTPUT" 2>&1; then
    fail "Non-interactive domain mode accepted a missing ILB_DOMAIN"
fi
assert_contains "requires a non-empty ILB_DOMAIN" "$MISSING_DOMAIN_OUTPUT"

for PUBLIC_IPV4 in 1.1.1.1 8.8.8.8 138.124.35.156 223.255.255.254; do
    validate_public_ipv4 "$PUBLIC_IPV4" || fail "Public IPv4 was rejected: $PUBLIC_IPV4"
done

for NON_PUBLIC_IPV4 in \
    '' '1.2.3' '1.2.3.4.5' '1.2.3.a' '01.2.3.4' '256.1.1.1' \
    '0.1.2.3' '10.1.2.3' '100.64.0.1' '100.127.255.254' '127.0.0.1' \
    '169.254.1.1' '172.16.0.1' '172.31.255.254' '192.0.0.1' '192.0.2.1' \
    '192.88.99.1' '192.168.1.1' '198.18.0.1' '198.19.255.254' \
    '198.51.100.1' '203.0.113.1' '224.0.0.1' '239.255.255.255' '240.0.0.1' '255.255.255.255'; do
    if validate_public_ipv4 "$NON_PUBLIC_IPV4"; then
        fail "Malformed or non-public IPv4 was accepted: ${NON_PUBLIC_IPV4:-empty}"
    fi
done

: > "$MOCK_CURL_LOG"
export MOCK_PUBLIC_IPV4=138.124.35.156
CHROMIUM_SSLIP_HOSTNAME=""
FIREFOX_SSLIP_HOSTNAME=""
resolve_access_hostname chromium sslip CHROMIUM_SSLIP_HOSTNAME
resolve_access_hostname firefox sslip FIREFOX_SSLIP_HOSTNAME
[[ "$CHROMIUM_SSLIP_HOSTNAME" == "chromium.138-124-35-156.sslip.io" ]] || fail "Chromium sslip.io hostname was generated incorrectly"
[[ "$FIREFOX_SSLIP_HOSTNAME" == "firefox.138-124-35-156.sslip.io" ]] || fail "Firefox sslip.io hostname was generated incorrectly"
validate_domain "$CHROMIUM_SSLIP_HOSTNAME" || fail "Generated Chromium sslip.io hostname failed domain validation"
validate_domain "$FIREFOX_SSLIP_HOSTNAME" || fail "Generated Firefox sslip.io hostname failed domain validation"
assert_contains $'curl\t-4\t-fsS\t--connect-timeout\t3\t--max-time\t5\thttps://ifconfig.me/ip' "$MOCK_CURL_LOG"

NON_PUBLIC_DETECTION_OUTPUT="$TEMP_DIR/non-public-detection.out"
if (MOCK_PUBLIC_IPV4=10.0.0.1 detect_public_ipv4 REJECTED_IPV4) > "$NON_PUBLIC_DETECTION_OUTPUT" 2>&1; then
    fail "Public IPv4 detection accepted a private address"
fi
assert_contains "requires a publicly routable IPv4 address" "$NON_PUBLIC_DETECTION_OUTPUT"

EMPTY_DETECTION_OUTPUT="$TEMP_DIR/empty-detection.out"
if (MOCK_PUBLIC_IPV4= detect_public_ipv4 REJECTED_IPV4) > "$EMPTY_DETECTION_OUTPUT" 2>&1; then
    fail "Public IPv4 detection accepted an empty response"
fi
assert_contains "requires a publicly routable IPv4 address" "$EMPTY_DETECTION_OUTPUT"

FAILED_LOOKUP_OUTPUT="$TEMP_DIR/failed-lookup.out"
if (MOCK_CURL_FAIL=1 detect_public_ipv4 REJECTED_IPV4) > "$FAILED_LOOKUP_OUTPUT" 2>&1; then
    fail "Public IPv4 detection accepted a failed lookup"
fi
assert_contains "could not detect the server's public IPv4 address within 5 seconds" "$FAILED_LOOKUP_OUTPUT"
unset MOCK_PUBLIC_IPV4

: > "$MOCK_LOG"
if (ILB_ACCESS_MODE=sslip MOCK_PUBLIC_IPV4=10.0.0.1 ILB_USERNAME=admin ILB_PASSWORD=preflight-secret install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > /dev/null 2>&1; then
    fail "Non-public IPv4 reached installation"
fi
[[ ! -s "$MOCK_LOG" ]] || fail "Non-public IPv4 contacted Docker before failing"

for INVALID_DOMAIN in \
    'https://browser.example.com' \
    'browser.example.com/path' \
    'browser.example.com:443' \
    'browser example.com' \
    '*.example.com' \
    '127.0.0.1' \
    '2001:db8::1' \
    'localhost' \
    '.example.com' \
    'browser..example.com' \
    '-browser.example.com' \
    'browser-.example.com' \
    'browser.example.com;import'; do
    if (
        ILB_DOMAIN="$INVALID_DOMAIN"
        resolve_access_mode INVALID_DOMAIN_MODE
        resolve_access_hostname chromium "$INVALID_DOMAIN_MODE" REJECTED_DOMAIN
    ) > /dev/null 2>&1; then
        fail "Invalid domain was accepted: $INVALID_DOMAIN"
    fi
done

INJECTION_OUTPUT="$TEMP_DIR/injection.out"
: > "$MOCK_LOG"
if (ILB_USERNAME=admin ILB_PASSWORD=secret ILB_DOMAIN='browser.example.com;import' install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > "$INJECTION_OUTPUT" 2>&1; then
    fail "Injection-shaped domain reached deployment"
fi
assert_not_contains $'docker\tpull' "$MOCK_LOG"
assert_not_contains $'docker\trun' "$MOCK_LOG"
[[ ! -s "$MOCK_LOG" ]] || fail "Invalid domain contacted Docker before failing"

INVALID_EMAIL_OUTPUT="$TEMP_DIR/invalid-email.out"
: > "$MOCK_LOG"
if (ILB_USERNAME=admin ILB_PASSWORD=secret ILB_DOMAIN=browser.example.com ILB_ACME_EMAIL=$'admin@example.com\n}' install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > "$INVALID_EMAIL_OUTPUT" 2>&1; then
    fail "Injection-shaped ACME email reached deployment"
fi
assert_not_contains $'docker\tpull' "$MOCK_LOG"
assert_not_contains $'docker\trun' "$MOCK_LOG"
[[ ! -s "$MOCK_LOG" ]] || fail "Invalid ACME email contacted Docker before failing"

DUPLICATE_CONFIG_BASE="$TEMP_DIR/duplicate"
(
    CONFIG_BASE="$DUPLICATE_CONFIG_BASE"
    ensure_proxy_directories
    write_caddy_route firefox shared.example.com
    assert_domain_available chromium shared.example.com
) > /dev/null 2>&1 && fail "The same domain was assigned to both browsers"

PERMISSIONS_CONFIG_BASE="$TEMP_DIR/permissions"
PERMISSIONS_LOG="$TEMP_DIR/permissions.log"
(
    chmod() {
        printf 'chmod'
        printf '\t%s' "$@"
        printf '\n'
    } > "$PERMISSIONS_LOG"
    CONFIG_BASE="$PERMISSIONS_CONFIG_BASE"
    ensure_proxy_directories
)
assert_contains $'chmod\t700\t'"$PERMISSIONS_CONFIG_BASE"$'/proxy/data\t'"$PERMISSIONS_CONFIG_BASE"'/proxy/config' "$PERMISSIONS_LOG"

EOF_OUTPUT="$TEMP_DIR/eof.out"
if (
    source "$SCRIPT"
    if [[ -n "$TTY_FD" ]]; then
        exec {TTY_FD}>&-
    fi
    TTY_FD=""
    prompt_text username "Enter UI Username (default: admin): " "admin"
) < /dev/null > "$EOF_OUTPUT" 2>&1; then
    fail "Credential EOF was accepted"
fi
assert_contains "Username input ended or was interrupted" "$EOF_OUTPUT"

DEFAULT_USERNAME_OUTPUT="$TEMP_DIR/default-username.out"
(
    source "$SCRIPT"
    if [[ -n "$TTY_FD" ]]; then
        exec {TTY_FD}>&-
    fi
    TTY_FD=""
    prompt_text username "Enter UI Username (default: admin): " "admin" <<< ""
    [[ "$username" == "admin" ]]
) > "$DEFAULT_USERNAME_OUTPUT" 2>&1 || fail "Empty username did not use the admin default"

DIAGNOSTICS_TIMEOUT_OUTPUT="$TEMP_DIR/diagnostics-timeout.out"
MOCK_DOCKER_INFO_TIMEOUT=1 show_diagnostics > "$DIAGNOSTICS_TIMEOUT_OUTPUT" 2>&1
assert_contains "Checking Docker daemon (up to 5 seconds)..." "$DIAGNOSTICS_TIMEOUT_OUTPUT"
assert_contains "Docker: daemon check timed out after 5 seconds" "$DIAGNOSTICS_TIMEOUT_OUTPUT"

RESOLVED_IDS="$(SUDO_USER=root resolve_puid_pgid)"
[[ "$RESOLVED_IDS" == "1000:1000" ]] || fail "Expected safe UID/GID fallback, got $RESOLVED_IDS"

: > "$MOCK_LOG"
INSTALL_OUTPUT="$TEMP_DIR/install.out"
unset ILB_ACCESS_MODE ILB_DOMAIN ILB_ACME_EMAIL MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS
ILB_USERNAME=admin ILB_PASSWORD=do-not-print-this install_browser chromium lscr.io/linuxserver/chromium:latest 3000 > "$INSTALL_OUTPUT" 2>&1
assert_not_contains "do-not-print-this" "$INSTALL_OUTPUT"
assert_not_contains "do-not-print-this" "$MOCK_LOG"
assert_contains $'PASSWORD=[REDACTED]' "$MOCK_LOG"
assert_not_contains "Enter UI Username" "$INSTALL_OUTPUT"
assert_not_contains "Enter UI Password" "$INSTALL_OUTPUT"
assert_not_contains "Select access mode" "$INSTALL_OUTPUT"
assert_contains "https://203.0.113.10:3001" "$INSTALL_OUTPUT"
assert_contains "HTTP (proxy-only)" "$INSTALL_OUTPUT"
assert_contains "self-signed certificate" "$INSTALL_OUTPUT"

RUN_RECORD="$TEMP_DIR/docker-run.log"
awk -F '\t' '$2 == "run" { print; found = 1; exit } END { exit !found }' "$MOCK_LOG" > "$RUN_RECORD" || fail "Docker run invocation was not recorded"
IMAGE_INDEX="$(argument_index "lscr.io/linuxserver/chromium:latest")"
[[ -n "$IMAGE_INDEX" ]] || fail "Chromium image was not passed to docker run"
assert_environment_before_image "PIXELFLUX_WAYLAND=false"
assert_environment_before_image "CHROME_CLI=--no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox"
assert_contains $'\t-p\t3000:3000\t-p\t3001:3001' "$RUN_RECORD"
assert_not_contains "--network=$CADDY_NETWORK" "$RUN_RECORD"
assert_not_contains "--disable-software-rasterizer" "$RUN_RECORD"
assert_not_contains "instant-linux-browser-caddy" "$MOCK_LOG"
assert_not_contains $'docker\tnetwork\t' "$MOCK_LOG"

CONFIG_BASE="$TEMP_DIR/sslip-chromium"
: > "$MOCK_LOG"
export MOCK_PUBLIC_IPV4=138.124.35.156
SSLIP_CHROMIUM_OUTPUT="$TEMP_DIR/sslip-chromium.out"
ILB_ACCESS_MODE=sslip ILB_USERNAME=sslip-user ILB_PASSWORD=sslip-password \
    install_browser chromium lscr.io/linuxserver/chromium:latest 3000 > "$SSLIP_CHROMIUM_OUTPUT" 2>&1
unset ILB_ACCESS_MODE MOCK_PUBLIC_IPV4
assert_contains "https://chromium.138-124-35-156.sslip.io" "$SSLIP_CHROMIUM_OUTPUT"
assert_not_contains "HTTP (proxy-only)" "$SSLIP_CHROMIUM_OUTPUT"
assert_contains "sslip.io is a third-party DNS service" "$SSLIP_CHROMIUM_OUTPUT"
assert_contains "hostname exposes the server IP" "$SSLIP_CHROMIUM_OUTPUT"
assert_contains "ports 80 and 443 must be publicly reachable" "$SSLIP_CHROMIUM_OUTPUT"
assert_contains "rate limits may prevent certificate issuance" "$SSLIP_CHROMIUM_OUTPUT"
assert_contains "custom domain for stable long-term production" "$SSLIP_CHROMIUM_OUTPUT"
assert_not_contains "sslip-password" "$SSLIP_CHROMIUM_OUTPUT"
assert_not_contains "Enter UI Username" "$SSLIP_CHROMIUM_OUTPUT"
assert_not_contains "Enter UI Password" "$SSLIP_CHROMIUM_OUTPUT"
assert_not_contains "Select access mode" "$SSLIP_CHROMIUM_OUTPUT"
assert_not_contains "Custom domain for automatic HTTPS" "$SSLIP_CHROMIUM_OUTPUT"
assert_contains "chromium.138-124-35-156.sslip.io {" "$CONFIG_BASE/proxy/sites/chromium.caddy"
assert_contains "reverse_proxy chromium:3000" "$CONFIG_BASE/proxy/sites/chromium.caddy"

SSLIP_CHROMIUM_RUN="$TEMP_DIR/sslip-chromium-run.log"
record_run_with_argument "lscr.io/linuxserver/chromium:latest" "$SSLIP_CHROMIUM_RUN" || fail "sslip.io Chromium run was not recorded"
assert_contains $'\t--network=instant-linux-browser\t' "$SSLIP_CHROMIUM_RUN"
assert_contains $'\t-p\t127.0.0.1:3000:3000\t-p\t127.0.0.1:3001:3001' "$SSLIP_CHROMIUM_RUN"

SSLIP_CADDY_RUN="$TEMP_DIR/sslip-caddy-run.log"
record_run_with_argument "--name=instant-linux-browser-caddy" "$SSLIP_CADDY_RUN" || fail "sslip.io Caddy run was not recorded"
assert_contains $'\t-p\t80:80\t-p\t443:443' "$SSLIP_CADDY_RUN"

CONFIG_BASE="$TEMP_DIR/domain-chromium"
: > "$MOCK_LOG"
unset MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS
DOMAIN_CHROMIUM_OUTPUT="$TEMP_DIR/domain-chromium.out"
ILB_USERNAME=domain-user ILB_PASSWORD=domain-password ILB_DOMAIN=Chrome.Example.COM ILB_ACME_EMAIL=admin@example.com \
    install_browser chromium lscr.io/linuxserver/chromium:latest 3000 > "$DOMAIN_CHROMIUM_OUTPUT" 2>&1
assert_contains "Browser URL (HTTPS):" "$DOMAIN_CHROMIUM_OUTPUT"
assert_contains "https://chrome.example.com" "$DOMAIN_CHROMIUM_OUTPUT"
assert_contains "Caddy manages certificate issuance and renewal" "$DOMAIN_CHROMIUM_OUTPUT"
assert_not_contains "domain-password" "$DOMAIN_CHROMIUM_OUTPUT"
assert_not_contains "Enter UI Username" "$DOMAIN_CHROMIUM_OUTPUT"
assert_not_contains "Enter UI Password" "$DOMAIN_CHROMIUM_OUTPUT"
assert_not_contains "Select access mode" "$DOMAIN_CHROMIUM_OUTPUT"
assert_not_contains "Custom domain for automatic HTTPS" "$DOMAIN_CHROMIUM_OUTPUT"
assert_contains "chrome.example.com {" "$CONFIG_BASE/proxy/sites/chromium.caddy"
assert_contains "reverse_proxy chromium:3000" "$CONFIG_BASE/proxy/sites/chromium.caddy"
assert_contains "email admin@example.com" "$CONFIG_BASE/proxy/Caddyfile"
assert_contains "import /etc/caddy/sites/*.caddy" "$CONFIG_BASE/proxy/Caddyfile"
assert_not_contains "domain-password" "$CONFIG_BASE/proxy/Caddyfile"
assert_not_contains "domain-password" "$CONFIG_BASE/proxy/sites/chromium.caddy"

DOMAIN_CHROMIUM_RUN="$TEMP_DIR/domain-chromium-run.log"
record_run_with_argument "lscr.io/linuxserver/chromium:latest" "$DOMAIN_CHROMIUM_RUN" || fail "Domain Chromium run was not recorded"
assert_contains $'\t--network=instant-linux-browser\t' "$DOMAIN_CHROMIUM_RUN"
assert_contains $'\t-p\t127.0.0.1:3000:3000\t-p\t127.0.0.1:3001:3001' "$DOMAIN_CHROMIUM_RUN"

CADDY_RUN="$TEMP_DIR/caddy-run.log"
record_run_with_argument "--name=instant-linux-browser-caddy" "$CADDY_RUN" || fail "Caddy run was not recorded"
assert_contains $'\t--network=instant-linux-browser\t' "$CADDY_RUN"
assert_contains $'\t-p\t80:80\t-p\t443:443' "$CADDY_RUN"
assert_contains $'\tcaddy:2-alpine' "$CADDY_RUN"
assert_contains $'\t-v\t'"$CONFIG_BASE"$'/proxy:/etc/caddy:ro\t' "$CADDY_RUN"
assert_contains $'\t-v\t'"$CONFIG_BASE"$'/proxy/data:/data\t' "$CADDY_RUN"
assert_contains $'\t-v\t'"$CONFIG_BASE"$'/proxy/config:/config\t' "$CADDY_RUN"
assert_not_contains "$CONFIG_BASE/proxy/data:/data:ro" "$CADDY_RUN"
assert_not_contains "$CONFIG_BASE/proxy/config:/config:ro" "$CADDY_RUN"
assert_contains $'docker\tnetwork\tcreate\t--label\tcom.instant-linux-browser.managed=true\tinstant-linux-browser' "$MOCK_LOG"

CONFIG_BASE="$TEMP_DIR/caddy-immediate-exit"
ensure_proxy_directories
: > "$MOCK_LOG"
export MOCK_TRACK_CADDY=1
export MOCK_CADDY_STATE="$TEMP_DIR/caddy.state"
export MOCK_CADDY_INSPECT_COUNT_FILE="$TEMP_DIR/caddy-inspect-count"
export MOCK_CADDY_EXIT_AFTER_FIRST_CHECK=1
rm -f -- "$MOCK_CADDY_STATE" "$MOCK_CADDY_INSPECT_COUNT_FILE"
CADDY_EXIT_OUTPUT="$TEMP_DIR/caddy-immediate-exit.out"
if configure_caddy_route chromium immediate-exit.example.com "" > "$CADDY_EXIT_OUTPUT" 2>&1; then
    fail "Caddy startup succeeded after the container exited immediately"
fi
assert_contains "Caddy setup failed: container start or reload failed" "$CADDY_EXIT_OUTPUT"
assert_contains "Recent Caddy logs:" "$CADDY_EXIT_OUTPUT"
assert_contains $'docker\tlogs\t--tail\t80\tinstant-linux-browser-caddy' "$MOCK_LOG"
[[ ! -f "$CONFIG_BASE/proxy/sites/chromium.caddy" ]] || fail "Failed Caddy startup left the new route configured"
unset MOCK_TRACK_CADDY MOCK_CADDY_STATE MOCK_CADDY_INSPECT_COUNT_FILE MOCK_CADDY_EXIT_AFTER_FIRST_CHECK

CONFIG_BASE="$TEMP_DIR/domain-firefox"
: > "$MOCK_LOG"
unset MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS
DOMAIN_FIREFOX_OUTPUT="$TEMP_DIR/domain-firefox.out"
ILB_ACCESS_MODE=domain ILB_USERNAME=firefox-user ILB_PASSWORD=firefox-password ILB_DOMAIN=firefox.example.com \
    install_browser firefox lscr.io/linuxserver/firefox:latest 4000 > "$DOMAIN_FIREFOX_OUTPUT" 2>&1
assert_contains "https://firefox.example.com" "$DOMAIN_FIREFOX_OUTPUT"
assert_contains "reverse_proxy firefox:3000" "$CONFIG_BASE/proxy/sites/firefox.caddy"

DOMAIN_FIREFOX_RUN="$TEMP_DIR/domain-firefox-run.log"
record_run_with_argument "lscr.io/linuxserver/firefox:latest" "$DOMAIN_FIREFOX_RUN" || fail "Domain Firefox run was not recorded"
assert_contains $'\t--network=instant-linux-browser\t' "$DOMAIN_FIREFOX_RUN"
assert_contains $'\t-p\t127.0.0.1:4000:3000\t-p\t127.0.0.1:4001:3001' "$DOMAIN_FIREFOX_RUN"

CONFIG_BASE="$TEMP_DIR/sslip-firefox"
: > "$MOCK_LOG"
unset MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS ILB_DOMAIN
export MOCK_PUBLIC_IPV4=138.124.35.156
SSLIP_FIREFOX_OUTPUT="$TEMP_DIR/sslip-firefox.out"
ILB_ACCESS_MODE=sslip ILB_USERNAME=firefox-user ILB_PASSWORD=firefox-password \
    install_browser firefox lscr.io/linuxserver/firefox:latest 4000 > "$SSLIP_FIREFOX_OUTPUT" 2>&1
unset ILB_ACCESS_MODE MOCK_PUBLIC_IPV4
assert_contains "https://firefox.138-124-35-156.sslip.io" "$SSLIP_FIREFOX_OUTPUT"
assert_contains "firefox.138-124-35-156.sslip.io {" "$CONFIG_BASE/proxy/sites/firefox.caddy"
assert_contains "reverse_proxy firefox:3000" "$CONFIG_BASE/proxy/sites/firefox.caddy"

SSLIP_FIREFOX_RUN="$TEMP_DIR/sslip-firefox-run.log"
record_run_with_argument "lscr.io/linuxserver/firefox:latest" "$SSLIP_FIREFOX_RUN" || fail "sslip.io Firefox run was not recorded"
assert_contains $'\t--network=instant-linux-browser\t' "$SSLIP_FIREFOX_RUN"
assert_contains $'\t-p\t127.0.0.1:4000:3000\t-p\t127.0.0.1:4001:3001' "$SSLIP_FIREFOX_RUN"

CONFIG_BASE="$TEMP_DIR/reused-caddy"
: > "$MOCK_LOG"
export MOCK_EXISTING_CONTAINERS=instant-linux-browser-caddy
export MOCK_NETWORK_EXISTS=1
REUSED_CADDY_OUTPUT="$TEMP_DIR/reused-caddy.out"
ILB_USERNAME=reuse-user ILB_PASSWORD=reuse-password ILB_DOMAIN=reuse.example.com \
    install_browser firefox lscr.io/linuxserver/firefox:latest 4000 > "$REUSED_CADDY_OUTPUT" 2>&1
assert_not_contains $'docker\tpull\tcaddy:2-alpine' "$MOCK_LOG"
if record_run_with_argument "--name=instant-linux-browser-caddy" "$TEMP_DIR/unexpected-caddy-run.log"; then
    fail "Existing project Caddy container was recreated"
fi
assert_contains $'docker\texec\t-w\t/etc/caddy\tinstant-linux-browser-caddy\tcaddy\treload' "$MOCK_LOG"

CONFIG_BASE="$TEMP_DIR/uninstall-one-route"
ensure_proxy_directories
write_caddy_main_config ""
write_caddy_route chromium chromium.138-124-35-156.sslip.io
write_caddy_route firefox firefox.example.com
: > "$MOCK_LOG"
export MOCK_EXISTING_CONTAINERS=chromium,instant-linux-browser-caddy
export MOCK_NETWORK_EXISTS=1
uninstall_browser chromium > "$TEMP_DIR/uninstall-one-route.out" 2>&1
[[ ! -f "$CONFIG_BASE/proxy/sites/chromium.caddy" ]] || fail "Chromium route was not removed"
[[ -f "$CONFIG_BASE/proxy/sites/firefox.caddy" ]] || fail "Firefox route was removed unexpectedly"
assert_not_contains $'docker\tstop\tinstant-linux-browser-caddy' "$MOCK_LOG"
assert_contains $'docker\texec\t-w\t/etc/caddy\tinstant-linux-browser-caddy\tcaddy\treload' "$MOCK_LOG"

CONFIG_BASE="$TEMP_DIR/uninstall-last-route"
ensure_proxy_directories
write_caddy_main_config ""
write_caddy_route firefox last.example.com
: > "$MOCK_LOG"
export MOCK_EXISTING_CONTAINERS=firefox,instant-linux-browser-caddy
uninstall_browser firefox > "$TEMP_DIR/uninstall-last-route.out" 2>&1
[[ ! -f "$CONFIG_BASE/proxy/sites/firefox.caddy" ]] || fail "Last Firefox route was not removed"
assert_contains $'docker\tstop\tinstant-linux-browser-caddy' "$MOCK_LOG"
assert_contains $'docker\trm\tinstant-linux-browser-caddy' "$MOCK_LOG"

CONFIG_BASE="$TEMP_DIR/uninstall-reload-failure"
ensure_proxy_directories
write_caddy_main_config ""
write_caddy_route chromium stale.example.com
write_caddy_route firefox retained.example.com
: > "$MOCK_LOG"
export MOCK_EXISTING_CONTAINERS=chromium,instant-linux-browser-caddy
export MOCK_CADDY_RELOAD_FAIL=1
UNINSTALL_FAILURE_OUTPUT="$TEMP_DIR/uninstall-reload-failure.out"
if (uninstall_browser chromium) > "$UNINSTALL_FAILURE_OUTPUT" 2>&1; then
    fail "Uninstall succeeded after Caddy route removal failed"
fi
[[ -f "$CONFIG_BASE/proxy/sites/chromium.caddy" ]] || fail "Failed route removal did not restore the Chromium route"
assert_not_contains $'docker\tstop\tchromium' "$MOCK_LOG"
assert_not_contains $'docker\trm\tchromium' "$MOCK_LOG"
assert_not_contains "Cleanup complete." "$UNINSTALL_FAILURE_OUTPUT"
assert_contains "Failed to remove the chromium domain route safely" "$UNINSTALL_FAILURE_OUTPUT"
unset MOCK_CADDY_RELOAD_FAIL

unset MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS MOCK_PUBLIC_IPV4 ILB_ACCESS_MODE ILB_DOMAIN ILB_ACME_EMAIL

LOG_OUTPUT="$TEMP_DIR/log.out"
export MOCK_LOG_LINE='do-not-print-this'
print_recent_logs chromium do-not-print-this > "$LOG_OUTPUT"
unset MOCK_LOG_LINE
assert_not_contains "do-not-print-this" "$LOG_OUTPUT"
assert_contains "[REDACTED]" "$LOG_OUTPUT"

PROCESS_OUTPUT="$TEMP_DIR/process.out"
export MOCK_CHROMIUM_PROCESS=0
if verify_chromium_startup > "$PROCESS_OUTPUT" 2>&1; then
    fail "Missing Chromium process was reported as ready"
fi
unset MOCK_CHROMIUM_PROCESS
assert_contains "container is running but no Chromium process was found" "$PROCESS_OUTPUT"

echo "PASS: browser.sh checks"
