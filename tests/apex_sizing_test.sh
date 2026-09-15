#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../packaging/apex-sizing.sh
source "$repo_root/packaging/apex-sizing.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_sizing() {
    local cpus="$1" memory_mb="$2" expected_workers="$3"

    APEX_CPU_COUNT="$cpus" APEX_MEMORY_MB="$memory_mb" apex_calculate_auto_sizing
    [[ "$apex_workers" == "$expected_workers" ]] \
        || fail "${cpus} CPU/${memory_mb} MiB selected $apex_workers workers; expected $expected_workers"
}

assert_sizing 2 2048 4
assert_sizing 16 7531 32
assert_sizing 16 1024 6
assert_sizing 1 512 2

apex_calculate_mpm_layout 65 1
[[ "$apex_mpm_workers" == 65 ]] || fail '65-worker layout was not preserved exactly'
[[ "$apex_mpm_server_limit" == 5 ]] || fail '65-worker layout did not select five servers'
[[ "$apex_mpm_threads_per_child" == 13 ]] || fail '65-worker layout did not select 13 threads per child'

apex_calculate_mpm_layout 67 1
[[ "$apex_mpm_workers" == 66 ]] || fail '67-worker layout was not safely normalized to 66'
[[ $((apex_mpm_server_limit * apex_mpm_threads_per_child)) == "$apex_mpm_workers" ]] \
    || fail 'normalized MPM layout does not equal MaxRequestWorkers'

apex_calculate_mpm_layout 512 4
[[ "$apex_mpm_workers" == 512 ]] || fail '512-worker layout was not preserved exactly'
[[ "$apex_mpm_start_servers" == 4 ]] || fail 'throughput start-server preference was not preserved'

sizing_fixture="$(mktemp -d)"
trap 'rm -rf "$sizing_fixture"' EXIT
printf '150000 100000\n' > "$sizing_fixture/cpu.max"
printf '%s\n' "$((1024 * 1024 * 1024))" > "$sizing_fixture/memory.max"
printf 'MemTotal:        8388608 kB\n' > "$sizing_fixture/meminfo"
unset APEX_CPU_COUNT APEX_MEMORY_MB
APEX_CPU_MAX_FILE="$sizing_fixture/cpu.max" \
APEX_CPU_QUOTA_FILE="$sizing_fixture/missing-quota" \
APEX_CPU_PERIOD_FILE="$sizing_fixture/missing-period" \
APEX_MEMORY_MAX_FILE="$sizing_fixture/memory.max" \
APEX_MEMINFO_FILE="$sizing_fixture/meminfo" \
    apex_calculate_auto_sizing
[[ "$apex_cpu_count" == 1.500 ]] || fail 'cgroup CPU quota was not detected'
[[ "$apex_memory_mb" == 1024 ]] || fail 'cgroup memory limit was not detected'
[[ "$apex_workers" == 3 ]] || fail 'fractional cgroup CPU quota did not select three workers'

APEX_CPU_COUNT=2 APEX_MEMORY_MB=2048 APEX_MEMORY_PER_WORKER_MB=256 \
    apex_calculate_auto_sizing
[[ "$apex_workers" == 4 ]] || fail 'CPU budget did not remain the limiting factor'

if APEX_CPU_COUNT=0 APEX_MEMORY_MB=2048 apex_calculate_auto_sizing >/dev/null 2>&1; then
    fail 'zero CPU override was accepted'
fi
if APEX_CPU_COUNT=2 APEX_MEMORY_MB=invalid apex_calculate_auto_sizing >/dev/null 2>&1; then
    fail 'invalid memory override was accepted'
fi

printf 'apex sizing tests: PASS\n'
