#!/usr/bin/env bash
# -------------------------------------------------------------------
# remove-spoke.sh — Remove a spoke VNet and its peerings
#
# Tears down the bidirectional peerings and optionally deletes the
# spoke VNet and resource group. Updates .azure-debug-config.json.
#
# Usage:
#   ./scripts/ipam/remove-spoke.sh --name "my-app"
#   ./scripts/ipam/remove-spoke.sh --name "my-app" --delete-vnet
#   ./scripts/ipam/remove-spoke.sh --name "my-app" --delete-rg
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"

SPOKE_NAME=""
DELETE_VNET=false
DELETE_RG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) SPOKE_NAME="$2"; shift 2 ;;
    --delete-vnet) DELETE_VNET=true; shift ;;
    --delete-rg) DELETE_RG=true; DELETE_VNET=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found." >&2
  exit 1
fi

if [[ -z "$SPOKE_NAME" ]]; then
  echo "ERROR: --name is required."
  echo "Usage: $0 --name <spoke-name> [--delete-vnet] [--delete-rg]"
  echo ""
  echo "Known spokes:"
  jq -r '.spokes[].name // empty' "$CONFIG_FILE" | sed 's/^/  - /'
  exit 1
fi

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' "$CONFIG_FILE")
HUB_RG=$(jq -r '.hub.resourceGroupName' "$CONFIG_FILE")
HUB_VNET_NAME=$(jq -r '.hub.vnetName' "$CONFIG_FILE")

# Find spoke in config
SPOKE=$(jq --arg name "$SPOKE_NAME" '.spokes[] | select(.name == $name)' "$CONFIG_FILE")
if [[ -z "$SPOKE" ]]; then
  echo "ERROR: Spoke '$SPOKE_NAME' not found in .azure-debug-config.json"
  echo ""
  echo "Known spokes:"
  jq -r '.spokes[].name // empty' "$CONFIG_FILE" | sed 's/^/  - /'
  exit 1
fi

SPOKE_RG=$(echo "$SPOKE" | jq -r '.resourceGroupName')
SPOKE_VNET_NAME=$(echo "$SPOKE" | jq -r '.vnetName')
SPOKE_SUB=$(echo "$SPOKE" | jq -r '.subscriptionId // "'"$SUBSCRIPTION_ID"'"')

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Removing Spoke: $SPOKE_NAME"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  VNet:           $SPOKE_VNET_NAME"
echo "  Resource group: $SPOKE_RG"
echo "  Delete VNet:    $DELETE_VNET"
echo "  Delete RG:      $DELETE_RG"
echo ""

# Step 1: Remove spoke→hub peering
echo "── Step 1: Removing spoke → hub peering ──"
SPOKE_PEERING_NAME="hub-${HUB_VNET_NAME}"
if az network vnet peering show \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_PEERING_NAME" \
  --subscription "$SPOKE_SUB" \
  -o none 2>/dev/null; then
  az network vnet peering delete \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$SPOKE_PEERING_NAME" \
    --subscription "$SPOKE_SUB"
  echo "  ✅ Spoke → hub peering removed"
else
  echo "  ⚠️  Spoke → hub peering not found (already removed?)"
fi

# Step 2: Remove hub→spoke peering
echo ""
echo "── Step 2: Removing hub → spoke peering ──"
HUB_PEERING_NAME="spoke-${SPOKE_VNET_NAME}"
if az network vnet peering show \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET_NAME" \
  --name "$HUB_PEERING_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  -o none 2>/dev/null; then
  az network vnet peering delete \
    --resource-group "$HUB_RG" \
    --vnet-name "$HUB_VNET_NAME" \
    --name "$HUB_PEERING_NAME" \
    --subscription "$SUBSCRIPTION_ID"
  echo "  ✅ Hub → spoke peering removed"
else
  echo "  ⚠️  Hub → spoke peering not found (already removed?)"
fi

# Step 3: Delete VNet (optional)
if $DELETE_VNET && ! $DELETE_RG; then
  echo ""
  echo "── Step 3: Deleting VNet $SPOKE_VNET_NAME ──"
  az network vnet delete \
    --resource-group "$SPOKE_RG" \
    --name "$SPOKE_VNET_NAME" \
    --subscription "$SPOKE_SUB" 2>/dev/null || true
  echo "  ✅ VNet deleted"
fi

# Step 4: Delete resource group (optional)
if $DELETE_RG; then
  echo ""
  echo "── Step 3: Deleting resource group $SPOKE_RG ──"
  az group delete \
    --name "$SPOKE_RG" \
    --subscription "$SPOKE_SUB" \
    --yes --no-wait
  echo "  ✅ Resource group deletion initiated (async)"
fi

# Step 5: Update config
echo ""
echo "── Updating .azure-debug-config.json ──"
UPDATED_CONFIG=$(jq --arg name "$SPOKE_NAME" '.spokes = [.spokes[] | select(.name != $name)]' "$CONFIG_FILE")
echo "$UPDATED_CONFIG" > "$CONFIG_FILE"
echo "  ✅ Spoke removed from config"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Spoke '$SPOKE_NAME' removed"
echo "═══════════════════════════════════════════════════════"
echo ""
