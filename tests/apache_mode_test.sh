#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command_under_test="$repo_root/tools/apache_mode.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    grep -Fqx "$expected" "$file" || fail "$file does not contain: $expected"
}

make_helpers() {
    local helper_dir="$1"
    mkdir -p "$helper_dir"

    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$helper_dir/apachectl-ok"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$helper_dir/apachectl-fail"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$*" >> "${APEX_TEST_RESTART_LOG}"' > "$helper_dir/systemctl"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$helper_dir/a2enconf"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$helper_dir/a2disconf"
    chmod +x "$helper_dir"/*
}

run_mode() {
    local mode="$1"
    local tuning_conf="$2"
    local helper_dir="$3"
    local apachectl_name="${4:-apachectl-ok}"

    APEX_PLATFORM=debian \
    APEX_TUNING_CONF="$tuning_conf" \
    APEX_CTL="$helper_dir/$apachectl_name" \
    APEX_SYSTEMCTL="$helper_dir/systemctl" \
    APEX_ENABLE_CMD="$helper_dir/a2enconf" \
    APEX_DISABLE_CMD="$helper_dir/a2disconf" \
    APEX_TEST_RESTART_LOG="$fixture_root/restarts.log" \
    APEX_CPU_COUNT="${APEX_TEST_CPU_COUNT:-2}" \
    APEX_MEMORY_MB="${APEX_TEST_MEMORY_MB:-2048}" \
        "$command_under_test" "$mode"
}

helper_dir="$fixture_root/helpers"
make_helpers "$helper_dir"

steady_conf="$fixture_root/steady/php-apex-performance.conf"
mkdir -p "$(dirname "$steady_conf")"
run_mode auto "$steady_conf" "$helper_dir"
assert_contains "$steady_conf" 'KeepAlive Off'
assert_contains "$steady_conf" 'ServerLimit 1'
assert_contains "$steady_conf" 'ThreadLimit 4'
assert_contains "$steady_conf" 'ThreadsPerChild 4'
assert_contains "$steady_conf" 'MaxRequestWorkers 4'
assert_contains "$steady_conf" 'MaxSpareThreads 4'
assert_contains "$steady_conf" 'MaxConnectionsPerChild 0'
assert_contains "$fixture_root/restarts.log" 'restart apache2'

status_output="$(APEX_PLATFORM=debian APEX_TUNING_CONF="$steady_conf" "$command_under_test" status)"
[[ "$status_output" == *'Profile: auto'* ]] || fail 'status does not identify the auto profile'
[[ "$status_output" == *'MaxRequestWorkers 4'* ]] || fail 'status does not show worker count'

host_shape_conf="$fixture_root/host-shape/php-apex-performance.conf"
mkdir -p "$(dirname "$host_shape_conf")"
APEX_TEST_CPU_COUNT=16 APEX_TEST_MEMORY_MB=7531 \
    run_mode auto "$host_shape_conf" "$helper_dir"
assert_contains "$host_shape_conf" 'ThreadsPerChild 32'
assert_contains "$host_shape_conf" 'MaxRequestWorkers 32'

exact_layout_conf="$fixture_root/exact-layout/php-apex-performance.conf"
mkdir -p "$(dirname "$exact_layout_conf")"
APEX_MAX_REQUEST_WORKERS=65 run_mode auto "$exact_layout_conf" "$helper_dir"
assert_contains "$exact_layout_conf" 'ServerLimit 5'
assert_contains "$exact_layout_conf" 'ThreadsPerChild 13'
assert_contains "$exact_layout_conf" 'MaxRequestWorkers 65'

normalized_layout_conf="$fixture_root/normalized-layout/php-apex-performance.conf"
mkdir -p "$(dirname "$normalized_layout_conf")"
APEX_MAX_REQUEST_WORKERS=67 run_mode auto "$normalized_layout_conf" "$helper_dir"
assert_contains "$normalized_layout_conf" 'ServerLimit 2'
assert_contains "$normalized_layout_conf" 'ThreadsPerChild 33'
assert_contains "$normalized_layout_conf" 'MaxRequestWorkers 66'

throughput_conf="$fixture_root/throughput/php-apex-performance.conf"
mkdir -p "$(dirname "$throughput_conf")"
run_mode throughput "$throughput_conf" "$helper_dir"
assert_contains "$throughput_conf" 'KeepAlive On'
assert_contains "$throughput_conf" 'ServerLimit 4'
assert_contains "$throughput_conf" 'MaxRequestWorkers 256'
assert_contains "$throughput_conf" 'MaxConnectionsPerChild 1000'

override_conf="$fixture_root/override/php-apex-performance.conf"
mkdir -p "$(dirname "$override_conf")"
APEX_MAX_REQUEST_WORKERS=512 run_mode throughput "$override_conf" "$helper_dir"
assert_contains "$override_conf" 'ServerLimit 8'
assert_contains "$override_conf" 'MaxRequestWorkers 512'

invalid_conf="$fixture_root/invalid/php-apex-performance.conf"
mkdir -p "$(dirname "$invalid_conf")"
if APEX_MAX_REQUEST_WORKERS=513 run_mode auto "$invalid_conf" "$helper_dir" >/dev/null 2>&1; then
    fail 'auto accepted more than 512 workers'
fi

missing_parent="$fixture_root/missing/php-apex-performance.conf"
if run_mode auto "$missing_parent" "$helper_dir" >/dev/null 2>&1; then
    fail 'auto succeeded with a missing managed configuration directory'
fi
[[ ! -e "$missing_parent" ]] || fail 'steady created a file in a missing managed directory'

rollback_conf="$fixture_root/rollback/php-apex-performance.conf"
mkdir -p "$(dirname "$rollback_conf")"
printf '%s\n' '# existing operator file' > "$rollback_conf"
before="$(cat "$rollback_conf")"
: > "$fixture_root/restarts.log"
if run_mode auto "$rollback_conf" "$helper_dir" apachectl-fail >/dev/null 2>&1; then
    fail 'auto succeeded after Apache syntax validation failed'
fi
after="$(cat "$rollback_conf")"
[[ "$after" == "$before" ]] || fail 'syntax failure did not restore the previous managed file'
[[ ! -s "$fixture_root/restarts.log" ]] || fail 'syntax failure restarted Apache'

printf 'apache_mode tests: PASS\n'
