#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1}"
APEX_PATH="${APEX_PATH:-/test.php}"
FPM_PATH="${FPM_PATH:-/fpm/test.php}"
APP_PATH="${APP_PATH:-/wordpress}"
THREADS="${THREADS:-2}"
CONNECTIONS="${CONNECTIONS:-1000}"
SOAK_SECONDS="${SOAK_SECONDS:-60}"
SHORT_SECONDS="${SHORT_SECONDS:-15}"
RECENT_CORE_MINUTES="${RECENT_CORE_MINUTES:-30}"
APP_RPS_MIN="${APP_RPS_MIN:-10000}"
APP_READ_ERR_MAX="${APP_READ_ERR_MAX:-5000}"
CANARY_READ_ERR_MAX="${CANARY_READ_ERR_MAX:-2000}"
CANARY_RPS_MIN="${CANARY_RPS_MIN:-5000}"

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

collect_core_names() {
    if [[ -d /var/lib/apache2/coredumps ]]; then
        find /var/lib/apache2/coredumps -maxdepth 1 -type f -name 'core.*' -printf '%f\n' | sort -u
    fi
}

get_rps() {
    awk '/Requests\/sec:/ {print $2}' "$1" | tail -n 1
}

get_read_errors() {
    awk '/Socket errors:/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "read") {
                gsub(",", "", $(i+1));
                print $(i+1);
                exit;
            }
        }
    }' "$1"
}

run_wrk() {
    local url="$1"
    local duration="$2"
    local out_file="$3"

    wrk -t"$THREADS" -c"$CONNECTIONS" -d"${duration}s" "$url" | tee "$out_file"
}

check_guardrails() {
    log "--- Guardrails ---"

    if sudo apachectl -t >/dev/null 2>&1; then
        pass "apachectl syntax"
    else
        fail "apachectl syntax"
    fi

    if systemctl is-active apache2 >/dev/null 2>&1; then
        pass "apache2 active"
    else
        fail "apache2 active"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$APEX_PATH" >/dev/null; then
        pass "apex health endpoint"
    else
        fail "apex health endpoint"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$FPM_PATH" >/dev/null; then
        pass "fpm health endpoint"
    else
        fail "fpm health endpoint"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$APP_PATH" >/dev/null; then
        pass "app health endpoint"
    else
        fail "app health endpoint"
    fi
}

check_soak_and_crash() {
    log "--- Soak And Crash Gate ---"

    local before_cores_file
    local after_cores_file
    local new_cores

    before_cores_file="$(mktemp)"
    after_cores_file="$(mktemp)"

    collect_core_names > "$before_cores_file"

    TRUNCATE_LOG=1 "$SCRIPT_DIR/apache_crash_watch.sh" -- \
        wrk -t"$THREADS" -c"$CONNECTIONS" -d"${SOAK_SECONDS}s" "$BASE_URL$APEX_PATH" \
        > /tmp/apex_soak_gate.txt 2>&1 || fail "apex soak crash gate"

    if grep -q "\[crash-watch\] PASS" /tmp/apex_soak_gate.txt; then
        pass "apex soak crash gate"
    fi

    "$SCRIPT_DIR/apache_crash_watch.sh" -- \
        wrk -t"$THREADS" -c"$CONNECTIONS" -d"${SOAK_SECONDS}s" "$BASE_URL$FPM_PATH" \
        > /tmp/fpm_soak_gate.txt 2>&1 || fail "fpm soak crash gate"

    if grep -q "\[crash-watch\] PASS" /tmp/fpm_soak_gate.txt; then
        pass "fpm soak crash gate"
    fi

    if ! sudo grep -Eq 'AH00051|reslist_cleanup|Segmentation fault|exit signal Abort' /var/log/apache2/error.log; then
        pass "no recent crash signatures in apache log"
    else
        fail "no recent crash signatures in apache log"
    fi

    collect_core_names > "$after_cores_file"
    new_cores="$(comm -13 "$before_cores_file" "$after_cores_file" || true)"
    if [[ -z "$new_cores" ]]; then
        pass "no new core dump files during gate run"
    else
        fail "no new core dump files during gate run"
        log "$new_cores"
    fi

    rm -f "$before_cores_file" "$after_cores_file"
}

check_slo() {
    log "--- SLO Check ---"

    run_wrk "$BASE_URL$APP_PATH" "$SHORT_SECONDS" /tmp/app_slo_gate.txt >/dev/null

    local rps
    local read_err
    rps="$(get_rps /tmp/app_slo_gate.txt)"
    read_err="$(get_read_errors /tmp/app_slo_gate.txt)"
    read_err="${read_err:-0}"

    log "SLO sample: app_rps=${rps:-0} app_read_errors=$read_err"

    if [[ -n "$rps" ]] && awk -v v="$rps" -v min="$APP_RPS_MIN" 'BEGIN { exit !(v >= min) }'; then
        pass "app RPS >= ${APP_RPS_MIN}"
    else
        fail "app RPS >= ${APP_RPS_MIN}"
    fi

    if awk -v v="$read_err" -v max="$APP_READ_ERR_MAX" 'BEGIN { exit !(v <= max) }'; then
        pass "app read errors <= ${APP_READ_ERR_MAX}"
    else
        fail "app read errors <= ${APP_READ_ERR_MAX}"
    fi
}

check_canary() {
    log "--- Canary Stages ---"

    local c1_file=/tmp/canary_stage1.txt
    local c2_file=/tmp/canary_stage2.txt
    local c3_file=/tmp/canary_stage3.txt

    wrk -t1 -c100 -d"${SHORT_SECONDS}s" "$BASE_URL$APP_PATH" | tee "$c1_file" >/dev/null
    wrk -t2 -c300 -d"${SHORT_SECONDS}s" "$BASE_URL$APP_PATH" | tee "$c2_file" >/dev/null
    wrk -t2 -c1000 -d"${SHORT_SECONDS}s" "$BASE_URL$APP_PATH" | tee "$c3_file" >/dev/null

    local stage3_rps
    local stage3_read_err
    stage3_rps="$(get_rps "$c3_file")"
    stage3_read_err="$(get_read_errors "$c3_file")"
    stage3_read_err="${stage3_read_err:-0}"

    log "Canary stage3: rps=${stage3_rps:-0} read_errors=$stage3_read_err"

    if [[ -n "$stage3_rps" ]] && awk -v v="$stage3_rps" -v min="$CANARY_RPS_MIN" 'BEGIN { exit !(v >= min) }'; then
        pass "canary stage3 RPS >= ${CANARY_RPS_MIN}"
    else
        fail "canary stage3 RPS >= ${CANARY_RPS_MIN}"
    fi

    if awk -v v="$stage3_read_err" -v max="$CANARY_READ_ERR_MAX" 'BEGIN { exit !(v <= max) }'; then
        pass "canary stage3 read errors <= ${CANARY_READ_ERR_MAX}"
    else
        fail "canary stage3 read errors <= ${CANARY_READ_ERR_MAX}"
    fi
}

check_disaster_recovery() {
    log "--- Disaster Recovery Drill ---"

    if sudo apachectl -t >/dev/null 2>&1 && sudo systemctl restart apache2 >/dev/null 2>&1; then
        pass "apache restart drill"
    else
        fail "apache restart drill"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$APP_PATH" >/dev/null; then
        pass "app healthy after restart"
    else
        fail "app healthy after restart"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$APEX_PATH" >/dev/null; then
        pass "apex healthy after restart"
    else
        fail "apex healthy after restart"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$FPM_PATH" >/dev/null; then
        pass "fpm healthy after restart"
    else
        fail "fpm healthy after restart"
    fi
}

main() {
    require_cmd wrk
    require_cmd curl
    require_cmd sudo
    require_cmd awk
    require_cmd grep
    require_cmd find

    log "Production Readiness Gate"
    log "BASE_URL=$BASE_URL APP_PATH=$APP_PATH APEX_PATH=$APEX_PATH FPM_PATH=$FPM_PATH"
    log "THREADS=$THREADS CONNECTIONS=$CONNECTIONS SOAK_SECONDS=$SOAK_SECONDS"

    check_guardrails
    check_soak_and_crash
    check_slo
    check_canary
    check_disaster_recovery

    log "---"
    log "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
