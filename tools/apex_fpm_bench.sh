#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1}"
APEX_PATH="${APEX_PATH:-/test.php}"
FPM_PATH="${FPM_PATH:-/fpm/test.php}"
THREADS="${THREADS:-2}"
CONNECTIONS="${CONNECTIONS:-100}"
DURATION="${DURATION:-10s}"
TIMEOUT="${TIMEOUT:-10}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
    printf '%s\n' "$*"
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 2
    fi
}

require_http_ok() {
    local url="$1"
    local code

    code="$(curl -sS --max-time "$TIMEOUT" -o /dev/null -w '%{http_code}' "$url")"
    if [[ "$code" != "200" ]]; then
        log "Endpoint check failed for $url (HTTP $code)"
        exit 1
    fi
}

run_wrk() {
    local label="$1"
    local url="$2"
    local out_file="$3"

    log "Running wrk for $label -> $url"
    wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" "$url" >"$out_file" 2>&1
}

extract_metric() {
    local out_file="$1"
    local metric="$2"

    case "$metric" in
        requests_sec)
            awk '/Requests\/sec:/ {print $2}' "$out_file" | tail -n 1
            ;;
        latency_avg)
            awk '/^\s*Latency\s+/ {print $2}' "$out_file" | tail -n 1
            ;;
        transfer_sec)
            awk '/Transfer\/sec:/ {print $2" "$3}' "$out_file" | tail -n 1
            ;;
        socket_errors)
            awk '/Socket errors:/ {print $0}' "$out_file" | tail -n 1
            ;;
        requests_total)
            awk '/requests in/ {print $1}' "$out_file" | tail -n 1
            ;;
        non_2xx)
            awk '/Non-2xx or 3xx responses:/ {print $5}' "$out_file" | tail -n 1
            ;;
        *)
            return 1
            ;;
    esac
}

to_number_or_zero() {
    local v="$1"
    if [[ -z "$v" ]]; then
        printf '0'
    else
        printf '%s' "$v"
    fi
}

main() {
    need_cmd curl
    need_cmd wrk
    need_cmd awk

    local apex_url="${BASE_URL}${APEX_PATH}"
    local fpm_url="${BASE_URL}${FPM_PATH}"
    local apex_out="$TMP_DIR/apex_wrk.txt"
    local fpm_out="$TMP_DIR/fpm_wrk.txt"

    log "Validating endpoints before benchmark"
    require_http_ok "$apex_url"
    require_http_ok "$fpm_url"

    run_wrk "mod_apex" "$apex_url" "$apex_out"
    run_wrk "php-fpm" "$fpm_url" "$fpm_out"

    local apex_rps fpm_rps apex_lat fpm_lat apex_tx fpm_tx apex_req fpm_req apex_non2xx fpm_non2xx apex_sock fpm_sock
    local faster pct

    apex_rps="$(extract_metric "$apex_out" requests_sec)"
    fpm_rps="$(extract_metric "$fpm_out" requests_sec)"
    apex_lat="$(extract_metric "$apex_out" latency_avg)"
    fpm_lat="$(extract_metric "$fpm_out" latency_avg)"
    apex_tx="$(extract_metric "$apex_out" transfer_sec)"
    fpm_tx="$(extract_metric "$fpm_out" transfer_sec)"
    apex_req="$(extract_metric "$apex_out" requests_total)"
    fpm_req="$(extract_metric "$fpm_out" requests_total)"
    apex_non2xx="$(to_number_or_zero "$(extract_metric "$apex_out" non_2xx)")"
    fpm_non2xx="$(to_number_or_zero "$(extract_metric "$fpm_out" non_2xx)")"
    apex_sock="$(extract_metric "$apex_out" socket_errors)"
    fpm_sock="$(extract_metric "$fpm_out" socket_errors)"

    if awk -v a="$apex_rps" -v b="$fpm_rps" 'BEGIN {exit !(a>b)}'; then
        faster="mod_apex"
    elif awk -v a="$apex_rps" -v b="$fpm_rps" 'BEGIN {exit !(b>a)}'; then
        faster="php-fpm"
    else
        faster="tie"
    fi

    pct="$(awk -v a="$apex_rps" -v b="$fpm_rps" 'BEGIN { if (b==0) {print "0.00"} else { printf "%.2f", ((a-b)/b)*100 } }')"

    log ""
    log "Benchmark Parameters"
    log "  threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
    log ""
    log "Results"
    log "  mod_apex: Requests/sec=$apex_rps Latency(avg)=$apex_lat Transfer/sec=$apex_tx Requests=$apex_req Non2xx=$apex_non2xx"
    if [[ -n "$apex_sock" ]]; then
        log "    $apex_sock"
    fi
    log "  php-fpm : Requests/sec=$fpm_rps Latency(avg)=$fpm_lat Transfer/sec=$fpm_tx Requests=$fpm_req Non2xx=$fpm_non2xx"
    if [[ -n "$fpm_sock" ]]; then
        log "    $fpm_sock"
    fi
    log ""
    log "Summary"
    log "  Faster endpoint: $faster"
    log "  mod_apex vs php-fpm Requests/sec delta: ${pct}%"

    cp "$apex_out" ./apex_wrk_last.txt
    cp "$fpm_out" ./fpm_wrk_last.txt
    log ""
    log "Saved raw outputs: ./apex_wrk_last.txt ./fpm_wrk_last.txt"
}

main "$@"
