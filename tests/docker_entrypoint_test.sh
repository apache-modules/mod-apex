#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
entrypoint="$repo_root/docker/docker-entrypoint.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

run_entrypoint() {
    local name=$1
    shift

    env \
        APEX_RUNTIME_CONF="$test_root/$name/apache.conf" \
        APEX_OPCACHE_CONF="$test_root/$name/opcache.ini" \
        APEX_TEST_PAGE_SOURCE="$repo_root/test.php" \
        APEX_TEST_PAGE_TARGET="$test_root/$name/html/test.php" \
        "$@" \
        "$entrypoint" /bin/true
}

run_entrypoint default
grep -Fx 'opcache.validate_timestamps=0' "$test_root/default/opcache.ini"
grep -Fx 'expose_php=Off' "$test_root/default/opcache.ini"
grep -Fx 'session.cookie_httponly=1' "$test_root/default/opcache.ini"
grep -Fx 'session.cookie_samesite=Lax' "$test_root/default/opcache.ini"
grep -Fx 'allow_url_fopen=1' "$test_root/default/opcache.ini"
grep -Fx 'disable_functions=' "$test_root/default/opcache.ini"
grep -Fx '    MaxConnectionsPerChild 1000' "$test_root/default/apache.conf"
if grep -Fq 'RemoteIPHeader' "$test_root/default/apache.conf"; then
    echo 'remote IP handling must remain disabled without APEX_TRUSTED_PROXY' >&2
    exit 1
fi
test ! -e "$test_root/default/html/test.php"

run_entrypoint writable APEX_OPCACHE_VALIDATE=1
grep -Fx 'opcache.validate_timestamps=1' "$test_root/writable/opcache.ini"

run_entrypoint immutable APEX_OPCACHE_VALIDATE=0
grep -Fx 'opcache.validate_timestamps=0' "$test_root/immutable/opcache.ini"

run_entrypoint hardened \
    APEX_ALLOW_URL_FOPEN=0 \
    APEX_DISABLE_FUNCTIONS=exec,passthru,shell_exec,system,proc_open,popen
grep -Fx 'allow_url_fopen=0' "$test_root/hardened/opcache.ini"
grep -Fx 'disable_functions=exec,passthru,shell_exec,system,proc_open,popen' \
    "$test_root/hardened/opcache.ini"

run_entrypoint test-page APEX_ENABLE_TEST_PAGE=1
cmp "$repo_root/test.php" "$test_root/test-page/html/test.php"

run_entrypoint proxy \
    'APEX_TRUSTED_PROXY=10.89.0.0/16 173.245.48.0/20' \
    APEX_MAX_CONNECTIONS_PER_CHILD=10000
grep -Fx '    MaxConnectionsPerChild 10000' "$test_root/proxy/apache.conf"
grep -Fx '    RemoteIPHeader X-Forwarded-For' "$test_root/proxy/apache.conf"
grep -Fx '    RemoteIPTrustedProxy 10.89.0.0/16' "$test_root/proxy/apache.conf"
grep -Fx '    RemoteIPTrustedProxy 173.245.48.0/20' "$test_root/proxy/apache.conf"

if run_entrypoint invalid APEX_OPCACHE_VALIDATE=2 \
    >"$test_root/invalid.stdout" 2>"$test_root/invalid.stderr"; then
    echo 'expected invalid APEX_OPCACHE_VALIDATE to fail' >&2
    exit 1
fi

grep -F 'APEX_OPCACHE_VALIDATE must be 0 or 1' "$test_root/invalid.stderr"
test ! -e "$test_root/invalid/opcache.ini"

if run_entrypoint invalid-url APEX_ALLOW_URL_FOPEN=2 \
    >"$test_root/invalid-url.stdout" 2>"$test_root/invalid-url.stderr"; then
    echo 'expected invalid APEX_ALLOW_URL_FOPEN to fail' >&2
    exit 1
fi
grep -F 'APEX_ALLOW_URL_FOPEN must be 0 or 1' "$test_root/invalid-url.stderr"

if run_entrypoint invalid-test-page APEX_ENABLE_TEST_PAGE=yes \
    >"$test_root/invalid-test-page.stdout" 2>"$test_root/invalid-test-page.stderr"; then
    echo 'expected invalid APEX_ENABLE_TEST_PAGE to fail' >&2
    exit 1
fi
grep -F 'APEX_ENABLE_TEST_PAGE must be 0 or 1' \
    "$test_root/invalid-test-page.stderr"

if run_entrypoint invalid-functions 'APEX_DISABLE_FUNCTIONS=exec,system
auto_prepend_file=/tmp/evil.php' \
    >"$test_root/invalid-functions.stdout" 2>"$test_root/invalid-functions.stderr"; then
    echo 'expected unsafe APEX_DISABLE_FUNCTIONS to fail' >&2
    exit 1
fi
grep -F 'APEX_DISABLE_FUNCTIONS must be a comma-separated list of PHP function names' \
    "$test_root/invalid-functions.stderr"

if run_entrypoint invalid-connections APEX_MAX_CONNECTIONS_PER_CHILD=-1 \
    >"$test_root/invalid-connections.stdout" \
    2>"$test_root/invalid-connections.stderr"; then
    echo 'expected invalid APEX_MAX_CONNECTIONS_PER_CHILD to fail' >&2
    exit 1
fi
grep -F 'APEX_MAX_CONNECTIONS_PER_CHILD must be a whole number from 0 to 1000000' \
    "$test_root/invalid-connections.stderr"

if run_entrypoint huge-connections \
    APEX_MAX_CONNECTIONS_PER_CHILD=999999999999999999999999999999999999 \
    >"$test_root/huge-connections.stdout" \
    2>"$test_root/huge-connections.stderr"; then
    echo 'expected oversized APEX_MAX_CONNECTIONS_PER_CHILD to fail' >&2
    exit 1
fi
grep -F 'APEX_MAX_CONNECTIONS_PER_CHILD must be a whole number from 0 to 1000000' \
    "$test_root/huge-connections.stderr"

if run_entrypoint invalid-proxy 'APEX_TRUSTED_PROXY=10.89.0.0/16
RemoteIPHeader X-Real-IP' \
    >"$test_root/invalid-proxy.stdout" 2>"$test_root/invalid-proxy.stderr"; then
    echo 'expected unsafe APEX_TRUSTED_PROXY to fail' >&2
    exit 1
fi
grep -F 'APEX_TRUSTED_PROXY must contain only space-separated IP addresses or CIDR ranges' \
    "$test_root/invalid-proxy.stderr"

vhost_conf="$repo_root/docker/000-mod-apex.conf"
grep -Fx '        AllowOverride None' "$vhost_conf"
grep -Fx '        AllowOverrideList RewriteEngine RewriteBase RewriteCond RewriteRule' \
    "$vhost_conf"
if grep -Fq 'AllowOverride All' "$vhost_conf"; then
    echo 'container vhost must not allow unrestricted .htaccess directives' >&2
    exit 1
fi
