#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"
CONF_NAME="apex-perf"
CONF_PATH="/etc/apache2/conf-available/${CONF_NAME}.conf"

usage() {
    cat <<'EOF'
Usage:
  ./tools/apache_asset_perf.sh status
  ./tools/apache_asset_perf.sh apply
  ./tools/apache_asset_perf.sh remove

Modes:
  status  Show current module/config status for asset performance tuning.
  apply   Enable cache/compression profile for static assets and restart Apache.
  remove  Disable profile and restart Apache.
EOF
}

log() {
    printf '%s\n' "$*"
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 2
    fi
}

enable_module_if_available() {
    local mod="$1"
    if [[ -f "/etc/apache2/mods-available/${mod}.load" ]]; then
        sudo a2enmod "$mod" >/dev/null
        log "Enabled module: $mod"
    else
        log "Module not available on this host: $mod"
    fi
}

show_status() {
    need_cmd apachectl

    log "Apache module status (headers/expires/deflate/brotli):"
    apachectl -M 2>/dev/null | grep -E 'headers_module|expires_module|deflate_module|brotli_module' || true

    log ""
    log "Config status:"
    if [[ -L "/etc/apache2/conf-enabled/${CONF_NAME}.conf" ]]; then
        log "- ${CONF_NAME}.conf is enabled"
    else
        log "- ${CONF_NAME}.conf is disabled"
    fi

    if [[ -f "$CONF_PATH" ]]; then
        log ""
        log "Current ${CONF_NAME}.conf:"
        sed -n '1,200p' "$CONF_PATH"
    fi
}

apply_profile() {
    need_cmd sudo
    need_cmd apachectl
    need_cmd systemctl

    enable_module_if_available headers
    enable_module_if_available expires
    enable_module_if_available deflate
    enable_module_if_available brotli

    sudo tee "$CONF_PATH" >/dev/null <<'EOF'
# mod_apex web asset performance profile.
# Safe defaults for common PHP apps (WordPress, Laravel, Symfony, Drupal).

<IfModule mod_expires.c>
    ExpiresActive On

    # Aggressive cache for static assets.
    ExpiresByType text/css "access plus 1 year"
    ExpiresByType application/javascript "access plus 1 year"
    ExpiresByType text/javascript "access plus 1 year"
    ExpiresByType image/svg+xml "access plus 1 year"
    ExpiresByType image/x-icon "access plus 1 year"
    ExpiresByType image/vnd.microsoft.icon "access plus 1 year"
    ExpiresByType image/png "access plus 1 year"
    ExpiresByType image/jpeg "access plus 1 year"
    ExpiresByType image/gif "access plus 1 year"
    ExpiresByType image/webp "access plus 1 year"
    ExpiresByType font/woff2 "access plus 1 year"
    ExpiresByType font/woff "access plus 1 year"

    # Keep dynamic responses fresh.
    ExpiresByType text/html "access plus 0 seconds"
    ExpiresByType application/json "access plus 0 seconds"
</IfModule>

<IfModule mod_headers.c>
    <FilesMatch "\.(css|js|svg|ico|png|jpe?g|gif|webp|woff2?|map)$">
        Header set Cache-Control "public, max-age=31536000, immutable"
    </FilesMatch>

    <FilesMatch "\.(php|html?)$">
        Header set Cache-Control "no-store, no-cache, must-revalidate"
    </FilesMatch>

    Header append Vary "Accept-Encoding"
</IfModule>

<IfModule mod_brotli.c>
    BrotliCompressionQuality 5
    AddOutputFilterByType BROTLI_COMPRESS text/plain text/html text/css text/javascript application/javascript application/json application/xml image/svg+xml
</IfModule>

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/plain text/html text/css text/javascript application/javascript application/json application/xml image/svg+xml
</IfModule>
EOF

    sudo a2enconf "$CONF_NAME" >/dev/null
    sudo apachectl -t
    sudo systemctl restart apache2

    log "Applied asset performance profile: $CONF_PATH"
    show_status
}

remove_profile() {
    need_cmd sudo
    need_cmd apachectl
    need_cmd systemctl

    if [[ -L "/etc/apache2/conf-enabled/${CONF_NAME}.conf" ]]; then
        sudo a2disconf "$CONF_NAME" >/dev/null
    fi

    sudo apachectl -t
    sudo systemctl restart apache2

    log "Disabled asset performance profile (${CONF_NAME})."
    show_status
}

case "$MODE" in
    status)
        show_status
        ;;
    apply)
        apply_profile
        ;;
    remove)
        remove_profile
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        log "Unknown mode: $MODE"
        usage
        exit 2
        ;;
esac
