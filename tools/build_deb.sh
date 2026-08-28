#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_ROOT="$REPO_ROOT/packaging/deb"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
VERSION="${VERSION:-0.1.7}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
PKG_NAME="mod-apex"
PKG_DIR="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}"
PHP_PREFIX="${PHP_PREFIX:-/usr/local/php-zts}"
PHP_CONFIG="${PHP_CONFIG:-$PHP_PREFIX/bin/php-config}"
PHP_ZTS_VERSION=""

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 2
    fi
}

require_cmd dpkg-deb
require_cmd dpkg
require_cmd install

if [[ ! -x "$PHP_CONFIG" ]] && ! command -v "$PHP_CONFIG" >/dev/null 2>&1; then
    if command -v php-config >/dev/null 2>&1; then
        PHP_CONFIG="php-config"
    else
        echo "php-config not found. Set PHP_CONFIG=/path/to/php-config" >&2
        exit 2
    fi
fi

detect_libphp_path() {
    local php_config_path="$1"
    local prefix_candidate
    local libphp_path
    local ldflags
    local token
    local libdir

    prefix_candidate="$($php_config_path --prefix 2>/dev/null || true)"
    if [[ -n "$prefix_candidate" ]]; then
        libphp_path="$prefix_candidate/lib/libphp.so"
        if [[ -f "$libphp_path" ]]; then
            echo "$libphp_path"
            return 0
        fi
    fi

    ldflags="$($php_config_path --ldflags 2>/dev/null || true)"
    for token in $ldflags; do
        if [[ "$token" == -L* ]]; then
            libdir="${token#-L}"
            libphp_path="$libdir/libphp.so"
            if [[ -f "$libphp_path" ]]; then
                echo "$libphp_path"
                return 0
            fi
        fi
    done

    return 1
}

require_php_embed_zts() {
    local php_config_path="$1"
    local configure_options

    configure_options="$($php_config_path --configure-options 2>/dev/null || true)"
    if [[ -z "$configure_options" ]]; then
        echo "Unable to read PHP configure options from $php_config_path" >&2
        exit 1
    fi

    if [[ "$configure_options" != *"--enable-embed"* ]]; then
        echo "PHP from $php_config_path is missing --enable-embed" >&2
        echo "Build/package against a PHP embed build." >&2
        exit 1
    fi

    if [[ "$configure_options" != *"--enable-zts"* && "$configure_options" != *"--enable-maintainer-zts"* ]]; then
        echo "PHP from $php_config_path is missing ZTS (--enable-zts or --enable-maintainer-zts)" >&2
        echo "Build/package against a ZTS PHP build." >&2
        exit 1
    fi
}

require_php_embed_zts "$PHP_CONFIG"

PHP_ZTS_VERSION="$($PHP_CONFIG --version 2>/dev/null || true)"
if [[ -z "$PHP_ZTS_VERSION" ]]; then
    echo "Unable to read the PHP version from $PHP_CONFIG" >&2
    exit 1
fi

if ! LIBPHP_PATH="$(detect_libphp_path "$PHP_CONFIG")"; then
    echo "Could not locate libphp.so from $PHP_CONFIG." >&2
    echo "Ensure PHP embed/ZTS is installed, or set PHP_CONFIG to the correct binary." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$PKG_DIR"

if [[ ! -f "$REPO_ROOT/.libs/mod_apex.so" ]]; then
    echo "mod_apex artifact not found, building first..."
    (cd "$REPO_ROOT" && ./build-install.sh)
fi

if [[ ! -f "$REPO_ROOT/.libs/mod_apex.so" ]]; then
    echo "Build failed: .libs/mod_apex.so missing" >&2
    exit 1
fi

# Filesystem layout
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/lib/apache2/modules"
mkdir -p "$PKG_DIR/etc/apache2/mods-available"
mkdir -p "$PKG_DIR/usr/share/doc/$PKG_NAME"

# Binary/module + Apache module loader config
install -m 0644 "$REPO_ROOT/.libs/mod_apex.so" "$PKG_DIR/usr/lib/apache2/modules/mod_apex.so"
sed -E "s#^LoadFile[[:space:]]+.*#LoadFile $LIBPHP_PATH#" \
    "$PKG_ROOT/apex.load" > "$PKG_DIR/etc/apache2/mods-available/apex.load"
chmod 0644 "$PKG_DIR/etc/apache2/mods-available/apex.load"

# Docs
install -m 0644 "$REPO_ROOT/README.md" "$PKG_DIR/usr/share/doc/$PKG_NAME/README.md"
if [[ -f "$REPO_ROOT/LICENSE" ]]; then
    install -m 0644 "$REPO_ROOT/LICENSE" "$PKG_DIR/usr/share/doc/$PKG_NAME/LICENSE"
fi
if [[ -f "$PKG_ROOT/copyright" ]]; then
    install -m 0644 "$PKG_ROOT/copyright" "$PKG_DIR/usr/share/doc/$PKG_NAME/copyright"
fi

# DEBIAN metadata/scripts with version/arch substitution
sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@ARCH@/$ARCH/g" \
  -e "s/@PHP_ZTS_VERSION@/$PHP_ZTS_VERSION/g" \
  "$PKG_ROOT/control" > "$PKG_DIR/DEBIAN/control"

install -m 0755 "$PKG_ROOT/postinst" "$PKG_DIR/DEBIAN/postinst"
install -m 0755 "$PKG_ROOT/prerm" "$PKG_DIR/DEBIAN/prerm"

# Build package
DEB_PATH="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"
rm -f "$DEB_PATH"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB_PATH"

echo "Built package: $DEB_PATH"
echo "Install with: sudo dpkg -i $DEB_PATH"
echo "If dependencies are missing: sudo apt-get -f install"
echo "Packaged LoadFile path: $LIBPHP_PATH"
