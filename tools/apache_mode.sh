#!/usr/bin/env bash
set -euo pipefail

mode="${1:-status}"
platform="${APEX_PLATFORM:-}"
tuning_conf="${APEX_TUNING_CONF:-}"
service_name="${APEX_SERVICE:-}"
apache_ctl="${APEX_CTL:-}"
systemctl_cmd="${APEX_SYSTEMCTL:-$(command -v systemctl || true)}"
enable_cmd="${APEX_ENABLE_CMD:-}"
disable_cmd="${APEX_DISABLE_CMD:-}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") status
  sudo $(basename "$0") steady
  sudo $(basename "$0") throughput

Profiles:
  steady      WordPress-safe default validated by a one-hour soak test.
  throughput  Controlled 256-worker profile for higher traffic.
  status      Show the active PHP Apex performance file.

Profile override:
  APEX_MAX_REQUEST_WORKERS  Override the worker count (64-512).
EOF
}

detect_platform() {
    local distro_id="" distro_like=""
    [[ -n "$platform" ]] && return
    if [[ ! -r /etc/os-release ]]; then
        echo "Unable to identify this Linux distribution." >&2
        exit 2
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    distro_id="${ID:-}"
    distro_like="${ID_LIKE:-}"
    case " $distro_id $distro_like " in
        *" debian "*|*" ubuntu "*) platform="debian" ;;
        *" fedora "*|*" rhel "*|*" centos "*) platform="fedora" ;;
        *" arch "*|*" manjaro "*) platform="arch" ;;
        *)
            echo "Unsupported Linux distribution: ${distro_id:-unknown}" >&2
            exit 2
            ;;
    esac
}

select_platform_settings() {
    case "$platform" in
        debian)
            tuning_conf="${tuning_conf:-/etc/apache2/conf-available/php-apex-performance.conf}"
            service_name="${service_name:-apache2}"
            apache_ctl="${apache_ctl:-$(command -v apache2ctl || command -v apachectl || true)}"
            enable_cmd="${enable_cmd:-$(command -v a2enconf || true)}"
            disable_cmd="${disable_cmd:-$(command -v a2disconf || true)}"
            ;;
        fedora)
            tuning_conf="${tuning_conf:-/etc/httpd/conf.d/php-apex-performance.conf}"
            service_name="${service_name:-httpd}"
            apache_ctl="${apache_ctl:-$(command -v apachectl || command -v httpd || true)}"
            ;;
        arch)
            tuning_conf="${tuning_conf:-/etc/httpd/conf/conf.d/php-apex-performance.conf}"
            service_name="${service_name:-httpd}"
            apache_ctl="${apache_ctl:-$(command -v apachectl || command -v httpd || true)}"
            ;;
        *)
            echo "Unsupported platform: $platform" >&2
            exit 2
            ;;
    esac
}

require_command_path() {
    local command_path="$1" label="$2"
    if [[ -z "$command_path" || ! -x "$command_path" ]]; then
        echo "$label was not found or is not executable." >&2
        exit 2
    fi
}

require_managed_directory() {
    local managed_dir
    managed_dir="$(dirname "$tuning_conf")"
    if [[ ! -d "$managed_dir" ]]; then
        echo "Apache configuration directory not found: $managed_dir" >&2
        exit 2
    fi
    if [[ "$managed_dir" == /etc/* && "$(id -u)" -ne 0 ]]; then
        echo "Run this profile with sudo." >&2
        exit 2
    fi
}

calculate_steady_values() {
    profile_name="steady"
    max_request_workers="${APEX_MAX_REQUEST_WORKERS:-128}"
    calculate_worker_layout 2
    keep_alive="On"
    max_keep_alive_requests=10000
    keep_alive_timeout=1
    max_connections_per_child=1000
    printf 'Steady WordPress profile: MaxRequestWorkers=%s\n' "$max_request_workers"
}

calculate_worker_layout() {
    local preferred_start_servers="$1"
    if [[ ! "$max_request_workers" =~ ^[1-9][0-9]*$ ]] \
        || (( max_request_workers < 64 || max_request_workers > 512 )); then
        echo "APEX_MAX_REQUEST_WORKERS must be an integer from 64 to 512." >&2
        exit 2
    fi
    threads_per_child=64
    server_limit=$(((max_request_workers + threads_per_child - 1) / threads_per_child))
    start_servers="$preferred_start_servers"
    if (( start_servers > server_limit )); then
        start_servers=$server_limit
    fi
    min_spare_threads=$threads_per_child
    if (( min_spare_threads > max_request_workers )); then
        min_spare_threads=$max_request_workers
    fi
    max_spare_threads=$((threads_per_child * server_limit))
    if (( max_spare_threads > max_request_workers )); then
        max_spare_threads=$max_request_workers
    fi
}

set_throughput_values() {
    profile_name="throughput"
    keep_alive="On"
    max_keep_alive_requests=10000
    keep_alive_timeout=1
    max_request_workers="${APEX_MAX_REQUEST_WORKERS:-256}"
    calculate_worker_layout 4
    max_connections_per_child=1000
    printf 'Throughput profile: MaxRequestWorkers=%s\n' "$max_request_workers"
}

write_profile_file() {
    local output_file="$1"
    cat > "$output_file" <<EOF
# Managed by php-apex-mode. Run "php-apex-mode status" to view this profile.
# PHP Apex profile: $profile_name
KeepAlive $keep_alive
MaxKeepAliveRequests $max_keep_alive_requests
KeepAliveTimeout $keep_alive_timeout

<IfModule mpm_event_module>
StartServers $start_servers
ServerLimit $server_limit
ThreadLimit $threads_per_child
ThreadsPerChild $threads_per_child
MinSpareThreads $min_spare_threads
MaxSpareThreads $max_spare_threads
MaxRequestWorkers $max_request_workers
MaxConnectionsPerChild $max_connections_per_child
</IfModule>
EOF
}

show_status() {
    if [[ ! -f "$tuning_conf" ]]; then
        echo "No PHP Apex performance profile is active at $tuning_conf"
        echo "Run: sudo $(basename "$0") steady"
        return 1
    fi
    profile_name="$(sed -n 's/^# PHP Apex profile: //p' "$tuning_conf" | head -1)"
    printf 'Profile: %s\n' "${profile_name:-custom}"
    printf 'File: %s\n' "$tuning_conf"
    sed -n -E '/^(KeepAlive|MaxKeepAliveRequests|KeepAliveTimeout|[[:space:]]*(StartServers|ServerLimit|ThreadLimit|ThreadsPerChild|MinSpareThreads|MaxSpareThreads|MaxRequestWorkers|MaxConnectionsPerChild))[[:space:]]/p' "$tuning_conf" \
        | sed 's/^[[:space:]]*//'
}

enable_debian_profile() {
    [[ "$platform" != "debian" ]] && return
    require_command_path "$enable_cmd" "a2enconf"
    "$enable_cmd" php-apex-performance >/dev/null
}

rollback_profile() {
    local backup_file="$1" had_existing_file="$2"
    if [[ "$had_existing_file" == "yes" ]]; then
        cp -p "$backup_file" "$tuning_conf"
    else
        rm -f "$tuning_conf"
        if [[ "$platform" == "debian" && -n "$disable_cmd" && -x "$disable_cmd" ]]; then
            "$disable_cmd" php-apex-performance >/dev/null 2>&1 || true
        fi
    fi
}

apply_profile() {
    local managed_dir temp_file backup_file had_existing_file="no"
    managed_dir="$(dirname "$tuning_conf")"
    temp_file="$(mktemp "$managed_dir/.php-apex-performance.XXXXXX")"
    backup_file="$(mktemp)"
    trap 'rm -f "$temp_file" "$backup_file"' RETURN

    if [[ -f "$tuning_conf" ]]; then
        cp -p "$tuning_conf" "$backup_file"
        had_existing_file="yes"
    fi
    write_profile_file "$temp_file"
    chmod 0644 "$temp_file"
    mv -f "$temp_file" "$tuning_conf"

    if ! enable_debian_profile; then
        rollback_profile "$backup_file" "$had_existing_file"
        echo "Apache could not enable the PHP Apex performance profile." >&2
        return 1
    fi
    if ! "$apache_ctl" -t; then
        rollback_profile "$backup_file" "$had_existing_file"
        echo "Apache did not accept the new profile; the previous file was restored." >&2
        return 1
    fi
    if ! "$systemctl_cmd" restart "$service_name"; then
        echo "The profile is valid, but the $service_name service did not restart." >&2
        return 1
    fi
    show_status
}

case "$mode" in
    -h|--help|help)
        usage
        ;;
    status)
        detect_platform
        select_platform_settings
        show_status
        ;;
    steady|throughput)
        detect_platform
        select_platform_settings
        require_managed_directory
        require_command_path "$apache_ctl" "Apache control command"
        require_command_path "$systemctl_cmd" "systemctl"
        if [[ "$mode" == "steady" ]]; then
            calculate_steady_values
        else
            set_throughput_values
        fi
        apply_profile
        ;;
    *)
        echo "Unknown profile: $mode" >&2
        usage >&2
        exit 2
        ;;
esac
