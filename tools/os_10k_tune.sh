#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/mod_apex_10k}"

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
        log "Run this script as root (for example: sudo ./tools/os_10k_tune.sh)"
        exit 1
    fi
}

backup_file() {
    local src="$1"
    local dest="$2"

    mkdir -p "$BACKUP_DIR"
    if [[ -e "$src" && ! -e "$dest" ]]; then
        cp "$src" "$dest"
    fi
}

main() {
    need_cmd sysctl
    need_cmd systemctl
    need_cmd grep
    require_root

    backup_file /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak"

    if [[ -d /etc/systemd/system/apache2.service.d ]]; then
        backup_file /etc/systemd/system/apache2.service.d/override.conf "$BACKUP_DIR/apache2.override.conf.bak"
    fi

    if ! grep -q '^www-data soft nofile 65535$' /etc/security/limits.conf; then
        cat <<'EOF' >> /etc/security/limits.conf

# mod_apex 10k profile
www-data soft nofile 65535
www-data hard nofile 65535
EOF
    fi

    mkdir -p /etc/systemd/system/apache2.service.d
    cat <<'EOF' > /etc/systemd/system/apache2.service.d/override.conf
[Service]
LimitNOFILE=65535
EOF

    sysctl -w net.core.somaxconn=65535
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535
    sysctl -w net.ipv4.ip_local_port_range='1024 65000'

    systemctl daemon-reload
    systemctl restart apache2

    log "Updated OS-side limits for 10,000 connections."
    log "Current values:"
    sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range
    grep -E '^www-data\s+(soft|hard)\s+nofile\s+65535$' /etc/security/limits.conf || true
    systemctl show apache2 -p LimitNOFILE
}

main "$@"