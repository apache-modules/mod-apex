#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$repo_root/Dockerfile"
docker_conf="$repo_root/docker/security-hardening.conf"
example_conf="$repo_root/httpd.conf"

assert_line() {
    local file=$1
    local expected=$2
    grep -Fqx "$expected" "$file" || {
        printf 'FAIL: %s does not contain: %s\n' "$file" "$expected" >&2
        exit 1
    }
}

grep -Eq 'a2enmod ([^#]* )?headers([[:space:]]|$)' "$dockerfile" || {
    echo 'FAIL: Docker image does not enable mod_headers' >&2
    exit 1
}

for conf in "$docker_conf" "$example_conf"; do
    assert_line "$conf" '    Header onsuccess unset X-Content-Type-Options'
    assert_line "$conf" '    Header always set X-Content-Type-Options "nosniff"'
    assert_line "$conf" '    Header onsuccess unset Referrer-Policy'
    assert_line "$conf" '    Header always set Referrer-Policy "strict-origin-when-cross-origin"'
    assert_line "$conf" '    Header onsuccess unset X-Powered-By'
    assert_line "$conf" '    Header always unset X-Powered-By'
done

printf 'security header tests: PASS\n'
