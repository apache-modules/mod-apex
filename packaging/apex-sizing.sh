#!/usr/bin/env bash

# Shared resource detection and worker sizing for native packages and Docker.
# Call apex_calculate_auto_sizing; results are returned in apex_* variables.

apex_is_positive_integer() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

apex_detect_cpu_millicores() {
    local online_cpus cpu_limit_file quota period quota_millicores

    if [[ -n "${APEX_CPU_COUNT:-}" ]]; then
        if ! apex_is_positive_integer "$APEX_CPU_COUNT"; then
            echo "APEX_CPU_COUNT must be a positive whole number." >&2
            return 2
        fi
        printf '%s\n' "$((10#$APEX_CPU_COUNT * 1000))"
        return
    fi

    online_cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if ! apex_is_positive_integer "$online_cpus"; then
        online_cpus=1
    fi
    apex_detected_cpu_millicores=$((10#$online_cpus * 1000))

    cpu_limit_file="${APEX_CPU_MAX_FILE:-/sys/fs/cgroup/cpu.max}"
    if [[ -r "$cpu_limit_file" ]]; then
        read -r quota period < "$cpu_limit_file" || true
    else
        quota=""
        period=""
    fi

    if [[ "$quota" == "max" ]]; then
        quota=""
    fi
    if [[ -z "$quota" ]]; then
        local quota_file="${APEX_CPU_QUOTA_FILE:-/sys/fs/cgroup/cpu/cpu.cfs_quota_us}"
        local period_file="${APEX_CPU_PERIOD_FILE:-/sys/fs/cgroup/cpu/cpu.cfs_period_us}"
        if [[ -r "$quota_file" && -r "$period_file" ]]; then
            quota="$(<"$quota_file")"
            period="$(<"$period_file")"
            [[ "$quota" == "-1" ]] && quota=""
        fi
    fi

    if apex_is_positive_integer "$quota" && apex_is_positive_integer "$period"; then
        quota_millicores=$(((10#$quota * 1000 + 10#$period - 1) / 10#$period))
        if (( quota_millicores < apex_detected_cpu_millicores )); then
            apex_detected_cpu_millicores=$quota_millicores
        fi
    fi

    printf '%s\n' "$apex_detected_cpu_millicores"
}

apex_detect_memory_mb() {
    local meminfo_file physical_mb memory_limit_file memory_limit_bytes memory_limit_mb

    if [[ -n "${APEX_MEMORY_MB:-}" ]]; then
        if ! apex_is_positive_integer "$APEX_MEMORY_MB"; then
            echo "APEX_MEMORY_MB must be a positive whole number." >&2
            return 2
        fi
        printf '%s\n' "$((10#$APEX_MEMORY_MB))"
        return
    fi

    meminfo_file="${APEX_MEMINFO_FILE:-/proc/meminfo}"
    physical_mb="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024; exit}' "$meminfo_file" 2>/dev/null || true)"
    if ! apex_is_positive_integer "$physical_mb"; then
        physical_mb=512
    fi
    apex_detected_memory_mb=$physical_mb

    memory_limit_file="${APEX_MEMORY_MAX_FILE:-/sys/fs/cgroup/memory.max}"
    if [[ -r "$memory_limit_file" ]]; then
        memory_limit_bytes="$(<"$memory_limit_file")"
    else
        memory_limit_file="${APEX_MEMORY_LIMIT_FILE:-/sys/fs/cgroup/memory/memory.limit_in_bytes}"
        memory_limit_bytes=""
        [[ -r "$memory_limit_file" ]] && memory_limit_bytes="$(<"$memory_limit_file")"
    fi

    if apex_is_positive_integer "$memory_limit_bytes"; then
        memory_limit_mb=$((10#$memory_limit_bytes / 1024 / 1024))
        if (( memory_limit_mb > 0 && memory_limit_mb < apex_detected_memory_mb )); then
            apex_detected_memory_mb=$memory_limit_mb
        fi
    fi

    printf '%s\n' "$apex_detected_memory_mb"
}

apex_format_cpu_count() {
    local millicores="$1" whole remainder
    whole=$((millicores / 1000))
    remainder=$((millicores % 1000))
    if (( remainder == 0 )); then
        printf '%d' "$whole"
    else
        printf '%d.%03d' "$whole" "$remainder"
    fi
}

apex_calculate_mpm_layout() {
    local requested_workers="${1:-}" preferred_start_servers="${2:-1}"
    local servers threads candidate best_workers=0 best_servers=1 best_threads=1

    if ! apex_is_positive_integer "$requested_workers" \
        || (( requested_workers < 1 || requested_workers > 512 )); then
        echo "worker count must be a whole number from 1 to 512." >&2
        return 2
    fi
    if ! apex_is_positive_integer "$preferred_start_servers"; then
        echo "preferred start-server count must be a positive whole number." >&2
        return 2
    fi

    # event MPM requires MaxRequestWorkers to be an integer multiple of
    # ThreadsPerChild. Search the existing envelope (up to eight children,
    # up to 64 threads each) for the largest product that does not exceed the
    # resource budget. For equal products, retain the layout with fewer
    # processes and more threads.
    for ((servers = 1; servers <= 8; servers++)); do
        for ((threads = 1; threads <= 64; threads++)); do
            candidate=$((servers * threads))
            if (( candidate <= requested_workers && candidate > best_workers )); then
                best_workers=$candidate
                best_servers=$servers
                best_threads=$threads
            fi
        done
    done

    apex_mpm_requested_workers=$requested_workers
    apex_mpm_workers=$best_workers
    apex_mpm_server_limit=$best_servers
    apex_mpm_threads_per_child=$best_threads
    apex_mpm_start_servers=$preferred_start_servers
    if (( apex_mpm_start_servers > apex_mpm_server_limit )); then
        apex_mpm_start_servers=$apex_mpm_server_limit
    fi
    apex_mpm_min_spare_threads=$apex_mpm_threads_per_child
    apex_mpm_max_spare_threads=$apex_mpm_workers
}

apex_calculate_auto_sizing() {
    local memory_per_worker reserve_mb usable_mb

    memory_per_worker="${APEX_MEMORY_PER_WORKER_MB:-128}"
    if ! apex_is_positive_integer "$memory_per_worker"; then
        echo "APEX_MEMORY_PER_WORKER_MB must be a positive whole number." >&2
        return 2
    fi

    apex_cpu_millicores="$(apex_detect_cpu_millicores)" || return
    apex_memory_mb="$(apex_detect_memory_mb)" || return
    apex_cpu_count="$(apex_format_cpu_count "$apex_cpu_millicores")"
    apex_cpu_worker_cap=$(((apex_cpu_millicores * 2 + 999) / 1000))

    reserve_mb=$((apex_memory_mb / 4))
    (( reserve_mb < 256 )) && reserve_mb=256
    usable_mb=$((apex_memory_mb - reserve_mb))
    if (( usable_mb > 0 )); then
        apex_memory_worker_cap=$((usable_mb / 10#$memory_per_worker))
    else
        apex_memory_worker_cap=1
    fi
    (( apex_memory_worker_cap < 1 )) && apex_memory_worker_cap=1

    apex_workers=$apex_cpu_worker_cap
    apex_limiting_resource=cpu
    if (( apex_memory_worker_cap < apex_workers )); then
        apex_workers=$apex_memory_worker_cap
        apex_limiting_resource=memory
    fi
    (( apex_workers < 1 )) && apex_workers=1
    (( apex_workers > 512 )) && apex_workers=512
    return 0
}
