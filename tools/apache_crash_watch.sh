#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/apache2/error.log}"
CORE_DIR="${CORE_DIR:-/var/lib/apache2/coredumps}"
TRUNCATE_LOG="${TRUNCATE_LOG:-0}"

PATTERN='AH00051|reslist_cleanup|Segmentation fault|exit signal Abort|AH02537'

usage() {
    cat <<'EOF'
Usage:
  apache_crash_watch.sh -- <benchmark command>

Examples:
  ./tools/apache_crash_watch.sh -- wrk -t2 -c1000 -d60s http://127.0.0.1/test.php
  TRUNCATE_LOG=1 ./tools/apache_crash_watch.sh -- wrk -t2 -c1000 -d60s http://127.0.0.1/fpm/test.php

Environment:
  LOG_FILE      Apache error log path (default: /var/log/apache2/error.log)
  CORE_DIR      Core dump directory (default: /var/lib/apache2/coredumps)
  TRUNCATE_LOG  Set to 1 to clear the log before running the command
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 2
    fi
}

collect_core_names() {
    if [[ -d "$CORE_DIR" ]]; then
        find "$CORE_DIR" -maxdepth 1 -type f -name 'core.*' -printf '%f\n' | sort -u
    fi
}

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$1" != "--" ]]; then
    echo "Expected '--' before benchmark command" >&2
    usage
    exit 2
fi
shift

if [[ $# -eq 0 ]]; then
    echo "Missing benchmark command" >&2
    usage
    exit 2
fi

require_cmd wc
require_cmd grep
require_cmd find

if [[ "$TRUNCATE_LOG" == "1" ]]; then
    sudo truncate -s 0 "$LOG_FILE"
fi

before_lines=0
if [[ -f "$LOG_FILE" ]]; then
    before_lines="$(wc -l < "$LOG_FILE")"
fi

before_cores_file="$(mktemp)"
after_cores_file="$(mktemp)"
trap 'rm -f "$before_cores_file" "$after_cores_file"' EXIT

collect_core_names > "$before_cores_file"

echo "[crash-watch] start: $(date '+%F %T %z')"
echo "[crash-watch] command: $*"
"$@"
cmd_rc=$?

echo "[crash-watch] end: $(date '+%F %T %z')"

after_lines=0
if [[ -f "$LOG_FILE" ]]; then
    after_lines="$(wc -l < "$LOG_FILE")"
fi

new_log=""
if [[ "$after_lines" -ge "$before_lines" && "$after_lines" -gt 0 ]]; then
    new_log="$(tail -n +$((before_lines + 1)) "$LOG_FILE" || true)"
fi

new_crash_lines=""
if [[ -n "$new_log" ]]; then
    new_crash_lines="$(grep -En "$PATTERN" <<<"$new_log" || true)"
fi

collect_core_names > "$after_cores_file"
new_cores="$(comm -13 "$before_cores_file" "$after_cores_file" || true)"

status=0
if [[ $cmd_rc -ne 0 ]]; then
    status=1
fi
if [[ -n "$new_crash_lines" ]]; then
    status=1
fi
if [[ -n "$new_cores" ]]; then
    status=1
fi

echo "[crash-watch] command_exit=$cmd_rc"

if [[ -n "$new_crash_lines" ]]; then
    echo "[crash-watch] NEW crash signatures in log:" 
    echo "$new_crash_lines"
else
    echo "[crash-watch] No new crash signatures in log."
fi

if [[ -n "$new_cores" ]]; then
    echo "[crash-watch] NEW core files:" 
    echo "$new_cores"
else
    echo "[crash-watch] No new core files."
fi

if [[ $status -eq 0 ]]; then
    echo "[crash-watch] PASS"
else
    echo "[crash-watch] FAIL"
fi

exit $status
