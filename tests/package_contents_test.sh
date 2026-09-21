#!/usr/bin/env bash
set -euo pipefail

package_type="${1:-}"
package_path="${2:-}"

if [[ -z "$package_type" || -z "$package_path" ]]; then
    echo "Usage: $0 deb|deb-php|rpm|arch PACKAGE" >&2
    exit 2
fi
if [[ ! -f "$package_path" ]]; then
    echo "Package not found: $package_path" >&2
    exit 2
fi

case "$package_type" in
    deb)
        listing="$(dpkg-deb -c "$package_path")"
        grep -Eq '^-rwxr-xr-x .*\./usr/local/sbin/php-apex-mode$' <<<"$listing"
        grep -Eq '\./etc/apache2/mods-available/apex\.conf$' <<<"$listing"
        grep -Eq '\./etc/apache2/conf-available/php-apex-performance.conf$' <<<"$listing"
        grep -Eq '\./etc/apache2/conf-available/php-apex-security.conf$' <<<"$listing"
        grep -Eq '\./usr/local/lib/php-apex/apex-sizing.sh$' <<<"$listing"
        ;;
    deb-php)
        listing="$(dpkg-deb -c "$package_path")"
        depends="$(dpkg-deb -f "$package_path" Depends)"
        grep -Eq '\./usr/local/php-zts/bin/php$' <<<"$listing"
        grep -Eq '\./usr/local/php-zts/lib/libphp\.so$' <<<"$listing"
        grep -Eq '\./usr/local/php-zts/lib/php/extensions/.*/imagick\.so$' <<<"$listing"
        grep -Eq '(^|, )libgomp[0-9]+([ ,]|$)' <<<"$depends"
        grep -Eq '(^|, )libmagick(wand|core)[^, ]*([ ,]|$)' <<<"${depends,,}"
        ;;
    rpm)
        listing="$(rpm -qplv "$package_path")"
        grep -Eq '^-rwxr-xr-x .* /usr/local/sbin/php-apex-mode$' <<<"$listing"
        grep -Eq ' /etc/httpd/conf.d/php-apex-performance.conf$' <<<"$listing"
        grep -Eq ' /etc/httpd/conf.d/php-apex-security.conf$' <<<"$listing"
        grep -Eq ' /usr/local/lib/php-apex/apex-sizing.sh$' <<<"$listing"
        ;;
    arch)
        listing="$(bsdtar -tvf "$package_path")"
        grep -Eq '^-rwxr-xr-x .* usr/local/sbin/php-apex-mode$' <<<"$listing"
        grep -Eq ' etc/httpd/conf/conf.d/php-apex-performance.conf$' <<<"$listing"
        grep -Eq ' etc/httpd/conf/conf.d/php-apex-security.conf$' <<<"$listing"
        grep -Eq ' usr/local/lib/php-apex/apex-sizing.sh$' <<<"$listing"
        ;;
    *)
        echo "Unknown package type: $package_type" >&2
        exit 2
        ;;
esac

printf '%s package command: PASS\n' "$package_type"
