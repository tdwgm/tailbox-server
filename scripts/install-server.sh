#!/bin/bash
# install-server.sh
# Bootstrap installer for the tailbox server stack (Mullvad + Tailscale + DNS).
#
# Steps:
#   1. Check prerequisites (docker, docker compose v2, jq)
#   2. Create Docker network
#   3. Set up .env from template
#   4. Validate MULLVAD_ADDRESS
#   5. Set up secrets (WG key, optional TS auth key)
#   6. Configure DNS based on DNS_MODE
#   7. Install scripts to /usr/local/bin
#   8. Create systemd service for gluetun-watcher
#   9. Start stacks in order
#  10. Verify VPN connection
#
# Environment overrides:
#   TAILBOX_BASE     Override base directory (default: parent of this script)
#   TAILBOX_NETWORK  Override docker network name (default: from .env or tailbox-net)

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAILBOX_BASE="${TAILBOX_BASE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

GLUETUN_DIR="${TAILBOX_BASE}/gluetun-mullvad"
TAILSCALE_DIR="${TAILBOX_BASE}/tailscale-endpoint"
DNS_DIR="${TAILBOX_BASE}/dns"
ENV_FILE="${GLUETUN_DIR}/.env"
ENV_EXAMPLE="${GLUETUN_DIR}/.env.example"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}=== $* ===${NC}"; }

# Read a value from the .env file (supports KEY=value and KEY="value")
env_get() {
    local key="$1"
    # Strip quotes and inline comments
    grep -E "^${key}=" "$ENV_FILE" 2>/dev/null \
        | head -1 \
        | cut -d= -f2- \
        | sed 's/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*#.*//' \
        | xargs
}

# Update or add a key=value in the .env file
env_set() {
    local key="$1"
    local val="$2"
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    section "Checking prerequisites"

    local ok=true

    if ! command -v docker &>/dev/null; then
        error "docker is not installed"
        ok=false
    else
        info "docker: $(docker --version)"
    fi

    if ! docker compose version &>/dev/null; then
        error "docker compose v2 plugin is not available (try: docker compose version)"
        ok=false
    else
        info "docker compose: $(docker compose version --short 2>/dev/null || docker compose version)"
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is not installed (sudo apt install jq / sudo dnf install jq)"
        ok=false
    else
        info "jq: $(jq --version)"
    fi

    if [[ "$ok" != "true" ]]; then
        fatal "Install the missing prerequisites and re-run."
    fi
}

# ---------------------------------------------------------------------------
# 2. Docker network
# ---------------------------------------------------------------------------
create_network() {
    section "Docker network"

    # Determine network name: CLI override → .env value → default
    local network="${TAILBOX_NETWORK:-}"
    if [[ -z "$network" && -f "$ENV_FILE" ]]; then
        network="$(env_get TAILBOX_NETWORK)"
    fi
    network="${network:-tailbox-net}"

    if docker network inspect "$network" &>/dev/null; then
        info "Network '$network' already exists"
    else
        info "Creating Docker network '$network'..."
        docker network create "$network"
        info "Network '$network' created"
    fi
}

# ---------------------------------------------------------------------------
# 3. .env setup
# ---------------------------------------------------------------------------
setup_env() {
    section ".env configuration"

    if [[ -f "$ENV_FILE" ]]; then
        info ".env already exists: $ENV_FILE"
        return
    fi

    if [[ ! -f "$ENV_EXAMPLE" ]]; then
        fatal ".env.example not found at $ENV_EXAMPLE"
    fi

    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Copied .env.example → .env"
    echo
    warn "Please edit $ENV_FILE before continuing."
    warn "At minimum, set:"
    warn "  MULLVAD_ADDRESS  — your WireGuard address (e.g. 10.64.x.x/32)"
    warn "  DNS_LOCAL_DOMAIN — your local domain (split mode)"
    warn "  DNS_LOCAL_SERVER — your LAN DNS server (split mode)"
    echo
    read -rp "Press Enter after you have edited .env, or Ctrl-C to abort... "
}

# ---------------------------------------------------------------------------
# 4. Validate MULLVAD_ADDRESS
# ---------------------------------------------------------------------------
validate_mullvad_address() {
    section "Validating MULLVAD_ADDRESS"

    local addr
    addr="$(env_get MULLVAD_ADDRESS)"

    if [[ -z "$addr" ]]; then
        fatal "MULLVAD_ADDRESS is not set in $ENV_FILE\n  Generate a config at: https://mullvad.net/en/account/wireguard-config"
    fi

    info "MULLVAD_ADDRESS: $addr"
}

# ---------------------------------------------------------------------------
# 5. Secrets
# ---------------------------------------------------------------------------
setup_secrets() {
    section "Secrets"

    # --- Mullvad WireGuard key ---
    local wg_key_file="${GLUETUN_DIR}/secrets/mullvad_wg_key.txt"
    mkdir -p "${GLUETUN_DIR}/secrets"

    if [[ -f "$wg_key_file" ]] && [[ -s "$wg_key_file" ]]; then
        info "Mullvad WG key already present: $wg_key_file"
    else
        echo
        info "Paste your Mullvad WireGuard private key below (single line, input hidden)."
        info "Generate one at: https://mullvad.net/en/account/wireguard-config"
        echo -n "Mullvad WG private key: "
        local wg_key
        read -rs wg_key
        echo
        if [[ -z "$wg_key" ]]; then
            fatal "WireGuard key cannot be empty"
        fi
        echo -n "$wg_key" > "$wg_key_file"
        chmod 600 "$wg_key_file"
        info "Saved WG key to $wg_key_file"
    fi

    # --- Tailscale auth key (OPTIONAL) ---
    local ts_key_file="${TAILSCALE_DIR}/secrets/ts_authkey.txt"
    mkdir -p "${TAILSCALE_DIR}/secrets"

    if [[ -f "$ts_key_file" ]] && [[ -s "$ts_key_file" ]]; then
        info "Tailscale auth key already present: $ts_key_file"
    else
        echo
        info "Tailscale auth key is OPTIONAL."
        info "  - Skip → Tailscale will print an interactive login URL on first start."
        info "  - Provide one for headless / automated provisioning."
        info "  Create keys at: https://login.tailscale.com/admin/settings/keys"
        echo -n "Tailscale auth key [leave blank to skip]: "
        local ts_key
        read -rs ts_key
        echo
        if [[ -n "$ts_key" ]]; then
            echo -n "$ts_key" > "$ts_key_file"
            chmod 600 "$ts_key_file"
            info "Saved Tailscale auth key to $ts_key_file"
        else
            # Write an empty file so the secret mount doesn't fail;
            # the entrypoint reads $TS_AUTHKEY_FILE and passes it as TS_AUTHKEY.
            # An empty value is handled gracefully by the Tailscale image.
            touch "$ts_key_file"
            chmod 600 "$ts_key_file"
            info "Skipping Tailscale auth key — you will get a login URL on first start."
        fi
    fi
}

# ---------------------------------------------------------------------------
# 6. DNS configuration
# ---------------------------------------------------------------------------
configure_dns() {
    section "DNS configuration"

    local dns_mode
    dns_mode="$(env_get DNS_MODE)"
    dns_mode="${dns_mode:-split}"

    info "DNS_MODE: $dns_mode"

    case "$dns_mode" in
        split)
            local local_domain local_server
            local_domain="$(env_get DNS_LOCAL_DOMAIN)"
            local_server="$(env_get DNS_LOCAL_SERVER)"

            if [[ -z "$local_domain" || "$local_domain" == "lan.example.com" ]]; then
                fatal "DNS_MODE=split requires DNS_LOCAL_DOMAIN to be set (not the example value)"
            fi
            if [[ -z "$local_server" ]]; then
                fatal "DNS_MODE=split requires DNS_LOCAL_SERVER to be set"
            fi

            info "Generating dnsmasq config: ${local_domain} → ${local_server}"
            bash "${DNS_DIR}/generate-config.sh" "$ENV_FILE"

            env_set "DNS_UPSTREAM" "127.0.0.1:5353"
            info "Set DNS_UPSTREAM=127.0.0.1:5353"
            ;;

        mullvad)
            env_set "DNS_UPSTREAM" "10.64.0.1"
            info "Set DNS_UPSTREAM=10.64.0.1 (Mullvad)"
            ;;

        custom)
            local custom_server
            custom_server="$(env_get DNS_CUSTOM_SERVER)"
            if [[ -z "$custom_server" ]]; then
                fatal "DNS_MODE=custom requires DNS_CUSTOM_SERVER to be set"
            fi
            warn "Custom DNS mode: all DNS goes to $custom_server (may leak outside VPN tunnel)"
            env_set "DNS_UPSTREAM" "$custom_server"
            info "Set DNS_UPSTREAM=$custom_server"
            ;;

        *)
            fatal "Unknown DNS_MODE '$dns_mode'. Expected: split | mullvad | custom"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 7. Install scripts
# ---------------------------------------------------------------------------
install_scripts() {
    section "Installing scripts to /usr/local/bin"

    local scripts=(
        "mullvad-exitnode-init.sh"
        "gluetun-watcher.sh"
    )

    for script in "${scripts[@]}"; do
        local src="${SCRIPT_DIR}/${script}"
        local dst="/usr/local/bin/${script}"

        if [[ ! -f "$src" ]]; then
            fatal "Script not found: $src"
        fi

        info "Installing $script → $dst"
        sudo install -m 755 "$src" "$dst"
    done
}

# ---------------------------------------------------------------------------
# 8. Systemd service for gluetun-watcher
# ---------------------------------------------------------------------------
install_systemd_service() {
    section "systemd service: gluetun-watcher"

    local service_file="/etc/systemd/system/gluetun-watcher.service"

    if [[ -f "$service_file" ]]; then
        info "Service file already exists: $service_file"
        info "Run 'sudo systemctl daemon-reload && sudo systemctl restart gluetun-watcher' if you updated the script."
        return
    fi

    info "Creating $service_file..."
    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Gluetun VPN watcher — restarts dependent containers on VPN restart
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
Environment=TAILBOX_BASE=${TAILBOX_BASE}
ExecStart=/usr/local/bin/gluetun-watcher.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gluetun-watcher

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now gluetun-watcher.service
    info "gluetun-watcher.service enabled and started"
}

# ---------------------------------------------------------------------------
# 9. Start stacks
# ---------------------------------------------------------------------------
start_stacks() {
    section "Starting stacks"

    local dns_mode
    dns_mode="$(env_get DNS_MODE)"
    dns_mode="${dns_mode:-split}"

    # 1. Gluetun (VPN gateway) — must come first
    info "Starting gluetun-mullvad stack..."
    (cd "$GLUETUN_DIR" && docker compose up -d)

    # Wait for gluetun to establish VPN before starting containers that share
    # its network namespace. A 5 s delay is sufficient for the initial boot.
    info "Waiting 5s for gluetun to initialise..."
    sleep 5

    # 2. DNS sidecar (split mode only)
    if [[ "$dns_mode" == "split" ]]; then
        info "Starting dns stack (split mode)..."
        (cd "$DNS_DIR" && docker compose up -d)
    fi

    # 3. Tailscale endpoint + microsocks
    info "Starting tailscale-endpoint stack..."
    (cd "$TAILSCALE_DIR" && docker compose up -d)
}

# ---------------------------------------------------------------------------
# 10. Verify VPN connection
# ---------------------------------------------------------------------------
verify_vpn() {
    section "Verifying VPN connection"

    info "Waiting up to 30s for mullvad-gateway to become healthy..."

    local attempts=0
    while (( attempts < 6 )); do
        local health
        health="$(docker inspect --format='{{.State.Health.Status}}' mullvad-gateway 2>/dev/null || true)"
        if [[ "$health" == "healthy" ]]; then
            break
        fi
        (( attempts++ ))
        sleep 5
    done

    local health
    health="$(docker inspect --format='{{.State.Health.Status}}' mullvad-gateway 2>/dev/null || true)"
    if [[ "$health" == "healthy" ]]; then
        info "mullvad-gateway is healthy"
    else
        warn "mullvad-gateway health status: ${health:-unknown}"
        warn "VPN may still be connecting — check logs with: docker logs mullvad-gateway"
    fi

    info "Checking VPN connectivity via am.i.mullvad.net..."
    local result
    if result="$(docker exec mullvad-gateway wget -qO- https://am.i.mullvad.net/connected 2>/dev/null)"; then
        if echo "$result" | grep -qi "You are connected"; then
            info "VPN confirmed: $result"
        else
            warn "Unexpected response from Mullvad check: $result"
        fi
    else
        warn "Could not reach am.i.mullvad.net — VPN may still be warming up."
        warn "Re-run check manually: docker exec mullvad-gateway wget -qO- https://am.i.mullvad.net/connected"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BOLD}"
    echo "  tailbox server — bootstrap installer"
    echo "  TAILBOX_BASE: ${TAILBOX_BASE}"
    echo -e "${NC}"

    check_prerequisites
    setup_env
    validate_mullvad_address
    create_network
    setup_secrets
    configure_dns
    install_scripts
    install_systemd_service
    start_stacks
    verify_vpn

    echo
    echo -e "${GREEN}${BOLD}Installation complete.${NC}"
    echo
    echo "  Next steps:"
    echo "  - Check container status:    docker ps"
    echo "  - Gluetun logs:              docker logs mullvad-gateway"
    echo "  - Tailscale logs:            docker logs tailscale-endpoint"
    echo "    (first run may print a login URL — open it to authenticate)"
    echo "  - Watcher service:           sudo systemctl status gluetun-watcher"
    echo
}

main "$@"
