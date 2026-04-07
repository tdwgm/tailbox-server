#!/bin/bash
# gluetun-watcher.sh v1.3.0
# Watches for mullvad-gateway restart events and recreates all dependent containers.
# Also runs the Tailscale routing fix (mullvad-exitnode-init.sh) after each restart
# and once at startup to cover the case where the system boots without a gluetun event.
#
# TAILBOX_BASE: set this env var to override the directory containing compose dirs.
# Defaults to the parent directory of this script (i.e. tailbox-server/).
#
# To add your own sidecar containers that should restart when the VPN restarts:
#   1. Add the container name to DEPENDENT_CONTAINERS
#   2. Add a matching entry to COMPOSE_DIRS pointing to its compose directory
# Both arrays must stay in sync. Containers sharing a compose dir are deduplicated
# (only one `docker compose up --force-recreate` is run per unique dir).

set -euo pipefail

# Base directory for compose dirs — override with TAILBOX_BASE env var
TAILBOX_BASE="${TAILBOX_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

VPN_CONTAINER="mullvad-gateway"

# Containers to restart when the VPN container restarts.
# Add your own sidecar container names here.
DEPENDENT_CONTAINERS=(
    "tailscale-endpoint"
    "tailbox-socks"
    "tailbox-dns"
)

# Compose directory for each dependent container.
# tailscale-endpoint and tailbox-socks share the same compose dir.
# Add entries here to match any containers you added above.
declare -A COMPOSE_DIRS=(
    ["tailscale-endpoint"]="${TAILBOX_BASE}/tailscale-endpoint"
    ["tailbox-socks"]="${TAILBOX_BASE}/tailscale-endpoint"
    ["tailbox-dns"]="${TAILBOX_BASE}/dns"
)

RESTART_DELAY=10
RESTART_LOCK="/tmp/gluetun-watcher-restart.lock"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

restart_container() {
    local container="$1"
    local compose_dir="${COMPOSE_DIRS[$container]:-}"

    if [[ -n "$compose_dir" && -d "$compose_dir" ]]; then
        log "Recreating $container via docker compose (dir: $compose_dir)"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would run: cd $compose_dir && docker compose up -d --force-recreate"
        else
            (cd "$compose_dir" && docker compose up -d --force-recreate) || \
                log "ERROR: Failed to recreate $container via compose"
        fi
    else
        log "WARNING: No compose dir for $container, using docker restart"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would run: docker restart $container"
        else
            docker restart "$container" || log "ERROR: Failed to restart $container"
        fi
    fi
}

restart_dependents() {
    if ! mkdir "$RESTART_LOCK" 2>/dev/null; then
        log "Restart already in progress, skipping duplicate event"
        return
    fi
    trap 'rmdir "$RESTART_LOCK" 2>/dev/null' RETURN

    log "VPN container '$VPN_CONTAINER' restarted. Waiting ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"

    declare -A processed_dirs=()
    for container in "${DEPENDENT_CONTAINERS[@]}"; do
        local compose_dir="${COMPOSE_DIRS[$container]:-}"
        if [[ -n "$compose_dir" && -n "${processed_dirs[$compose_dir]:-}" ]]; then
            log "Skipping $container (compose dir already processed)"
            continue
        fi
        restart_container "$container"
        if [[ -n "$compose_dir" ]]; then
            processed_dirs[$compose_dir]=1
        fi
    done

    log "All dependent containers processed"

    log "Waiting 15s for tailscale0 interface..."
    sleep 15
    local init_output
    init_output=$(/usr/local/bin/mullvad-exitnode-init.sh 2>&1) && \
        log "Exit node init: $init_output" || \
        log "WARNING: exit node init failed: $init_output"
}

main() {
    log "=== Starting gluetun-watcher v1.3.0 ==="
    log "Watching: $VPN_CONTAINER"
    log "Dependents: ${DEPENDENT_CONTAINERS[*]}"
    log "TAILBOX_BASE: $TAILBOX_BASE"
    [[ "$DRY_RUN" == "true" ]] && log "DRY-RUN MODE"

    rmdir "$RESTART_LOCK" 2>/dev/null || true

    log "Running initial routing fix..."
    local init_output
    init_output=$(/usr/local/bin/mullvad-exitnode-init.sh 2>&1) && \
        log "Initial routing fix: $init_output" || \
        log "WARNING: initial routing fix failed: $init_output"

    docker events \
        --filter "container=$VPN_CONTAINER" \
        --filter "event=start" \
        --format '{{.Action}} {{.Actor.Attributes.name}}' | \
    while read -r event; do
        log "Event: $event"
        restart_dependents &
    done
}

trap 'log "Shutting down..."; rmdir "$RESTART_LOCK" 2>/dev/null; exit 0' SIGTERM SIGINT
main
