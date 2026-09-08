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
    info|pull|run|stop|rm|ps)
        exit 0
        ;;
    inspect)
        printf 'true\n'
        exit 0
        ;;
    exec)
        [[ "${MOCK_CHROMIUM_PROCESS:-1}" == "1" ]]
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
else
    echo "SKIP: streamed TTY test requires the util-linux script command"
fi

export PATH="$MOCK_BIN:$PATH"
export MOCK_LOG
export CONFIG_BASE="$TEMP_DIR/config"
source "$SCRIPT"

if declare -f show_diagnostics | grep -Eq 'check_docker|ensure_docker_ready|apt-get|systemctl'; then
    fail "Diagnostics must not install or start Docker"
fi

require_root() { :; }
detect_arch() { echo x86_64; }
sleep() { :; }

DIAGNOSTICS_TIMEOUT_OUTPUT="$TEMP_DIR/diagnostics-timeout.out"
MOCK_DOCKER_INFO_TIMEOUT=1 show_diagnostics > "$DIAGNOSTICS_TIMEOUT_OUTPUT" 2>&1
assert_contains "Checking Docker daemon (up to 5 seconds)..." "$DIAGNOSTICS_TIMEOUT_OUTPUT"
assert_contains "Docker: daemon check timed out after 5 seconds" "$DIAGNOSTICS_TIMEOUT_OUTPUT"

RESOLVED_IDS="$(SUDO_USER=root resolve_puid_pgid)"
[[ "$RESOLVED_IDS" == "1000:1000" ]] || fail "Expected safe UID/GID fallback, got $RESOLVED_IDS"

: > "$MOCK_LOG"
INSTALL_OUTPUT="$TEMP_DIR/install.out"
ILB_USERNAME=admin ILB_PASSWORD=do-not-print-this install_browser chromium lscr.io/linuxserver/chromium:latest 3000 > "$INSTALL_OUTPUT" 2>&1
assert_not_contains "do-not-print-this" "$INSTALL_OUTPUT"

RUN_RECORD="$TEMP_DIR/docker-run.log"
awk -F '\t' '$2 == "run" { print; found = 1; exit } END { exit !found }' "$MOCK_LOG" > "$RUN_RECORD" || fail "Docker run invocation was not recorded"
IMAGE_INDEX="$(argument_index "lscr.io/linuxserver/chromium:latest")"
[[ -n "$IMAGE_INDEX" ]] || fail "Chromium image was not passed to docker run"
assert_environment_before_image "PIXELFLUX_WAYLAND=false"
assert_environment_before_image "CHROME_CLI=--no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox"
assert_not_contains "--disable-software-rasterizer" "$RUN_RECORD"

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
