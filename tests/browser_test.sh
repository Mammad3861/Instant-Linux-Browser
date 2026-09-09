#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/browser.sh"
TEMP_DIR="$(mktemp -d)"
MOCK_BIN="$TEMP_DIR/bin"
MOCK_LOG="$TEMP_DIR/docker.log"
export MOCK_LOG

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
        printf '\t%s' "$argument"
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
    assert_contains "Optional domain for automatic HTTPS" "$SEQUENTIAL_CREDENTIALS_OUTPUT"
    # script may record pre-fed PTY input before read -s disables terminal echo.
    assert_contains $'docker\tpull\tlscr.io/linuxserver/chromium:latest' "$MOCK_LOG"
    assert_contains $'docker\trun' "$MOCK_LOG"
    assert_contains $'CUSTOM_USER=streamed-user' "$MOCK_LOG"

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
    assert_not_contains "Optional domain for automatic HTTPS" "$ENV_CREDENTIALS_OUTPUT"
    assert_contains $'CUSTOM_USER=environment-user' "$MOCK_LOG"
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
sleep() { :; }
check_port_available() { :; }

EXPLICIT_EMPTY_DOMAIN="not-empty"
(
    prompt_optional_domain() { fail "Explicit empty ILB_DOMAIN prompted unexpectedly"; }
    TTY_FD=9
    ILB_DOMAIN=
    resolve_install_domain EXPLICIT_EMPTY_DOMAIN
    [[ -z "$EXPLICIT_EMPTY_DOMAIN" ]]
) || fail "Explicit empty ILB_DOMAIN did not disable domain mode"

NORMALIZED_DOMAIN=""
ILB_DOMAIN=Browser.Example.COM
resolve_install_domain NORMALIZED_DOMAIN
unset ILB_DOMAIN
[[ "$NORMALIZED_DOMAIN" == "browser.example.com" ]] || fail "Domain was not normalized to lowercase"

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
    if (ILB_DOMAIN="$INVALID_DOMAIN" resolve_install_domain REJECTED_DOMAIN) > /dev/null 2>&1; then
        fail "Invalid domain was accepted: $INVALID_DOMAIN"
    fi
done

NON_INTERACTIVE_DOMAIN="unexpected"
TTY_FD=""
unset ILB_DOMAIN
resolve_install_domain NON_INTERACTIVE_DOMAIN
[[ -z "$NON_INTERACTIVE_DOMAIN" ]] || fail "No-terminal domain selection did not default to IP mode"

INJECTION_OUTPUT="$TEMP_DIR/injection.out"
: > "$MOCK_LOG"
if (ILB_USERNAME=admin ILB_PASSWORD=secret ILB_DOMAIN='browser.example.com;import' install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > "$INJECTION_OUTPUT" 2>&1; then
    fail "Injection-shaped domain reached deployment"
fi
assert_not_contains $'docker\tpull' "$MOCK_LOG"
assert_not_contains $'docker\trun' "$MOCK_LOG"

INVALID_EMAIL_OUTPUT="$TEMP_DIR/invalid-email.out"
: > "$MOCK_LOG"
if (ILB_USERNAME=admin ILB_PASSWORD=secret ILB_DOMAIN=browser.example.com ILB_ACME_EMAIL=$'admin@example.com\n}' install_browser chromium lscr.io/linuxserver/chromium:latest 3000) > "$INVALID_EMAIL_OUTPUT" 2>&1; then
    fail "Injection-shaped ACME email reached deployment"
fi
assert_not_contains $'docker\tpull' "$MOCK_LOG"
assert_not_contains $'docker\trun' "$MOCK_LOG"

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
unset ILB_DOMAIN ILB_ACME_EMAIL MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS
ILB_USERNAME=admin ILB_PASSWORD=do-not-print-this install_browser chromium lscr.io/linuxserver/chromium:latest 3000 > "$INSTALL_OUTPUT" 2>&1
assert_not_contains "do-not-print-this" "$INSTALL_OUTPUT"
assert_not_contains "Enter UI Username" "$INSTALL_OUTPUT"
assert_not_contains "Enter UI Password" "$INSTALL_OUTPUT"
assert_not_contains "Optional domain for automatic HTTPS" "$INSTALL_OUTPUT"

RUN_RECORD="$TEMP_DIR/docker-run.log"
awk -F '\t' '$2 == "run" { print; found = 1; exit } END { exit !found }' "$MOCK_LOG" > "$RUN_RECORD" || fail "Docker run invocation was not recorded"
IMAGE_INDEX="$(argument_index "lscr.io/linuxserver/chromium:latest")"
[[ -n "$IMAGE_INDEX" ]] || fail "Chromium image was not passed to docker run"
assert_environment_before_image "PIXELFLUX_WAYLAND=false"
assert_environment_before_image "CHROME_CLI=--no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox"
assert_contains $'\t-p\t3000:3000\t-p\t3001:3001' "$RUN_RECORD"
assert_not_contains "--network=$CADDY_NETWORK" "$RUN_RECORD"
assert_not_contains "--disable-software-rasterizer" "$RUN_RECORD"

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
ILB_USERNAME=firefox-user ILB_PASSWORD=firefox-password ILB_DOMAIN=firefox.example.com \
    install_browser firefox lscr.io/linuxserver/firefox:latest 4000 > "$DOMAIN_FIREFOX_OUTPUT" 2>&1
assert_contains "https://firefox.example.com" "$DOMAIN_FIREFOX_OUTPUT"
assert_contains "reverse_proxy firefox:3000" "$CONFIG_BASE/proxy/sites/firefox.caddy"

DOMAIN_FIREFOX_RUN="$TEMP_DIR/domain-firefox-run.log"
record_run_with_argument "lscr.io/linuxserver/firefox:latest" "$DOMAIN_FIREFOX_RUN" || fail "Domain Firefox run was not recorded"
assert_contains $'\t--network=instant-linux-browser\t' "$DOMAIN_FIREFOX_RUN"
assert_contains $'\t-p\t127.0.0.1:4000:3000\t-p\t127.0.0.1:4001:3001' "$DOMAIN_FIREFOX_RUN"

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
write_caddy_route chromium chromium.example.com
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

unset MOCK_EXISTING_CONTAINERS MOCK_NETWORK_EXISTS ILB_DOMAIN ILB_ACME_EMAIL

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
