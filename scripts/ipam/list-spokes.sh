#!/usr/bin/env bash
# -------------------------------------------------------------------
# list-spokes.sh — List all spoke VNets and their peering status
#
# Reads hub config and queries Azure for all VNets peered to the hub.
#
# Usage:
#   ./scripts/ipam/list-spokes.sh
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' "$CONFIG_FILE")
HUB_RG=$(jq -r '.hub.resourceGroupName' "$CONFIG_FILE")
HUB_VNET_NAME=$(jq -r '.hub.vnetName' "$CONFIG_FILE")

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Hub-Spoke Network Inventory"
echo "═══════════════════════════════════════════════════════"
echo ""

# Hub info
HUB_SPACES=$(az network vnet show \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "addressSpace.addressPrefixes" \
  -o tsv 2>/dev/null || echo "unknown")

echo "  Hub: $HUB_VNET_NAME ($HUB_RG)"
echo "  Address space: $HUB_SPACES"
echo ""

# List peerings from hub
PEERINGS=$(az network vnet peering list \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[].{name:name, state:peeringState, remoteVnet:remoteVirtualNetwork.id, gatewayTransit:allowGatewayTransit}" \
  -o json 2>/dev/null || echo "[]")

PEERING_COUNT=$(echo "$PEERINGS" | jq length)

if [[ "$PEERING_COUNT" -eq 0 ]]; then
  echo "  No spoke VNets peered to hub."
else
  echo "  ┌──────────────────────────────────────────────────────────────────┐"
  printf "  │ %-20s %-14s %-10s %-16s │\n" "Spoke VNet" "Address Space" "Peering" "Gateway Transit"
  echo "  ├──────────────────────────────────────────────────────────────────┤"

  echo "$PEERINGS" | jq -c '.[]' | while read -r p; do
    REMOTE_ID=$(echo "$p" | jq -r '.remoteVnet')
    STATE=$(echo "$p" | jq -r '.state')
    GW=$(echo "$p" | jq -r '.gatewayTransit')
    REMOTE_NAME=$(basename "$REMOTE_ID")
    REMOTE_RG=$(echo "$REMOTE_ID" | grep -oP 'resourceGroups/\K[^/]+')
    REMOTE_SUB=$(echo "$REMOTE_ID" | grep -oP 'subscriptions/\K[^/]+')

    # Get address space
    REMOTE_SPACE=$(az network vnet show \
      --resource-group "$REMOTE_RG" \
      --name "$REMOTE_NAME" \
      --subscription "$REMOTE_SUB" \
      --query "addressSpace.addressPrefixes[0]" \
      -o tsv 2>/dev/null || echo "?")

    printf "  │ %-20s %-14s %-10s %-16s │\n" "$REMOTE_NAME" "$REMOTE_SPACE" "$STATE" "$GW"
  done

  echo "  └──────────────────────────────────────────────────────────────────┘"
fi

# Also show all VNets in subscription for context
echo ""
echo "── All VNets in subscription ──"
echo ""
az network vnet list \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[].{Name:name, ResourceGroup:resourceGroup, Location:location, AddressSpace:addressSpace.addressPrefixes[0]}" \
  -o table 2>/dev/null || echo "  Could not list VNets."
echo ""
