#!/usr/bin/env bash
set -euo pipefail

BACKUP_SUFFIX="${BACKUP_SUFFIX:-mod_apex_10000}"

log() {
    printf '%s\n' "$*"
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 2
    fi
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log "Run this script as root (for example: sudo ./tools/apache_10k_tune.sh)"
        exit 1
    fi
}

backup_if_missing() {
    local src="$1"
    local backup="$2"
    if [[ ! -e "$backup" ]]; then
        cp "$src" "$backup"
    fi
}

main() {
    need_cmd perl
    need_cmd apachectl
    need_cmd systemctl
    require_root

    backup_if_missing /etc/apache2/mods-enabled/mpm_event.conf "/etc/apache2/mods-enabled/mpm_event.conf.bak_${BACKUP_SUFFIX}"
    backup_if_missing /etc/apache2/apache2.conf "/etc/apache2/apache2.conf.bak_${BACKUP_SUFFIX}"

    perl -0pi -e 's/StartServers\s+\d+/StartServers            8/; s/ServerLimit\s+\d+/ServerLimit             157/; s/ThreadLimit\s+\d+/ThreadLimit             64/; s/ThreadsPerChild\s+\d+/ThreadsPerChild         64/; s/MinSpareThreads\s+\d+/MinSpareThreads         512/; s/MaxSpareThreads\s+\d+/MaxSpareThreads         1024/; s/MaxRequestWorkers\s+\d+/MaxRequestWorkers       10048/; s/MaxConnectionsPerChild\s+\d+/MaxConnectionsPerChild  0/' /etc/apache2/mods-enabled/mpm_event.conf
    perl -0pi -e 's/MaxKeepAliveRequests\s+\d+/MaxKeepAliveRequests 10000/; s/KeepAliveTimeout\s+\d+/KeepAliveTimeout 1/' /etc/apache2/apache2.conf

    apachectl -t
    systemctl restart apache2

    log "Updated live Apache tuning for 10,000 connections."
    log "Current values:"
    grep -E '^(StartServers|ServerLimit|ThreadLimit|ThreadsPerChild|MinSpareThreads|MaxSpareThreads|MaxRequestWorkers|MaxConnectionsPerChild)' /etc/apache2/mods-enabled/mpm_event.conf
    grep -E '^(KeepAlive|MaxKeepAliveRequests|KeepAliveTimeout)' /etc/apache2/apache2.conf
}

main "$@"