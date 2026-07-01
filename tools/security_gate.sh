#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1}"
APEX_PATH="${APEX_PATH:-/test.php}"
FPM_PATH="${FPM_PATH:-/fpm/test.php}"
APP_PATH="${APP_PATH:-/wordpress}"
INCLUDE_UPDATE_CHECKS="${INCLUDE_UPDATE_CHECKS:-1}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log() {
    printf '%s\n' "$*"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    log "PASS: $*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "FAIL: $*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    log "WARN: $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 2
    fi
}

check_static_analysis_and_hardening() {
    log "--- 1) Static Analysis And Hardening ---"

    local apxs_cflags
    apxs_cflags="$(apxs -q CFLAGS 2>/dev/null || true)"

    if grep -qE 'fstack-protector|Werror=format-security|FORTIFY_SOURCE|fcf-protection' <<<"$apxs_cflags"; then
        pass "compiler hardening flags present in Apache toolchain"
    elif grep -qE 'fstack-protector|Werror=format-security|FORTIFY_SOURCE|fcf-protection' build-install.sh; then
        pass "compiler hardening markers present in build-install.sh"
    else
        fail "compiler hardening flags detected"
    fi

    if ! grep -nE '\b(strcpy|strcat|sprintf|vsprintf|gets|system|popen)\b' mod_apex.c >/tmp/security_gate_insecure_funcs.txt; then
        pass "no obvious banned libc usage in mod_apex.c"
    else
        fail "no obvious banned libc usage in mod_apex.c"
        cat /tmp/security_gate_insecure_funcs.txt
    fi

    if command -v cppcheck >/dev/null 2>&1; then
        if cppcheck --quiet --enable=warning,performance,portability mod_apex.c; then
            pass "cppcheck"
        else
            fail "cppcheck"
        fi
    else
        warn "cppcheck not installed; skipped"
    fi
}

check_fuzz_and_edge_inputs() {
    log "--- 2) Request Fuzz/Edge Checks ---"

    # Oversized header-ish input and odd header chars via curl should not crash Apache.
    if curl -sS --max-time 10 -H "X-Fuzz: $(printf 'A%.0s' $(seq 1 8000))" "$BASE_URL$APEX_PATH" >/dev/null; then
        pass "large header request handled"
    else
        fail "large header request handled"
    fi

    if curl -sS --max-time 10 -H 'X-Fuzz: !@#$%^&*()_+[]{}|;:,.<>/?' "$BASE_URL$APEX_PATH" >/dev/null; then
        pass "special-character header request handled"
    else
        fail "special-character header request handled"
    fi

    if command -v nc >/dev/null 2>&1; then
        {
            printf 'POST %s HTTP/1.1\r\n' "$APEX_PATH"
            printf 'Host: 127.0.0.1\r\n'
            printf 'Content-Length: 4\r\n'
            printf 'Transfer-Encoding: chunked\r\n\r\n'
            printf '0\r\n\r\n'
        } | nc 127.0.0.1 80 >/tmp/security_gate_raw_http.txt || true
        if systemctl is-active apache2 >/dev/null 2>&1; then
            pass "conflicting CL/TE raw request did not kill apache"
        else
            fail "conflicting CL/TE raw request did not kill apache"
        fi
    else
        warn "nc not installed; raw HTTP malformed test skipped"
    fi

    if ! sudo grep -Eq 'AH00051|Segmentation fault|reslist_cleanup|exit signal Abort' /var/log/apache2/error.log; then
        pass "no crash signatures in apache log after edge checks"
    else
        fail "no crash signatures in apache log after edge checks"
    fi
}

check_dependencies_and_updates() {
    log "--- 3) Dependency And Update Checks ---"

    apache2 -v | sed -n '1,2p'
    php -v | sed -n '1,2p'

    if [[ "$INCLUDE_UPDATE_CHECKS" == "1" ]]; then
        if command -v apt >/dev/null 2>&1; then
            if apt list --upgradable 2>/dev/null | grep -Ei 'apache2|php|libapr|openssl' >/tmp/security_gate_updates.txt; then
                warn "security-relevant package updates available"
                cat /tmp/security_gate_updates.txt
            else
                pass "no pending apache/php/apr/openssl upgrades listed"
            fi
        else
            warn "apt not available; update check skipped"
        fi
    else
        warn "update checks disabled via INCLUDE_UPDATE_CHECKS=0"
    fi
}

check_security_behavior_suite() {
    log "--- 4) Security Behavior Suite ---"

    if [[ -x ./tools/common_app_compat_smoke.sh ]]; then
        if ./tools/common_app_compat_smoke.sh >/tmp/security_gate_compat.txt 2>&1; then
            pass "common app compatibility/auth/proxy/path suite"
        else
            fail "common app compatibility/auth/proxy/path suite"
            tail -n 80 /tmp/security_gate_compat.txt
        fi
    else
        fail "common_app_compat_smoke.sh executable"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$APP_PATH" >/dev/null; then
        pass "app endpoint reachable"
    else
        fail "app endpoint reachable"
    fi

    if curl -fsS --max-time 10 "$BASE_URL$FPM_PATH" >/dev/null; then
        pass "fpm endpoint reachable"
    else
        fail "fpm endpoint reachable"
    fi
}

check_least_privilege_and_service_hardening() {
    log "--- 5) Least Privilege And Service Hardening ---"

    if ps -C apache2 -o user= | grep -q '^www-data$'; then
        pass "apache worker runs as www-data"
    else
        fail "apache worker runs as www-data"
    fi

    if ps -C apache2 -o user= | grep -q '^root$'; then
        pass "apache master root process present (expected)"
    else
        warn "apache root master not detected"
    fi

    if [[ -f /etc/systemd/system/apache2.service.d/override.conf ]] && grep -q 'LimitNOFILE' /etc/systemd/system/apache2.service.d/override.conf; then
        pass "systemd apache override includes LimitNOFILE"
    else
        warn "systemd apache override missing or no LimitNOFILE"
    fi

    mod_path="/usr/lib/apache2/modules/mod_apex.so"
    if [[ -f "$mod_path" ]]; then
        perms="$(stat -c '%a' "$mod_path")"
        owner="$(stat -c '%U:%G' "$mod_path")"
        if [[ "$perms" == "644" || "$perms" == "640" || "$perms" == "444" ]]; then
            pass "mod_apex.so permissions are non-writable by group/other ($perms, $owner)"
        else
            fail "mod_apex.so permissions are non-writable by group/other ($perms, $owner)"
        fi
    else
        fail "mod_apex.so exists"
    fi

    if sudo apachectl -M | grep -q 'mpm_event_module'; then
        pass "threaded mpm_event enabled"
    else
        fail "threaded mpm_event enabled"
    fi
}

main() {
    require_cmd curl
    require_cmd grep
    require_cmd awk
    require_cmd apache2
    require_cmd php
    require_cmd sudo

    cd "$(cd "$(dirname "$0")/.." && pwd)"

    check_static_analysis_and_hardening
    check_fuzz_and_edge_inputs
    check_dependencies_and_updates
    check_security_behavior_suite
    check_least_privilege_and_service_hardening

    log "---"
    log "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT WARN=$WARN_COUNT"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
