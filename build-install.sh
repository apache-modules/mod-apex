#!/usr/bin/env bash
set -euo pipefail

usage() {
           cat <<'EOF'
Usage: ./build-install.sh [options]

Build/install mod_apex as an Apache module using PHP embed (ZTS).

Options:
     -h, --help    Show this help and exit

Environment:
     APXS          Default: apxs
     PHP_PREFIX    Default: /usr/local/php-zts
     PHP_CONFIG    Default: $PHP_PREFIX/bin/php-config
     INSTALL_MODE  auto | always | never (default: auto)

Modes:
     auto    root: install+enable, non-root: build-only
     always  force install+enable (requires root)
     never   build-only

Examples:
     ./build-install.sh
     INSTALL_MODE=never ./build-install.sh
     sudo INSTALL_MODE=always ./build-install.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
           usage
           exit 0
fi

APXS=${APXS:-apxs}
PHP_PREFIX=${PHP_PREFIX:-/usr/local/php-zts}
PHP_CONFIG=${PHP_CONFIG:-$PHP_PREFIX/bin/php-config}
INSTALL_MODE=${INSTALL_MODE:-auto}
PHP_LIB="$PHP_PREFIX/lib/libphp.so"

if ! command -v "$APXS" >/dev/null 2>&1; then
     echo "error: apxs not found: $APXS"
     exit 1
fi

if ! command -v "$PHP_CONFIG" >/dev/null 2>&1; then
     echo "error: php-config not found: $PHP_CONFIG"
     echo "hint: set PHP_PREFIX=/usr/local/php-zts or PHP_CONFIG=/path/to/php-config"
     exit 1
fi

if [[ ! -f "$PHP_LIB" ]]; then
     echo "error: embed library not found: $PHP_LIB"
     exit 1
fi

if [[ "$INSTALL_MODE" != "auto" && "$INSTALL_MODE" != "always" && "$INSTALL_MODE" != "never" ]]; then
     echo "error: INSTALL_MODE must be one of: auto, always, never"
     exit 1
fi

if [[ "$INSTALL_MODE" == "always" && "$EUID" -ne 0 ]]; then
     echo "error: INSTALL_MODE=always requires root privileges"
     echo "hint: run with sudo INSTALL_MODE=always $0"
     exit 1
fi

APXS_ARGS=(
     -Wc,"$($PHP_CONFIG --includes) -I$($PHP_CONFIG --include-dir)/sapi/embed -O2 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security"
     -Wl,"-L$PHP_PREFIX/lib -lphp -Wl,-z,relro -Wl,-z,now"
     mod_apex.c
)

echo "Building mod_apex (PHP embed mode)"

if [[ "$INSTALL_MODE" == "always" || ( "$INSTALL_MODE" == "auto" && "$EUID" -eq 0 ) ]]; then
     echo "Mode: install+enable (-c -i -a)"
     "$APXS" -c -i -a "${APXS_ARGS[@]}"

     # Ensure Apache loads the intended ZTS embed libphp before mod_apex.
     APEX_LOAD_FILE="/etc/apache2/mods-available/apex.load"
     if [[ -f "$APEX_LOAD_FILE" ]]; then
          if ! grep -q "^LoadFile $PHP_LIB$" "$APEX_LOAD_FILE"; then
               tmp_file="$(mktemp)"
               {
                    echo "LoadFile $PHP_LIB"
                    cat "$APEX_LOAD_FILE"
               } > "$tmp_file"
               mv "$tmp_file" "$APEX_LOAD_FILE"
          fi
     fi

     echo "Install complete. Verify module load with: apache2ctl -M | grep apex"
     echo "Then reload Apache: sudo systemctl reload apache2"
else
     echo "Mode: build-only (-c)"
     "$APXS" -c "${APXS_ARGS[@]}"
     echo "Built artifact: .libs/mod_apex.so"
     echo "To install+enable, run: sudo INSTALL_MODE=always $0"
fi