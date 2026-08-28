#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"
APACHE_CONF="/etc/apache2/apache2.conf"
MPM_CONF="/etc/apache2/mods-enabled/mpm_event.conf"

usage() {
    cat <<'EOF'
Usage:
  ./tools/apache_mode.sh status
  ./tools/apache_mode.sh throughput
  ./tools/apache_mode.sh steady

Modes:
  status      Show current Apache connection/worker settings.
  throughput  Max-RPS profile for stress tests.
  steady      Sensible CPU-sized settings for a smooth, dependable server.

steady environment overrides:
  APEX_CPUS                 Use this CPU count instead of auto-detection.
  APEX_MAX_REQUEST_WORKERS  Override the calculated worker count (64-2048).
EOF
}

require_root_tooling() {
    command -v sudo >/dev/null 2>&1 || {
        echo "Missing required command: sudo" >&2
        exit 2
    }
}

show_status() {
    echo "apache2.conf"
    grep -nE '^KeepAlive\b|^MaxKeepAliveRequests|^KeepAliveTimeout|^Timeout\b' "$APACHE_CONF"
    echo "---"
    echo "mpm_event.conf"
    grep -nE 'StartServers|ServerLimit|ThreadLimit|ThreadsPerChild|MinSpareThreads|MaxSpareThreads|MaxRequestWorkers|MaxConnectionsPerChild' "$MPM_CONF"
}

set_throughput_mode() {
    sudo sed -i -E 's/^KeepAlive\s+.*/KeepAlive On/' "$APACHE_CONF"
    sudo sed -i -E 's/^MaxKeepAliveRequests\s+.*/MaxKeepAliveRequests 10000/' "$APACHE_CONF"
    sudo sed -i -E 's/^KeepAliveTimeout\s+.*/KeepAliveTimeout 1/' "$APACHE_CONF"

    sudo sed -i -E 's/^StartServers\s+.*/StartServers            8/' "$MPM_CONF"
    sudo sed -i -E 's/^ServerLimit\s+.*/ServerLimit             157/' "$MPM_CONF"
    sudo sed -i -E 's/^MinSpareThreads\s+.*/MinSpareThreads         512/' "$MPM_CONF"
    sudo sed -i -E 's/^MaxSpareThreads\s+.*/MaxSpareThreads         1024/' "$MPM_CONF"
    sudo sed -i -E 's/^MaxRequestWorkers\s+.*/MaxRequestWorkers       10048/' "$MPM_CONF"
    sudo sed -i -E 's/^MaxConnectionsPerChild\s+.*/MaxConnectionsPerChild  0/' "$MPM_CONF"
}

set_steady_mode() {
    local cpus max_request_workers threads_per_child server_limit
    local start_servers min_spare_threads max_spare_threads

    cpus="${APEX_CPUS:-}"
    if [[ -z "$cpus" ]]; then
        cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    fi
    if [[ ! "$cpus" =~ ^[1-9][0-9]*$ ]]; then
        echo "Unable to detect a positive CPU count. Set APEX_CPUS=N." >&2
        exit 2
    fi

    # Keep the conservative profile proportional to available CPU while
    # avoiding tiny pools on small hosts and unsafe default pools on big ones.
    max_request_workers=$((cpus * 64))
    if (( max_request_workers < 128 )); then
        max_request_workers=128
    elif (( max_request_workers > 2048 )); then
        max_request_workers=2048
    fi

    if [[ -n "${APEX_MAX_REQUEST_WORKERS:-}" ]]; then
        if [[ ! "$APEX_MAX_REQUEST_WORKERS" =~ ^[1-9][0-9]*$ ]] \
            || (( APEX_MAX_REQUEST_WORKERS < 64 || APEX_MAX_REQUEST_WORKERS > 2048 )); then
            echo "APEX_MAX_REQUEST_WORKERS must be an integer from 64 to 2048." >&2
            exit 2
        fi
        max_request_workers="$APEX_MAX_REQUEST_WORKERS"
    fi

    threads_per_child=64
    server_limit=$(((max_request_workers + threads_per_child - 1) / threads_per_child))
    start_servers=$(((cpus + 3) / 4))
    if (( start_servers < 1 )); then
        start_servers=1
    elif (( start_servers > server_limit )); then
        start_servers=$server_limit
    fi
    min_spare_threads=$threads_per_child
    if (( min_spare_threads > max_request_workers )); then
        min_spare_threads=$max_request_workers
    fi
    max_spare_threads=$((threads_per_child * 4))
    if (( max_spare_threads > max_request_workers )); then
        max_spare_threads=$max_request_workers
    fi

    echo "steady profile: cpus=$cpus max_request_workers=$max_request_workers"
    echo "  server_limit=$server_limit threads_per_child=$threads_per_child"
    echo "  start_servers=$start_servers min_spare_threads=$min_spare_threads max_spare_threads=$max_spare_threads"

    sudo sed -i -E 's/^KeepAlive\s+.*/KeepAlive Off/' "$APACHE_CONF"
    sudo sed -i -E 's/^MaxKeepAliveRequests\s+.*/MaxKeepAliveRequests 10000/' "$APACHE_CONF"
    sudo sed -i -E 's/^KeepAliveTimeout\s+.*/KeepAliveTimeout 5/' "$APACHE_CONF"

    sudo sed -i -E "s/^StartServers\\s+.*/StartServers            $start_servers/" "$MPM_CONF"
    sudo sed -i -E "s/^ServerLimit\\s+.*/ServerLimit             $server_limit/" "$MPM_CONF"
    sudo sed -i -E "s/^ThreadLimit\\s+.*/ThreadLimit             $threads_per_child/" "$MPM_CONF"
    sudo sed -i -E "s/^ThreadsPerChild\\s+.*/ThreadsPerChild         $threads_per_child/" "$MPM_CONF"
    sudo sed -i -E "s/^MinSpareThreads\\s+.*/MinSpareThreads         $min_spare_threads/" "$MPM_CONF"
    sudo sed -i -E "s/^MaxSpareThreads\\s+.*/MaxSpareThreads         $max_spare_threads/" "$MPM_CONF"
    sudo sed -i -E "s/^MaxRequestWorkers\\s+.*/MaxRequestWorkers       $max_request_workers/" "$MPM_CONF"
    sudo sed -i -E 's/^MaxConnectionsPerChild\s+.*/MaxConnectionsPerChild  0/' "$MPM_CONF"
}

apply_and_restart() {
    sudo apachectl -t
    sudo systemctl restart apache2
}

require_root_tooling

case "$MODE" in
    status)
        show_status
        ;;
    throughput)
        set_throughput_mode
        apply_and_restart
        show_status
        ;;
    steady)
        set_steady_mode
        apply_and_restart
        show_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        usage
        exit 2
        ;;
esac
