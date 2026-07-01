#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
    printf '%s\n' "$*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 2
    fi
}

install_tools_if_missing() {
    local to_install=()

    if ! command -v cppcheck >/dev/null 2>&1; then
        to_install+=(cppcheck)
    fi

    if ! command -v nc >/dev/null 2>&1; then
        to_install+=(netcat-openbsd)
    fi

    if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing missing tools: ${to_install[*]}"
        sudo apt-get update -y
        sudo apt-get install -y "${to_install[@]}"
    else
        log "All required tools already installed."
    fi
}

apply_safe_security_updates() {
    local pkg="libgnutls-openssl27t64"

    if apt list --upgradable 2>/dev/null | grep -q "^${pkg}/"; then
        log "Applying security update for ${pkg}"
        sudo apt-get update -y
        sudo apt-get install -y --only-upgrade "${pkg}"
    else
        log "No pending upgrade for ${pkg}."
    fi
}

run_security_gate() {
    log "Running security gate"
    cd "$REPO_ROOT"
    ./tools/security_gate.sh
}

main() {
    require_cmd sudo
    require_cmd apt-get
    require_cmd apt

    install_tools_if_missing
    apply_safe_security_updates
    run_security_gate
}

main "$@"
