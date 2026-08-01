#!/usr/bin/env bash
set -euo pipefail

# Builds the php-zts-full .deb: a self-contained PHP (ZTS + embed SAPI,
# OPcache + JIT, WordPress/Drupal/Symfony extension set) runtime, using the
# shared packaging/build-php-zts.sh script staged via DESTDIR.
#
# Must be run as root (or via sudo): build-php-zts.sh installs PHP + its
# PECL extensions for real to /usr/local/php-zts during the build (phpize/
# php-config need it to exist there, not just staged under a scratch
# DESTDIR), then copies the finished tree into the .deb payload afterward.
#
# Run this INSIDE a container/chroot of the actual target distro+release
# (e.g. debian:bookworm, debian:trixie, ubuntu:jammy, ubuntu:noble) so the
# auto-detected runtime library dependencies below match that target -- the
# shared libs PHP links against (openssl, icu, etc.) carry different SONAME
# suffixes across releases (e.g. libicu72 on bookworm vs libicu74 on
# ubuntu:noble), so a package built on one release's dependency list is not
# guaranteed installable on another.
#
# Required build dependencies (install before running this script):
#   apt-get install -y build-essential autoconf automake libtool pkg-config \
#     curl ca-certificates apache2-dev libxml2-dev libssl-dev \
#     libcurl4-openssl-dev zlib1g-dev libsqlite3-dev libonig-dev libicu-dev \
#     libzip-dev libxslt1-dev libfreetype6-dev libjpeg62-turbo-dev \
#     libwebp-dev libpng-dev libsodium-dev libgmp-dev libmagickwand-dev \
#     dpkg-dev

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_ROOT="$REPO_ROOT/packaging/deb-php-zts"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
PHP_VERSION="${PHP_VERSION:-8.4.21}"
PKG_REVISION="${PKG_REVISION:-1}"
VERSION="${VERSION:-${PHP_VERSION}-${PKG_REVISION}}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
PKG_NAME="php-zts-full"
PKG_DIR="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 2
    fi
}

require_cmd dpkg-deb
require_cmd dpkg
require_cmd ldd

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: must be run as root (or via sudo) -- PHP + PECL extensions" >&2
    echo "are installed for real to /usr/local/php-zts during the build." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN" "$PKG_DIR/usr/share/doc/$PKG_NAME"

echo "Building PHP $PHP_VERSION into staged root $PKG_DIR ..."
PREFIX=/usr/local/php-zts \
DESTDIR="$PKG_DIR" \
PHP_VERSION="$PHP_VERSION" \
SRC_DIR="${SRC_DIR:-$OUT_DIR/src}" \
    "$REPO_ROOT/packaging/build-php-zts.sh"

STAGE_PREFIX="$PKG_DIR/usr/local/php-zts"
if [[ ! -x "$STAGE_PREFIX/bin/php" ]]; then
    echo "Build failed: $STAGE_PREFIX/bin/php missing" >&2
    exit 1
fi

# Auto-derive runtime library Depends from the actual linked shared objects
# (ldd) mapped back to the owning apt package (dpkg -S), rather than a
# hand-typed list -- this is what makes the same script correct on Debian
# 12/13 and Ubuntu 22.04/24.04 as long as it's run inside each target.
echo "Resolving shared library dependencies ..."
mapfile -t so_paths < <(
    ldd "$STAGE_PREFIX/bin/php" "$STAGE_PREFIX/lib/libphp.so" 2>/dev/null \
        | awk '/=>/ {print $3} !/=>/ && /\// {print $1}' \
        | grep -v '^$' \
        | sort -u
)

declare -A seen_pkgs
extra_depends=()
for so in "${so_paths[@]}"; do
    [[ -f "$so" ]] || continue
    # dpkg tracks the resolved real file, not the SONAME symlink ldd reports,
    # so resolve it first; either lookup can legitimately find no owning
    # package (e.g. a lib installed outside apt), which isn't a fatal error.
    real_so="$(realpath -e "$so" 2>/dev/null || echo "$so")"
    pkg="$(dpkg -S "$real_so" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    [[ -z "$pkg" || -n "${seen_pkgs[$pkg]:-}" ]] && continue
    seen_pkgs["$pkg"]=1
    extra_depends+=("$pkg")
done

if [[ ${#extra_depends[@]} -eq 0 ]]; then
    echo "warning: could not auto-detect any runtime library packages via dpkg -S" >&2
    EXTRA_DEPENDS_LINE="libc6, libssl3, zlib1g, libxml2"
else
    IFS=', '; EXTRA_DEPENDS_LINE="${extra_depends[*]}"; unset IFS
fi
echo "Detected runtime Depends: $EXTRA_DEPENDS_LINE"

sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@ARCH@/$ARCH/g" \
  -e "s/@EXTRA_DEPENDS@/$EXTRA_DEPENDS_LINE/g" \
  "$PKG_ROOT/control" > "$PKG_DIR/DEBIAN/control"

install -m 0755 "$PKG_ROOT/postinst" "$PKG_DIR/DEBIAN/postinst"
install -m 0644 "$PKG_ROOT/copyright" "$PKG_DIR/usr/share/doc/$PKG_NAME/copyright"
if [[ -f "$REPO_ROOT/LICENSE" ]]; then
    install -m 0644 "$REPO_ROOT/LICENSE" "$PKG_DIR/usr/share/doc/$PKG_NAME/LICENSE"
fi

DEB_PATH="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"
rm -f "$DEB_PATH"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB_PATH"

echo "Built package: $DEB_PATH"
echo "Install with: sudo dpkg -i $DEB_PATH && sudo apt-get -f install"
echo "Then build/install the mod-apex package (tools/build_deb.sh) against it."
