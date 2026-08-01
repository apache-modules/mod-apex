#!/usr/bin/env bash
# compat_matrix.sh -- per-app compatibility certification for mod_apex.
#
# For each configured app: HTTP precheck (status + content marker), a short
# evidence-parsed load run, and an error-log crash-signature delta. Plus a
# one-time framework probe (shim functions, chdir behavior, cross-request
# state isolation, run twice to detect leakage).
#
# Verdicts per app:
#   PASS      precheck ok, load run clean (0 non-2xx, read errors <= bound,
#             RPS >= floor), no new crash signatures
#   DEGRADED  serves correctly but load-run bounds missed
#   FAIL      precheck failed, non-2xx under load, or crash signatures
#
# Usage:
#   BASE_URL=http://127.0.0.1:8081 ./tools/compat_matrix.sh
#   APPS_FILE=./my_apps.list ./tools/compat_matrix.sh
#
# APPS_FILE lines:  name|url_path|expect_substring
# Default list certifies WordPress only -- add rows per app you deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="${BASE_URL:-http://127.0.0.1:8081}"
APPS_FILE="${APPS_FILE:-}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
ERROR_LOG="${ERROR_LOG:-/var/log/apache2/error.log}"
PROBE_SRC="${PROBE_SRC:-$REPO_ROOT/probes/framework-compat-probe.php}"
PROBE_FILE="${PROBE_FILE:-framework-compat-probe.php}"
WRK_DURATION="${WRK_DURATION:-30s}"
WRK_THREADS="${WRK_THREADS:-2}"
WRK_CONNS="${WRK_CONNS:-100}"
MATRIX_RPS_MIN="${MATRIX_RPS_MIN:-50}"
MATRIX_READ_ERR_MAX="${MATRIX_READ_ERR_MAX:-0}"
RESULTS_FILE="${RESULTS_FILE:-$REPO_ROOT/compat_matrix_results.txt}"

CRASH_RE='exit signal|Segmentation|signal 11|child pid .* exit'

PASS_COUNT=0
FAIL_COUNT=0

log()  { printf '%s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); log "PASS: $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); log "FAIL: $*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { log "Missing required command: $1"; exit 2; }
}

crash_baseline() {
    # grep -c already prints 0 on no match (and exits 1), so don't also
    # trigger a fallback echo or the count gets double-printed.
    local n
    n="$(sudo grep -acE "$CRASH_RE" "$ERROR_LOG" 2>/dev/null)"
    printf '%s\n' "${n:-0}"
}

# ---------------------------------------------------------------- probe ----
run_framework_probe() {
    log "== Framework probe =="
    if [[ ! -f "$PROBE_SRC" ]]; then
        fail "probe source not found: $PROBE_SRC"
        return
    fi
    sudo cp "$PROBE_SRC" "$WEB_ROOT/$PROBE_FILE"

    local url="$BASE_URL/$PROBE_FILE"
    local first second
    first="$(curl -sS --max-time 10 "$url")" || { fail "probe request failed: $url"; return; }
    second="$(curl -sS --max-time 10 "$url")" || { fail "probe second request failed"; return; }

    grep -Fq 'PROBE_COMPLETE=yes' <<<"$first" \
        && pass "probe executes to completion" \
        || { fail "probe did not complete (fatal mid-script?)"; return; }

    grep -Fq 'SHIM_FUNCTIONS_PRESENT=yes' <<<"$first" \
        && pass "apache2handler shim functions all present" \
        || fail "shim functions missing: $(grep -F 'SHIM_FUNCTIONS_PRESENT=' <<<"$first")"

    grep -Fq 'SHIM_SETENV_ROUNDTRIP=yes' <<<"$first" \
        && pass "apache_setenv/getenv roundtrip" \
        || fail "apache_setenv/getenv roundtrip"

    grep -Fq 'SHIM_NOTE_ROUNDTRIP=yes' <<<"$first" \
        && pass "apache_note roundtrip" \
        || fail "apache_note roundtrip"

    grep -Fq 'OPCACHE_ACTIVE=yes' <<<"$first" \
        && pass "OPcache active" \
        || fail "OPcache inactive (SAPI-name override not effective?)"

    # Cross-request isolation: SECOND response must show markers absent.
    grep -Fq 'PRIOR_GLOBAL_MARKER=absent' <<<"$second" \
        && pass "no cross-request superglobal leakage" \
        || fail "superglobal marker leaked across requests"

    grep -Fq 'PRIOR_STATIC_MARKER=absent' <<<"$second" \
        && pass "no cross-request static leakage" \
        || fail "static variable leaked across requests"

    # Informational, not pass/fail: documented NO_CHDIR + putenv behavior.
    log "info: $(grep -F 'CWD_EQUALS_SCRIPT_DIR=' <<<"$first") (expected 'no' under mod_apex NO_CHDIR)"
    log "info: $(grep -F 'RELATIVE_OPEN_RESOLVES=' <<<"$first") (legacy relative-include caveat if 'no')"
    log "info: $(grep -F 'PRIOR_PUTENV_MARKER=' <<<"$second") (putenv is process-global under threads by design)"
}

# ------------------------------------------------------------- per app ----
# Outputs one matrix row: name verdict rps p99 read_err non2xx crash_delta
check_app() {
    local name="$1" path="$2" expect="$3"
    local url="$BASE_URL$path"
    local verdict="PASS" rps="-" p99="-" read_err=0 non2xx=0

    log "== App: $name ($url) =="

    # Precheck: status must be 200 and body must contain the app marker.
    # (Guards against certifying an error page at 47k RPS.)
    local code body
    code="$(curl -s -o /tmp/apex_matrix_body.$$ --max-time 15 -w '%{http_code}' "$url" || echo 000)"
    body="$(head -c 65536 /tmp/apex_matrix_body.$$ 2>/dev/null || true)"
    rm -f /tmp/apex_matrix_body.$$
    if [[ "$code" != "200" ]]; then
        fail "$name precheck: HTTP $code (expected 200)"
        printf '%-14s %-9s %-9s %-9s %-9s %-9s %s\n' "$name" "FAIL" "-" "-" "-" "-" "-" >>"$RESULTS_FILE"
        return
    fi
    if [[ -n "$expect" ]] && ! grep -Fq "$expect" <<<"$body"; then
        fail "$name precheck: body lacks expected marker '$expect'"
        printf '%-14s %-9s %-9s %-9s %-9s %-9s %s\n' "$name" "FAIL" "-" "-" "-" "-" "-" >>"$RESULTS_FILE"
        return
    fi
    pass "$name precheck: 200 + content marker"

    # Load run with evidence parsing + crash delta.
    local base_crashes wrk_out=/tmp/apex_matrix_wrk_${name}.txt
    base_crashes="$(crash_baseline)"
    wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d5s "$url" >/dev/null 2>&1 || true   # warm
    if ! wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$WRK_DURATION" --timeout 10s --latency "$url" >"$wrk_out" 2>&1; then
        fail "$name load run: wrk exited non-zero (see $wrk_out)"
        verdict="FAIL"
    fi

    rps="$(awk '/^Requests\/sec:/ {print $2}' "$wrk_out")"
    p99="$(awk '/^ *99%/ {print $2}' "$wrk_out")"
    non2xx="$(awk '/Non-2xx or 3xx responses:/ {print $NF}' "$wrk_out")"
    read_err="$(awk -F'read ' '/Socket errors:/ {print $2}' "$wrk_out" | awk -F',' '{print $1}')"
    non2xx="${non2xx:-0}"; read_err="${read_err:-0}"; rps="${rps:-0}"; p99="${p99:--}"

    local new_crashes crash_delta
    new_crashes="$(crash_baseline)"
    crash_delta=$((new_crashes - base_crashes))

    log "$name load: rps=$rps p99=$p99 non2xx=$non2xx read_err=$read_err crash_delta=$crash_delta"

    if [[ "$non2xx" != "0" ]]; then
        fail "$name: $non2xx non-2xx/3xx responses under load"
        verdict="FAIL"
    fi
    if [[ "$crash_delta" -gt 0 ]]; then
        fail "$name: $crash_delta new crash signature(s) in $ERROR_LOG"
        verdict="FAIL"
    fi
    if [[ "$verdict" == "PASS" ]]; then
        if ! awk -v v="$read_err" -v max="$MATRIX_READ_ERR_MAX" 'BEGIN { exit !(v <= max) }'; then
            fail "$name: read errors $read_err > $MATRIX_READ_ERR_MAX"
            verdict="DEGRADED"
        fi
        if ! awk -v v="$rps" -v min="$MATRIX_RPS_MIN" 'BEGIN { exit !(v >= min) }'; then
            fail "$name: RPS $rps < $MATRIX_RPS_MIN"
            verdict="DEGRADED"
        fi
    fi
    [[ "$verdict" == "PASS" ]] && pass "$name certified"

    printf '%-14s %-9s %-9s %-9s %-9s %-9s %s\n' \
        "$name" "$verdict" "$rps" "$p99" "$read_err" "$non2xx" "$crash_delta" >>"$RESULTS_FILE"
}

# ----------------------------------------------------------------- main ----
main() {
    require_cmd curl
    require_cmd wrk
    require_cmd sudo

    : >"$RESULTS_FILE"
    printf '%-14s %-9s %-9s %-9s %-9s %-9s %s\n' \
        "APP" "VERDICT" "RPS" "P99" "READ_ERR" "NON2XX" "CRASH_DELTA" >>"$RESULTS_FILE"

    run_framework_probe

    if [[ -n "$APPS_FILE" && -f "$APPS_FILE" ]]; then
        while IFS='|' read -r name path expect; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            check_app "$name" "$path" "${expect:-}"
        done <"$APPS_FILE"
    else
        # Default: the one app certified so far. Add rows via APPS_FILE.
        check_app "wordpress" "/wordpress/" "wp-"
    fi

    log "---"
    log "Matrix written to $RESULTS_FILE:"
    cat "$RESULTS_FILE"
    log "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"

    [[ $FAIL_COUNT -gt 0 ]] && exit 1
    exit 0
}

main "$@"
