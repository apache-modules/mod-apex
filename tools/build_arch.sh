#!/usr/bin/env bash
set -euo pipefail

# Build private Arch artifacts from this checkout. This is intentionally not an
# AUR publisher: the project's current license does not permit redistribution.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
php_version="${PHP_VERSION:-8.4.21}"
mod_apex_version="${MOD_APEX_VERSION:-0.1.7}"
out_dir="${OUT_DIR:-$repo_root/dist/arch}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command not found: $1" >&2
        exit 2
    fi
}

if [[ ! -f /etc/arch-release ]]; then
    echo "error: run this helper in an Arch Linux build environment" >&2
    exit 2
fi

for command in makepkg tar sha256sum; do
    require_command "$command"
done

if [[ "$(id -u)" -eq 0 ]]; then
    echo "error: makepkg must run as an unprivileged user" >&2
    exit 2
fi

mkdir -p "$out_dir"
build_root="$(mktemp -d "$out_dir/.build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT

build_php_package() {
    local name="php-zts-full-${php_version}"
    local work_dir="$build_root/php-zts-full"

    mkdir -p "$work_dir"
    tar -C "$repo_root" -czf "$work_dir/${name}.tar.gz" \
        --transform "s,^,${name}/," \
        LICENSE packaging/build-php-zts.sh packaging/php-ini
    sed "s/^pkgver=.*/pkgver=${php_version}/" \
        "$repo_root/packaging/arch/PKGBUILD.php-zts-full" > "$work_dir/PKGBUILD"

    (
        cd "$work_dir"
        makepkg --syncdeps --cleanbuild --noconfirm >&2
    )

    find "$work_dir" -maxdepth 1 -type f -name 'php-zts-full-*.pkg.tar.zst' \
        -print -quit
}

build_module_package() {
    local php_package="$1"
    local name="mod-apex-${mod_apex_version}"
    local work_dir="$build_root/mod-apex"

    mkdir -p "$work_dir"
    tar -C "$repo_root" -czf "$work_dir/${name}.tar.gz" \
        --transform "s,^,${name}/," \
        LICENSE mod_apex.c build-install.sh packaging/arch/10-mod_apex.conf \
        packaging/arch/mod_apex.conf
    cp "$php_package" "$work_dir/php-zts-full.pkg.tar.zst"
    sed "s/^pkgver=.*/pkgver=${mod_apex_version}/" \
        "$repo_root/packaging/arch/PKGBUILD.mod-apex" > "$work_dir/PKGBUILD"

    (
        cd "$work_dir"
        makepkg --cleanbuild --noconfirm --nodeps >&2
    )

    find "$work_dir" -maxdepth 1 -type f -name 'mod-apex-*.pkg.tar.zst' \
        -print -quit
}

echo "==> Building php-zts-full ${php_version}"
php_package="$(build_php_package)"
echo "==> Building mod-apex ${mod_apex_version}"
module_package="$(build_module_package "$php_package")"

install -m 0644 "$php_package" "$out_dir/"
install -m 0644 "$module_package" "$out_dir/"
printf 'Built package: %s\n' "$out_dir/$(basename "$php_package")"
printf 'Built package: %s\n' "$out_dir/$(basename "$module_package")"
printf 'Install both matching files with: sudo pacman -U %s %s\n' \
    "$out_dir/$(basename "$php_package")" "$out_dir/$(basename "$module_package")"
