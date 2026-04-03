#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-peerings.sh — Verify VNet peerings between hub and spokes
#
# Checks that all spokes are peered to the hub with correct settings,
# and identifies missing or failed peerings.
#
# Usage:
#   ./scripts/debug/check-peerings.sh
#   ./scripts/debug/check-peerings.sh <spoke-vnet-resource-id>
# -------------------------------------------------------------------
set -euo pipefail
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help "check-peerings.sh" "Verify VNet peerings between hub and spokes" \
  "./scripts/debug/check-peerings.sh" \
  "./scripts/debug/check-peerings.sh <spoke-vnet-resource-id>"

SPECIFIC_SPOKE="${1:-}"

print_header "VNet Peering Diagnostics"

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required."
  exit 1
fi

# 1. List all peerings from the hub VNet
print_step 1 "Hub VNet peerings ($DBG_HUB_VNET_NAME)"
HUB_RG_LOWER=$(echo "$DBG_HUB_RG" | tr '[:upper:]' '[:lower:]')
PEERINGS=$(az network vnet peering list \
  --resource-group "$DBG_HUB_RG" \
  --vnet-name "$DBG_HUB_VNET_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "[].{name:name, peeringState:peeringState, remoteVnet:remoteVirtualNetwork.id, allowGatewayTransit:allowGatewayTransit, useRemoteGateways:useRemoteGateways, allowVirtualNetworkAccess:allowVirtualNetworkAccess, allowForwardedTraffic:allowForwardedTraffic}" \
  -o json 2>/dev/null || echo "[]")

PEERING_COUNT=$(echo "$PEERINGS" | jq length)
echo "    Found $PEERING_COUNT peering(s) from hub."

if [[ "$PEERING_COUNT" -eq 0 ]]; then
  result WARN "No peerings found on hub VNet"
  echo "         → If you have spoke VNets, they need to be peered to the hub."
else
  echo "$PEERINGS" | jq -c '.[]' | while read -r p; do
    NAME=$(echo "$p" | jq -r '.name')
    STATE=$(echo "$p" | jq -r '.peeringState')
    REMOTE=$(echo "$p" | jq -r '.remoteVnet')
    GW_TRANSIT=$(echo "$p" | jq -r '.allowGatewayTransit')
    ALLOW_ACCESS=$(echo "$p" | jq -r '.allowVirtualNetworkAccess')
    ALLOW_FWD=$(echo "$p" | jq -r '.allowForwardedTraffic')

    echo ""
    echo "    Peering: $NAME"
    echo "      Remote VNet: $REMOTE"
    echo "      State: $STATE"
    echo "      Gateway transit: $GW_TRANSIT | VNet access: $ALLOW_ACCESS | Forwarded traffic: $ALLOW_FWD"

    if [[ "$STATE" == "Connected" ]]; then
      result PASS "Peering '$NAME' is Connected"
    elif [[ "$STATE" == "Initiated" ]]; then
      result FAIL "Peering '$NAME' is Initiated (waiting for reciprocal peering)"
      echo "         → The spoke-to-hub peering may be missing. Create it with:"
      echo "         → az network vnet peering create ..."
    elif [[ "$STATE" == "Disconnected" ]]; then
      result FAIL "Peering '$NAME' is Disconnected"
      echo "         → The remote VNet may have been deleted or the peering was broken."
    else
      result WARN "Peering '$NAME' is in state: $STATE"
    fi

    if [[ "$GW_TRANSIT" != "true" ]]; then
      result WARN "Peering '$NAME' does not have allowGatewayTransit=true (spokes won't use hub VPN gateway)"
    fi
  done
fi

# 2. Check spoke-to-hub peerings (reverse direction)
print_step 2 "Spoke-to-hub peerings (reverse direction)"
if [[ -n "$SPECIFIC_SPOKE" ]]; then
  # Parse resource ID to get RG and VNet name
  SPOKE_RG=$(echo "$SPECIFIC_SPOKE" | grep -oP 'resourceGroups/\K[^/]+')
  SPOKE_VNET=$(echo "$SPECIFIC_SPOKE" | grep -oP 'virtualNetworks/\K[^/]+')
  SPOKE_SUB=$(echo "$SPECIFIC_SPOKE" | grep -oP 'subscriptions/\K[^/]+')

  echo "    Checking spoke: $SPOKE_VNET (RG: $SPOKE_RG)"
  SPOKE_PEERINGS=$(az network vnet peering list \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET" \
    --subscription "${SPOKE_SUB:-$DBG_SUBSCRIPTION_ID}" \
    --query "[?contains(remoteVirtualNetwork.id, '$DBG_HUB_VNET_NAME')].{name:name, peeringState:peeringState, useRemoteGateways:useRemoteGateways}" \
    -o json 2>/dev/null || echo "[]")

  if [[ $(echo "$SPOKE_PEERINGS" | jq length) -gt 0 ]]; then
    echo "$SPOKE_PEERINGS" | jq -c '.[]' | while read -r sp; do
      SP_NAME=$(echo "$sp" | jq -r '.name')
      SP_STATE=$(echo "$sp" | jq -r '.peeringState')
      SP_USE_GW=$(echo "$sp" | jq -r '.useRemoteGateways')
      echo "    Spoke peering: $SP_NAME  State: $SP_STATE  UseRemoteGateways: $SP_USE_GW"
      if [[ "$SP_STATE" == "Connected" ]]; then
        result PASS "Spoke-to-hub peering '$SP_NAME' is Connected"
      else
        result FAIL "Spoke-to-hub peering '$SP_NAME' is $SP_STATE"
      fi
      if [[ "$SP_USE_GW" != "true" ]]; then
        result WARN "Spoke peering does not use remote gateways (VPN traffic won't flow through hub)"
      fi
    done
  else
    result FAIL "No peering from spoke $SPOKE_VNET to hub found"
    echo "         → Create spoke-to-hub peering. See README.md for commands."
  fi
elif [[ "$DBG_SPOKE_COUNT" -gt 0 ]]; then
  for i in $(seq 0 $((DBG_SPOKE_COUNT - 1))); do
    SPOKE_VNET_ID=$(jq -r ".spokes[$i].vnetResourceId" "$REPO_ROOT/.azure-debug-config.json")
    SPOKE_VNET=$(jq -r ".spokes[$i].vnetName" "$REPO_ROOT/.azure-debug-config.json")
    SPOKE_RG=$(jq -r ".spokes[$i].resourceGroupName" "$REPO_ROOT/.azure-debug-config.json")
    SPOKE_SUB=$(jq -r ".spokes[$i].subscriptionId // \"$DBG_SUBSCRIPTION_ID\"" "$REPO_ROOT/.azure-debug-config.json")

    echo "    Checking spoke: $SPOKE_VNET (RG: $SPOKE_RG)"
    SPOKE_PEERINGS=$(az network vnet peering list \
      --resource-group "$SPOKE_RG" \
      --vnet-name "$SPOKE_VNET" \
      --subscription "$SPOKE_SUB" \
      --query "[].{name:name, peeringState:peeringState, remoteVnet:remoteVirtualNetwork.id, useRemoteGateways:useRemoteGateways}" \
      -o json 2>/dev/null || echo "[]")

    HUB_PEERING=$(echo "$SPOKE_PEERINGS" | jq -c "[.[] | select(.remoteVnet | ascii_downcase | contains(\"$DBG_HUB_VNET_NAME\" | ascii_downcase))]")
    if [[ $(echo "$HUB_PEERING" | jq length) -gt 0 ]]; then
      SP_STATE=$(echo "$HUB_PEERING" | jq -r '.[0].peeringState')
      if [[ "$SP_STATE" == "Connected" ]]; then
        result PASS "Spoke $SPOKE_VNET → hub peering is Connected"
      else
        result FAIL "Spoke $SPOKE_VNET → hub peering is $SP_STATE"
      fi
    else
      result FAIL "Spoke $SPOKE_VNET has no peering to hub VNet"
    fi
  done
else
  echo "  No spokes defined in .azure-debug-config.json. Skipping reverse check."
  echo "  To check a specific spoke, run: ./scripts/debug/check-peerings.sh <spoke-vnet-resource-id>"
fi

# 3. Check spoke-to-spoke connectivity note
print_step 3 "Spoke-to-spoke connectivity"
echo "  ℹ️  This landing zone does NOT force-tunnel all traffic through the hub."
echo "  If two spoke VNets need to communicate directly, they must be peered"
echo "  to each other (mesh peering) in addition to their hub peerings."
echo "  Use: az network vnet peering create (both directions) between the spoke VNets."

# 4. Check hub VNet DNS settings (use cached address space if available)
print_step 4 "Hub VNet DNS configuration"

if [[ -n "$DBG_HUB_ADDRESS_SPACE" ]]; then
  echo "    Hub VNet address space: $DBG_HUB_ADDRESS_SPACE (cached)"
fi

HUB_DNS=$(az network vnet show \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_HUB_VNET_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "dhcpOptions.dnsServers" \
  -o json 2>/dev/null || echo "[]")

if [[ "$HUB_DNS" == "[]" || "$HUB_DNS" == "null" ]]; then
  echo "    Hub VNet uses Azure default DNS (168.63.129.16)"
  result PASS "Hub VNet uses default Azure DNS (correct — the DNS VM handles forwarding)"
else
  echo "    Hub VNet custom DNS servers: $HUB_DNS"
  result PASS "Hub VNet has custom DNS configured: $HUB_DNS"
fi

# Summary
print_summary \
  "1. Create missing peerings (see README.md 'Create a new spoke vNet')" \
  "2. Ensure spoke peerings have --use-remote-gateways" \
  "3. Ensure hub peerings have --allow-gateway-transit"
