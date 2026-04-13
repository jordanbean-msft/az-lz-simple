#!/usr/bin/env bash
# -------------------------------------------------------------------
# validate-cidr-plan.sh — Validate a proposed spoke VNet CIDR plan.
#
# Validates VNet and subnet CIDRs before provisioning:
#   1. CIDR syntax and network boundary alignment
#   2. Subnet containment within the VNet
#   3. No overlapping subnets
#   4. Azure minimum subnet sizing rules
#   5. Overlap against hub, VPN pool, cached spokes, and live VNets
#   6. Optional service-profile and delegation checks
#
# Usage:
#   ./scripts/ipam/validate-cidr-plan.sh \
#     --address-space "10.3.0.0/16" \
#     --subnets "app:10.3.0.0/27,private-endpoint:10.3.0.32/27" \
#     --delegations "app:Microsoft.Web/serverFarms" \
#     --profiles "app:app-service,private-endpoint:private-endpoint"
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"

ADDRESS_SPACE=""
SUBNETS=""
DELEGATIONS=""
PROFILES=""
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --address-space) ADDRESS_SPACE="$2"; shift 2 ;;
    --subnets) SUBNETS="$2"; shift 2 ;;
    --delegations) DELEGATIONS="$2"; shift 2 ;;
    --profiles) PROFILES="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ADDRESS_SPACE" ]]; then
  echo "ERROR: --address-space is required." >&2
  exit 1
fi

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

VALIDATOR_PYTHON_SCRIPT="$SCRIPT_DIR/validate-cidr-plan.py"
if [[ ! -f "$VALIDATOR_PYTHON_SCRIPT" ]]; then
    echo "ERROR: Python validator script not found at $VALIDATOR_PYTHON_SCRIPT" >&2
    exit 1
fi

SUBSCRIPTION_ID=$(jq -r '.subscriptionId // ""' "$CONFIG_FILE")
LIVE_VNETS_JSON="[]"
if [[ -n "$SUBSCRIPTION_ID" && "$SUBSCRIPTION_ID" != "null" ]] && command -v az &>/dev/null; then
  LIVE_VNETS_JSON=$(az network vnet list \
    --subscription "$SUBSCRIPTION_ID" \
    --query "[].{name:name, resourceGroup:resourceGroup, addressSpace:addressSpace.addressPrefixes}" \
    -o json 2>/dev/null || echo "[]")
fi

PYTHON_ARGS=(
  --address-space "$ADDRESS_SPACE"
  --subnets "$SUBNETS"
  --delegations "$DELEGATIONS"
  --profiles "$PROFILES"
  --config-file "$CONFIG_FILE"
  --live-vnets-json "$LIVE_VNETS_JSON"
)

if $JSON_OUTPUT; then
  PYTHON_ARGS+=(--json)
fi

python3 "$VALIDATOR_PYTHON_SCRIPT" "${PYTHON_ARGS[@]}"
