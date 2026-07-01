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
  ./tools/apache_mode.sh low-error

Modes:
  status      Show current Apache connection/worker settings.
  throughput  Max-RPS profile for stress tests.
  low-error   Reduced-error profile for stability checks.
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
    grep -nE 'StartServers|ServerLimit|ThreadsPerChild|MinSpareThreads|MaxSpareThreads|MaxRequestWorkers|MaxConnectionsPerChild' "$MPM_CONF"
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

set_low_error_mode() {
    sudo sed -i -E 's/^KeepAlive\s+.*/KeepAlive Off/' "$APACHE_CONF"
    sudo sed -i -E 's/^MaxKeepAliveRequests\s+.*/MaxKeepAliveRequests 10000/' "$APACHE_CONF"
    sudo sed -i -E 's/^KeepAliveTimeout\s+.*/KeepAliveTimeout 5/' "$APACHE_CONF"

    sudo sed -i -E 's/^StartServers\s+.*/StartServers            4/' "$MPM_CONF"
    sudo sed -i -E 's/^ServerLimit\s+.*/ServerLimit             32/' "$MPM_CONF"
    sudo sed -i -E 's/^MinSpareThreads\s+.*/MinSpareThreads         128/' "$MPM_CONF"
    sudo sed -i -E 's/^MaxSpareThreads\s+.*/MaxSpareThreads         256/' "$MPM_CONF"
    sudo sed -i -E 's/^MaxRequestWorkers\s+.*/MaxRequestWorkers       2048/' "$MPM_CONF"
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
    low-error)
        set_low_error_mode
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
