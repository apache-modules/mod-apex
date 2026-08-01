#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="${BASE_URL:-http://127.0.0.1}"
PROBE_FILE="${PROBE_FILE:-common-app-probe.php}"
PROBE_SRC="${PROBE_SRC:-$REPO_ROOT/probes/common-app-probe.php}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
PROBE_URL_PATH="/${PROBE_FILE}"
RUN_WRK="${RUN_WRK:-0}"
WRK_PATH="${WRK_PATH:-/test.php}"
WRK_DURATION="${WRK_DURATION:-15s}"
SMOKE_RPS_MIN="${SMOKE_RPS_MIN:-100}"
SMOKE_READ_ERR_MAX="${SMOKE_READ_ERR_MAX:-0}"

PASS_COUNT=0
FAIL_COUNT=0

log() {
    printf '%s\n' "$*"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    log "PASS: $*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "FAIL: $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 2
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if grep -Fq "$needle" <<<"$haystack"; then
        pass "$label"
    else
        fail "$label (expected '$needle')"
    fi
}

deploy_probe() {
    if [[ ! -f "$PROBE_SRC" ]]; then
        log "Probe source not found: $PROBE_SRC"
        exit 2
    fi

    sudo cp "$PROBE_SRC" "$WEB_ROOT/$PROBE_FILE"
}

run_checks() {
    local out

    out="$(curl -sS --max-time 10 -H 'Host: app.local' "$BASE_URL$PROBE_URL_PATH?route=login")"
    assert_contains "$out" "REQUEST_METHOD=GET" "GET request method"
    assert_contains "$out" "REQUEST_URI=$PROBE_URL_PATH?route=login" "GET request URI"
    assert_contains "$out" "SCRIPT_NAME=$PROBE_URL_PATH" "SCRIPT_NAME present"
    assert_contains "$out" "HAS_FRONT_CONTROLLER_META=yes" "Front-controller metadata check"

    out="$(curl -sS --max-time 10 -X POST -H 'Host: app.local' -H 'Content-Type: application/x-www-form-urlencoded' --data 'a=1' "$BASE_URL$PROBE_URL_PATH")"
    assert_contains "$out" "REQUEST_METHOD=POST" "POST request method"
    assert_contains "$out" "CONTENT_TYPE=application/x-www-form-urlencoded" "POST content type"
    assert_contains "$out" "CONTENT_LENGTH=3" "POST content length"

    out="$(curl -sS --max-time 10 -u appuser:apppass -H 'Host: app.local' "$BASE_URL$PROBE_URL_PATH")"
    assert_contains "$out" "AUTH_TYPE=Basic" "Basic auth type"
    assert_contains "$out" "PHP_AUTH_USER=appuser" "PHP_AUTH_USER mapping"
    assert_contains "$out" "PHP_AUTH_PW=apppass" "PHP_AUTH_PW mapping"
    assert_contains "$out" "HAS_AUTH_BASIC=yes" "Basic auth compatibility check"

    out="$(curl -sS --max-time 10 -H 'Host: app.local' -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: app.example.com' -H 'X-Forwarded-For: 203.0.113.5' -H 'X-Real-IP: 203.0.113.5' "$BASE_URL$PROBE_URL_PATH/index.php/admin/users?x=1")"
    assert_contains "$out" "PATH_INFO=/index.php/admin/users" "PATH_INFO mapping"
    assert_contains "$out" "HTTP_X_FORWARDED_PROTO=https" "Forwarded proto mapping"
    assert_contains "$out" "HTTP_X_FORWARDED_HOST=app.example.com" "Forwarded host mapping"
    assert_contains "$out" "HTTP_X_FORWARDED_FOR=203.0.113.5" "Forwarded for mapping"
    assert_contains "$out" "HTTP_X_REAL_IP=203.0.113.5" "X-Real-IP mapping"
    assert_contains "$out" "HAS_PROXY_META=yes" "Proxy compatibility check"
    assert_contains "$out" "HAS_PATH_INFO=yes" "PATH_INFO compatibility check"

    if [[ "$RUN_WRK" == "1" ]]; then
        if ! command -v wrk >/dev/null 2>&1; then
            fail "wrk sanity run (wrk not installed)"
            return
        fi

        # Precheck: the target must return HTTP 200 before load means anything.
        # Guards against benchmarking the wrong vhost/port at 47k error-pages/s.
        local wrk_url="$BASE_URL$WRK_PATH"
        local code
        code="$(curl -s -o /dev/null --max-time 10 -H 'Host: app.local' -w '%{http_code}' "$wrk_url" || true)"
        if [[ "$code" != "200" ]]; then
            fail "wrk precheck: $wrk_url returned HTTP ${code:-none}, expected 200"
            return
        fi
        pass "wrk precheck: $wrk_url returns 200"

        local wrk_out=/tmp/apex_phase4_wrk.txt
        if ! wrk -t2 -c100 -d"$WRK_DURATION" -H 'Host: app.local' "$wrk_url" >"$wrk_out" 2>&1; then
            fail "wrk sanity run (wrk exited non-zero; see $wrk_out)"
            return
        fi

        # Evidence checks on the wrk output itself -- exit code 0 alone proves
        # nothing (wrk exits 0 even when 100% of responses are errors).
        local rps non2xx read_err
        rps="$(awk '/^Requests\/sec:/ {print $2}' "$wrk_out")"
        non2xx="$(awk '/Non-2xx or 3xx responses:/ {print $NF}' "$wrk_out")"
        read_err="$(awk -F'read ' '/Socket errors:/ {print $2}' "$wrk_out" | awk -F',' '{print $1}')"
        non2xx="${non2xx:-0}"
        read_err="${read_err:-0}"

        log "wrk: rps=${rps:-0} non2xx=$non2xx read_errors=$read_err (full output: $wrk_out)"

        if [[ "$non2xx" == "0" ]]; then
            pass "wrk responses all 2xx/3xx"
        else
            fail "wrk responses: $non2xx non-2xx/3xx responses"
        fi

        if awk -v v="$read_err" -v max="$SMOKE_READ_ERR_MAX" 'BEGIN { exit !(v <= max) }'; then
            pass "wrk read socket errors <= $SMOKE_READ_ERR_MAX"
        else
            fail "wrk read socket errors: $read_err > $SMOKE_READ_ERR_MAX"
        fi

        if [[ -n "$rps" ]] && awk -v v="$rps" -v min="$SMOKE_RPS_MIN" 'BEGIN { exit !(v >= min) }'; then
            pass "wrk RPS >= $SMOKE_RPS_MIN"
        else
            fail "wrk RPS: ${rps:-0} < $SMOKE_RPS_MIN"
        fi
    fi
}

main() {
    require_cmd curl
    require_cmd sudo

    log "Deploying probe to $WEB_ROOT/$PROBE_FILE"
    deploy_probe

    log "Running compatibility checks against $BASE_URL$PROBE_URL_PATH"
    run_checks

    log "---"
    log "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
