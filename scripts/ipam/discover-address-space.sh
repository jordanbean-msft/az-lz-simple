#!/usr/bin/env bash
# -------------------------------------------------------------------
# discover-address-space.sh — Query Azure for used address spaces and
# suggest an available CIDR block for a new spoke VNet.
#
# Scans all VNets in the subscription (and hub peerings) to build a
# map of used IP ranges, then finds a free /16 (or specified prefix)
# within 10.0.0.0/8.
#
# Usage:
#   ./scripts/ipam/discover-address-space.sh              # suggest a /16
#   ./scripts/ipam/discover-address-space.sh --prefix 24  # suggest a /24
#   ./scripts/ipam/discover-address-space.sh --json        # output as JSON
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"

PREFIX_LEN="16"
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX_LEN="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found. Copy .azure-debug-config.example.json and fill in your values." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: sudo apt-get install -y jq" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required." >&2
  exit 1
fi

DISCOVER_PYTHON_SCRIPT="$SCRIPT_DIR/discover-address-space.py"
if [[ ! -f "$DISCOVER_PYTHON_SCRIPT" ]]; then
  echo "ERROR: Python discovery script not found at $DISCOVER_PYTHON_SCRIPT" >&2
  exit 1
fi

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' "$CONFIG_FILE")

# Include cached spoke address spaces for quick display
CACHED_HUB_SPACE=$(jq -r '.hub.addressSpace // ""' "$CONFIG_FILE")
CACHED_SPOKE_COUNT=$(jq '.spokes | length' "$CONFIG_FILE")

# Collect all VNet address spaces in the subscription (always live for accuracy)
VNETS=$(az network vnet list \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[].{name:name, resourceGroup:resourceGroup, addressSpace:addressSpace.addressPrefixes, location:location}" \
  -o json 2>/dev/null)

USED_SPACES=$(echo "$VNETS" | jq -r '.[].addressSpace[]' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)

if ! $JSON_OUTPUT; then
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Azure Address Space Discovery"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  echo "── Currently used address spaces ──"
  echo ""
  echo "$VNETS" | jq -r '.[] | "  \(.name) (\(.resourceGroup), \(.location)): \(.addressSpace | join(", "))"'
  echo ""
  echo "── Used CIDR blocks (sorted) ──"
  echo ""
  echo "$USED_SPACES" | sed 's/^/  /'
  echo ""
fi

PYTHON_ARGS=(
  --used-spaces "$USED_SPACES"
  --prefix "$PREFIX_LEN"
)

if $JSON_OUTPUT; then
  PYTHON_ARGS+=(--json)
fi

python3 "$DISCOVER_PYTHON_SCRIPT" "${PYTHON_ARGS[@]}"
