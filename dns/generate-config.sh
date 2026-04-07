#!/bin/bash
# Generate dnsmasq.conf from template using .env values.
# Usage: ./generate-config.sh [path-to-env-file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${1:-$(dirname "$SCRIPT_DIR")/gluetun-mullvad/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found: $ENV_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${DNS_LOCAL_DOMAIN:-}" || -z "${DNS_LOCAL_SERVER:-}" ]]; then
    echo "ERROR: DNS_LOCAL_DOMAIN and DNS_LOCAL_SERVER must be set in .env" >&2
    exit 1
fi

export DNS_LOCAL_DOMAIN DNS_LOCAL_SERVER
envsubst '${DNS_LOCAL_DOMAIN} ${DNS_LOCAL_SERVER}' \
    < "$SCRIPT_DIR/dnsmasq.conf.template" \
    > "$SCRIPT_DIR/dnsmasq.conf"

echo "Generated dnsmasq.conf: ${DNS_LOCAL_DOMAIN} → ${DNS_LOCAL_SERVER}"
