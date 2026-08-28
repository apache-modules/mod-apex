#!/usr/bin/env bash
set -euo pipefail

# Builds mod_apex.rpm and/or php-zts-full.rpm for Fedora using rpmbuild.
# Must be run on Fedora (or in a Fedora container: `docker run --rm -v
# "$PWD":/src fedora:latest bash -c 'cd /src && dnf install -y rpm-build &&
# ./tools/build_rpm.sh'`) so the BuildRequires (openssl-devel, httpd-devel,
# etc.) can actually be resolved and installed by dnf; this script does not
# install them itself.
#
# Usage:
#   ./tools/build_rpm.sh php-zts-full   # build only the PHP runtime RPM
#   ./tools/build_rpm.sh mod_apex       # build only the mod_apex RPM
#   ./tools/build_rpm.sh                # build both (php-zts-full first)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHP_VERSION="${PHP_VERSION:-8.4.21}"
MOD_APEX_VERSION="${MOD_APEX_VERSION:-0.1.7}"
TOPDIR="${TOPDIR:-$REPO_ROOT/dist/rpmbuild}"
TARGETS="${1:-all}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1 (install the 'rpm-build' package)" >&2
        exit 2
    fi
}
require_cmd rpmbuild
require_cmd tar

mkdir -p "$TOPDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

build_php_zts_full() {
    echo "==> Packaging packaging/ sources for php-zts-full.spec"
    local stage name
    name="php-zts-full-${PHP_VERSION}"
    stage="$(mktemp -d)"
    mkdir -p "$stage/$name/packaging"
    cp "$REPO_ROOT/packaging/build-php-zts.sh" "$stage/$name/packaging/"
    cp -r "$REPO_ROOT/packaging/php-ini" "$stage/$name/packaging/"
    cp "$REPO_ROOT/packaging/licenses/PHP-3.01.txt" "$stage/$name/"
    tar -C "$stage" -czf "$TOPDIR/SOURCES/${name}.tar.gz" "$name"
    rm -rf "$stage"
    cp "$REPO_ROOT/packaging/rpm/php-zts-full.spec" "$TOPDIR/SPECS/"

    echo "==> Building php-zts-full RPM (PHP_VERSION=$PHP_VERSION)"
    rpmbuild --define "_topdir $TOPDIR" \
        --define "php_version $PHP_VERSION" \
        -bb "$TOPDIR/SPECS/php-zts-full.spec"
}

build_mod_apex() {
    echo "==> Packaging repo sources for mod_apex.spec"
    local stage name
    name="mod_apex-${MOD_APEX_VERSION}"
    stage="$(mktemp -d)"
    mkdir -p "$stage/$name/packaging/rpm" "$stage/$name/docker" "$stage/$name/tools"
    cp "$REPO_ROOT/mod_apex.c" "$REPO_ROOT/build-install.sh" \
        "$REPO_ROOT/LICENSE" "$REPO_ROOT/NOTICE" "$stage/$name/"
    cp "$REPO_ROOT/packaging/rpm/apex.load" "$stage/$name/packaging/rpm/"
    cp "$REPO_ROOT/docker/apex.conf" "$stage/$name/docker/"
    cp "$REPO_ROOT/tools/apache_mode.sh" "$stage/$name/tools/"
    tar -C "$stage" -czf "$TOPDIR/SOURCES/${name}.tar.gz" "$name"
    rm -rf "$stage"
    cp "$REPO_ROOT/packaging/rpm/mod_apex.spec" "$TOPDIR/SPECS/"

    echo "==> Building mod_apex RPM (MOD_APEX_VERSION=$MOD_APEX_VERSION)"
    rpmbuild --define "_topdir $TOPDIR" \
        --define "mod_apex_version $MOD_APEX_VERSION" \
        -bb "$TOPDIR/SPECS/mod_apex.spec"
}

install_built_php_zts() {
    local php_rpm

    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Building both RPMs requires root so the freshly built php-zts-full RPM can be installed for the mod_apex build." >&2
        echo "Run this command in the documented Fedora container, or build php-zts-full and install it before building mod_apex." >&2
        exit 1
    fi

    require_cmd dnf
    php_rpm="$(find "$TOPDIR/RPMS" -type f -name "php-zts-full-${PHP_VERSION}-*.rpm" ! -name '*debuginfo*' ! -name '*debugsource*' -print -quit)"
    if [[ -z "$php_rpm" ]]; then
        echo "Built php-zts-full RPM not found under $TOPDIR/RPMS" >&2
        exit 1
    fi

    echo "==> Installing the freshly built php-zts-full RPM for the mod_apex build"
    dnf -y install "$php_rpm"
}

case "$TARGETS" in
    php-zts-full) build_php_zts_full ;;
    mod_apex) build_mod_apex ;;
    all) build_php_zts_full; install_built_php_zts; build_mod_apex ;;
    *) echo "Usage: $0 [php-zts-full|mod_apex]" >&2; exit 2 ;;
esac

echo "==> RPMs written under $TOPDIR/RPMS/"
find "$TOPDIR/RPMS" -name '*.rpm'
