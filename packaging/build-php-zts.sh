#!/usr/bin/env bash
set -euo pipefail

# Shared PHP (ZTS + embed SAPI) build used by the Docker image, the Debian/
# Ubuntu "php-zts-full" package, and the Fedora RPM equivalent -- single
# source of truth for configure flags and the extension set required by
# WordPress, Drupal, and Symfony, so the three packaging paths don't drift.
#
# System build dependencies (compiler, apxs headers, -dev libs for each
# extension below) are NOT installed by this script; the caller (Dockerfile,
# tools/build_php_zts_deb.sh, packaging/rpm/php-zts-full.spec) is expected to
# install them first via the platform package manager.

usage() {
    cat <<'EOF'
Usage: ./packaging/build-php-zts.sh

Builds PHP (ZTS + embed SAPI, OPcache + JIT, and the extensions required by
WordPress/Drupal/Symfony) plus the APCu/Redis/Imagick PECL extensions, and
installs the result under PREFIX.

Environment:
  PREFIX          Install prefix (default: /usr/local/php-zts)
  DESTDIR         Staged install root prepended to PREFIX, for packaging
                  (default: empty -- installs directly to PREFIX)
  PACKAGE_BUILD_ROOT
                  Temporary physical install root for unprivileged package
                  builds. PHP still keeps PREFIX as its final runtime path.
  PHP_VERSION     PHP release to build (default: 8.4.21)
  APCU_VERSION    APCu PECL release (default: 5.1.24)
  REDIS_VERSION   phpredis PECL release (default: 6.1.0)
  IMAGICK_VERSION imagick PECL release (default: 3.8.1)
  SRC_DIR         Scratch/build directory (default: /usr/src -- must be
                  writable by the invoking user; the Docker build runs this
                  as root so the default works there, but tools/build_rpm.sh
                  and tools/build_php_zts_deb.sh point this at a writable
                  location under their own output directory instead)
  JOBS            Parallel make jobs (default: nproc)

Examples:
  ./packaging/build-php-zts.sh
  DESTDIR=/tmp/stage ./packaging/build-php-zts.sh
  PACKAGE_BUILD_ROOT=/tmp/package-root ./packaging/build-php-zts.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

PREFIX="${PREFIX:-/usr/local/php-zts}"
DESTDIR="${DESTDIR:-}"
PACKAGE_BUILD_ROOT="${PACKAGE_BUILD_ROOT:-}"
PHP_VERSION="${PHP_VERSION:-8.4.21}"
APCU_VERSION="${APCU_VERSION:-5.1.24}"
REDIS_VERSION="${REDIS_VERSION:-6.1.0}"
IMAGICK_VERSION="${IMAGICK_VERSION:-3.8.1}"
SRC_DIR="${SRC_DIR:-/usr/src}"
JOBS="${JOBS:-$(nproc)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INI_DIR="$SCRIPT_DIR/php-ini"

if [[ -n "$PACKAGE_BUILD_ROOT" && "$PACKAGE_BUILD_ROOT" != /* ]]; then
    echo "error: PACKAGE_BUILD_ROOT must be an absolute path" >&2
    exit 1
fi

physical_prefix() {
    if [[ -n "$PACKAGE_BUILD_ROOT" ]]; then
        printf '%s%s' "$PACKAGE_BUILD_ROOT" "$PREFIX"
    else
        printf '%s' "$PREFIX"
    fi
}

PHYSICAL_PREFIX="$(physical_prefix)"

for cmd in curl tar make gcc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: required command not found: $cmd" >&2
        exit 1
    fi
done

# PHP (and its PECL extensions) always get installed for real to $PREFIX
# during the build -- see the stage_root() comment below for why. Fail fast
# with an actionable message instead of a confusing mid-build permission
# error if that isn't writable (typically means: run this as root/sudo, or
# in a container/chroot, when PREFIX lives under /usr or /usr/local).
mkdir -p "$(dirname "$PHYSICAL_PREFIX")" 2>/dev/null || true
if [[ ! -w "$(dirname "$PHYSICAL_PREFIX")" ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo "error: $(dirname "$PHYSICAL_PREFIX") is not writable by $(id -un)." >&2
    echo "PHP + PECL extensions must be installed for real to \$PREFIX during the" >&2
    echo "build (phpize/php-config need it to exist there, not just under \$DESTDIR)." >&2
    echo "Re-run as root/sudo, or in a container/chroot." >&2
    exit 1
fi

# PHP is always installed for real to $PREFIX (not staged under $DESTDIR)
# during the build, because phpize/php-config resolve their paths (extension
# dir, lib/php/build, etc.) from the --prefix compiled into php-config, not
# from any DESTDIR override -- so PECL extensions below can't build against
# a DESTDIR-only install. When DESTDIR is set (packaging use), the finished
# $PREFIX tree is copied into $DESTDIR$PREFIX at the very end instead.
stage_root() {
    printf '%s' "${DESTDIR}${PREFIX}"
}

echo "==> Building PHP $PHP_VERSION (ZTS + embed) into $PREFIX"

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"
if [[ ! -d "php-${PHP_VERSION}" ]]; then
    curl -fsSL "https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz" -o php.tar.gz
    tar xzf php.tar.gz
    rm php.tar.gz
fi

cd "php-${PHP_VERSION}"

# Extension set covers WordPress, Drupal, and Symfony's required/recommended
# PHP extensions: ctype/filter/hash/json/session/tokenizer/SimpleXML/dom/xml
# are core-bundled and always on; the flags below add everything else those
# three projects need (curl, mbstring, openssl, PDO+mysqli+sqlite3, zip,
# intl, gd, bcmath, soap, xsl, exif, sodium, gmp) plus OPcache/JIT.
./configure \
    --prefix="$PREFIX" \
    --enable-zts \
    --enable-embed \
    --enable-opcache \
    --enable-mbstring \
    --with-curl \
    --with-openssl \
    --with-zlib \
    --with-sqlite3 \
    --enable-pdo \
    --with-pdo-sqlite \
    --with-pdo-mysql \
    --with-mysqli \
    --disable-cgi \
    --disable-phpdbg \
    --with-config-file-path="$PREFIX/etc" \
    --with-config-file-scan-dir="$PREFIX/etc/conf.d" \
    --enable-exif \
    --enable-intl \
    --with-zip \
    --enable-bcmath \
    --enable-soap \
    --with-xsl \
    --enable-gd \
    --with-freetype \
    --with-jpeg \
    --with-webp \
    --with-sodium \
    --with-gmp

make -j"$JOBS"
if [[ -n "$PACKAGE_BUILD_ROOT" ]]; then
    # PHP's generated Makefile stages with INSTALL_ROOT, not DESTDIR.
    make install INSTALL_ROOT="$PACKAGE_BUILD_ROOT"
else
    make install
fi

mkdir -p "$PHYSICAL_PREFIX/etc/conf.d"
cp php.ini-production "$PHYSICAL_PREFIX/etc/php.ini"
cp "$INI_DIR/opcache.ini" "$PHYSICAL_PREFIX/etc/conf.d/10-opcache.ini"

PHP_CONFIG="$PHYSICAL_PREFIX/bin/php-config"
PHPIZE="$PHYSICAL_PREFIX/bin/phpize"

# php-config and phpize embed the final PREFIX. During an unprivileged package
# build those final paths do not exist yet, so use private, temporary copies
# that point at the staged tree only while compiling PECL extensions. The
# installed scripts remain untouched and continue to advertise PREFIX.
if [[ -n "$PACKAGE_BUILD_ROOT" ]]; then
    TOOL_DIR="$SRC_DIR/.php-zts-package-tools"
    mkdir -p "$TOOL_DIR"
    cp "$PHP_CONFIG" "$TOOL_DIR/php-config"
    cp "$PHPIZE" "$TOOL_DIR/phpize"
    sed -i "s#${PREFIX}#${PHYSICAL_PREFIX}#g" \
        "$TOOL_DIR/php-config" "$TOOL_DIR/phpize"
    chmod +x "$TOOL_DIR/php-config" "$TOOL_DIR/phpize"
    PHP_CONFIG="$TOOL_DIR/php-config"
    PHPIZE="$TOOL_DIR/phpize"
fi

build_pecl_extension() {
    local name="$1" version="$2" ini_file="$3" ini_priority="$4"

    echo "==> Building PECL extension: $name $version"
    cd "$SRC_DIR"
    if [[ ! -d "${name}-${version}" ]]; then
        curl -fsSL "https://pecl.php.net/get/${name}-${version}.tgz" -o "${name}.tgz"
        tar xzf "${name}.tgz"
        rm "${name}.tgz"
    fi
    cd "${name}-${version}"
    "$PHPIZE"
    ./configure --with-php-config="$PHP_CONFIG"
    make -j"$JOBS"
    make install
    cp "$INI_DIR/$ini_file" "$PHYSICAL_PREFIX/etc/conf.d/${ini_priority}-${ini_file}"
}

# APCu: user-space object/data cache, used by all three target frameworks'
# caching layers (see /memories/repo notes on the WordPress APCu drop-in).
build_pecl_extension "apcu" "$APCU_VERSION" "apcu.ini" "20"

# phpredis: common cache/session backend for WordPress, Drupal, and Symfony.
build_pecl_extension "redis" "$REDIS_VERSION" "redis.ini" "21"

# imagick: advanced image handling used by WordPress/Drupal image styles
# beyond what GD covers. Requires ImageMagick's MagickWand dev headers
# (libmagickwand-dev on Debian/Ubuntu, ImageMagick-devel on Fedora) to be
# installed by the caller before this script runs.
build_pecl_extension "imagick" "$IMAGICK_VERSION" "imagick.ini" "22"

if [[ -n "$DESTDIR" ]]; then
    echo "==> Staging $PREFIX into $(stage_root)"
    mkdir -p "$(stage_root)"
    cp -a "$PHYSICAL_PREFIX/." "$(stage_root)/"
fi

echo "==> PHP ZTS build complete: $(stage_root)"
if [[ -z "$DESTDIR" && -z "$PACKAGE_BUILD_ROOT" ]]; then
    "$PREFIX/bin/php" -v
    "$PREFIX/bin/php" -m
fi
