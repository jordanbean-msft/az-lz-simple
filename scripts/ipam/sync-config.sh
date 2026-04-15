#!/usr/bin/env bash
# -------------------------------------------------------------------
# sync-config.sh — Reconcile .azure-debug-config.json with live Azure state
#
# Queries Azure for the current hub peerings and validates that every
# spoke in the config still exists. Removes stale spokes and adds any
# peered VNets that are missing from the config.
#
# Usage:
#   ./scripts/ipam/sync-config.sh          # interactive (prompts before changes)
#   ./scripts/ipam/sync-config.sh --yes    # auto-apply all changes
#   ./scripts/ipam/sync-config.sh --dry-run # show what would change
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"

MODE="interactive"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) MODE="auto"; shift ;;
    --dry-run) MODE="dry"; shift ;;
    *) shift ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found."
  echo "Copy .azure-debug-config.example.json to .azure-debug-config.json and fill in your values."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: sudo apt-get install -y jq"
  exit 1
fi

SUBSCRIPTION_ID=$(jq -r '.subscriptionId' "$CONFIG_FILE")
HUB_RG=$(jq -r '.hub.resourceGroupName' "$CONFIG_FILE")
HUB_VNET_NAME=$(jq -r '.hub.vnetName' "$CONFIG_FILE")
DNS_VM_NAME=$(jq -r '.hub.dnsServerVmName' "$CONFIG_FILE")

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Syncing .azure-debug-config.json with Azure"
echo "═══════════════════════════════════════════════════════"
echo ""

CHANGES=0
UPDATED_CONFIG=$(cat "$CONFIG_FILE")

# ── 1. Validate hub resources still exist ──
echo "── Validating hub resources ──"

HUB_RG_EXISTS=$(az group show --name "$HUB_RG" --subscription "$SUBSCRIPTION_ID" --query "name" -o tsv 2>/dev/null || echo "")
if [[ -z "$HUB_RG_EXISTS" ]]; then
  echo "  ❌ Hub resource group '$HUB_RG' no longer exists!"
  echo "     Update .azure-debug-config.json manually with your new hub details."
  exit 1
fi
echo "  ✅ Hub resource group exists"

HUB_VNET_EXISTS=$(az network vnet show --resource-group "$HUB_RG" --name "$HUB_VNET_NAME" --subscription "$SUBSCRIPTION_ID" --query "name" -o tsv 2>/dev/null || echo "")
if [[ -z "$HUB_VNET_EXISTS" ]]; then
  echo "  ❌ Hub VNet '$HUB_VNET_NAME' no longer exists!"
  echo "     Update .azure-debug-config.json manually with your new hub details."
  exit 1
fi
echo "  ✅ Hub VNet exists"

# ── 2. Refresh hub VNet address space and subnets ──
echo ""
echo "── Refreshing hub VNet details ──"

HUB_VNET_INFO=$(az network vnet show \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "{addressSpace:addressSpace.addressPrefixes[0], subnets:subnets[].{name:name, addressPrefix:addressPrefix}}" \
  -o json 2>/dev/null || echo "{}")

if [[ -n "$HUB_VNET_INFO" && "$HUB_VNET_INFO" != "{}" ]]; then
  LIVE_ADDRESS_SPACE=$(echo "$HUB_VNET_INFO" | jq -r '.addressSpace // ""')
  CONFIG_ADDRESS_SPACE=$(echo "$UPDATED_CONFIG" | jq -r '.hub.addressSpace // ""')
  if [[ -n "$LIVE_ADDRESS_SPACE" && "$LIVE_ADDRESS_SPACE" != "$CONFIG_ADDRESS_SPACE" ]]; then
    echo "  ⚠️  Hub address space changed: ${CONFIG_ADDRESS_SPACE:-<empty>} → $LIVE_ADDRESS_SPACE"
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --arg s "$LIVE_ADDRESS_SPACE" '.hub.addressSpace = $s')
    ((CHANGES+=1))
  else
    echo "  ✅ Hub address space is current ($LIVE_ADDRESS_SPACE)"
  fi

  LIVE_SUBNETS=$(echo "$HUB_VNET_INFO" | jq -c '.subnets // []')
  CONFIG_SUBNETS=$(echo "$UPDATED_CONFIG" | jq -c '.hub.subnets // []')
  if [[ "$LIVE_SUBNETS" != "$CONFIG_SUBNETS" ]]; then
    SUBNET_COUNT=$(echo "$LIVE_SUBNETS" | jq length)
    echo "  ⚠️  Hub subnets updated ($SUBNET_COUNT subnet(s))"
    echo "$LIVE_SUBNETS" | jq -r '.[] | "    - \(.name): \(.addressPrefix)"'
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --argjson s "$LIVE_SUBNETS" '.hub.subnets = $s')
    ((CHANGES+=1))
  else
    echo "  ✅ Hub subnets are current"
  fi
else
  echo "  ⚠️  Could not query hub VNet details — config unchanged"
fi

# ── 3. Refresh VPN Gateway info ──
echo ""
echo "── Refreshing VPN Gateway info ──"

VPN_GW_INFO=$(az network vnet-gateway list \
  --resource-group "$HUB_RG" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[0].{name:name, id:id, sku:sku.name, p2s:vpnClientConfiguration.vpnClientAddressPool.addressPrefixes}" \
  -o json 2>/dev/null || echo "{}")

if [[ -n "$VPN_GW_INFO" && "$VPN_GW_INFO" != "{}" && "$VPN_GW_INFO" != "null" ]]; then
  LIVE_GW_NAME=$(echo "$VPN_GW_INFO" | jq -r '.name // ""')
  CONFIG_GW_NAME=$(echo "$UPDATED_CONFIG" | jq -r '.hub.vpnGateway.name // ""')
  if [[ -n "$LIVE_GW_NAME" && "$LIVE_GW_NAME" != "null" ]]; then
    LIVE_GW_ID=$(echo "$VPN_GW_INFO" | jq -r '.id // ""')
    LIVE_GW_SKU=$(echo "$VPN_GW_INFO" | jq -r '.sku // ""')
    LIVE_P2S=$(echo "$VPN_GW_INFO" | jq -c '.p2s // []')
    echo "    Gateway: $LIVE_GW_NAME  SKU: $LIVE_GW_SKU  P2S pool: $LIVE_P2S"

    if [[ "$LIVE_GW_NAME" != "$CONFIG_GW_NAME" ]]; then
      UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq \
        --arg name "$LIVE_GW_NAME" \
        --arg id "$LIVE_GW_ID" \
        --arg sku "$LIVE_GW_SKU" \
        --argjson p2s "$LIVE_P2S" \
        '.hub.vpnGateway = {name: $name, resourceId: $id, sku: $sku, p2sAddressPool: $p2s}')
      ((CHANGES+=1))
      echo "  ⚠️  VPN Gateway config updated"
    else
      # Still refresh sku and p2s in case they changed
      CONFIG_GW_SKU=$(echo "$UPDATED_CONFIG" | jq -r '.hub.vpnGateway.sku // ""')
      CONFIG_P2S=$(echo "$UPDATED_CONFIG" | jq -c '.hub.vpnGateway.p2sAddressPool // []')
      if [[ "$LIVE_GW_SKU" != "$CONFIG_GW_SKU" || "$LIVE_P2S" != "$CONFIG_P2S" ]]; then
        UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq \
          --arg sku "$LIVE_GW_SKU" \
          --argjson p2s "$LIVE_P2S" \
          '.hub.vpnGateway.sku = $sku | .hub.vpnGateway.p2sAddressPool = $p2s')
        ((CHANGES+=1))
        echo "  ⚠️  VPN Gateway SKU/P2S pool updated"
      else
        echo "  ✅ VPN Gateway info is current"
      fi
    fi
  else
    echo "  ⚠️  No VPN Gateway found in $HUB_RG"
  fi
else
  echo "  ⚠️  Could not query VPN Gateway — config unchanged"
fi

# ── 4. Refresh DNS server IP from Azure ──
echo ""
echo "── Refreshing DNS server IP ──"

DNS_VM_EXISTS=$(az vm show --resource-group "$HUB_RG" --name "$DNS_VM_NAME" --subscription "$SUBSCRIPTION_ID" --query "name" -o tsv 2>/dev/null || echo "")
if [[ -n "$DNS_VM_EXISTS" ]]; then
  LIVE_DNS_IP=$(az vm show --resource-group "$HUB_RG" --name "$DNS_VM_NAME" --subscription "$SUBSCRIPTION_ID" --show-details --query "privateIps" -o tsv 2>/dev/null || echo "")
  CONFIG_DNS_IP=$(echo "$UPDATED_CONFIG" | jq -r '.hub.dnsServerPrivateIp')
  if [[ -n "$LIVE_DNS_IP" && "$LIVE_DNS_IP" != "$CONFIG_DNS_IP" ]]; then
    echo "  ⚠️  DNS server IP changed: $CONFIG_DNS_IP → $LIVE_DNS_IP"
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --arg ip "$LIVE_DNS_IP" '.hub.dnsServerPrivateIp = $ip')
    ((CHANGES+=1))
  else
    echo "  ✅ DNS server IP is current ($CONFIG_DNS_IP)"
  fi
else
  echo "  ⚠️  DNS server VM '$DNS_VM_NAME' not found — config unchanged"
fi

# ── 4b. Discover GitHub Actions runner VM ──
echo ""
echo "── Refreshing GitHub Actions runner VM ──"

CONFIG_GHA_NAME=$(echo "$UPDATED_CONFIG" | jq -r '.hub.ghaRunnerVmName // ""')
if [[ -z "$CONFIG_GHA_NAME" || "$CONFIG_GHA_NAME" == "null" ]]; then
  # Discover by naming convention (common patterns): vm-gha-*, *gha*, *runner*
  GHA_VM=$(az vm list --resource-group "$HUB_RG" --subscription "$SUBSCRIPTION_ID" \
    --query "[?contains(to_lower(name), 'gha') || contains(to_lower(name), 'runner')].{name:name, id:id}" \
    -o json 2>/dev/null || echo "[]")
  GHA_COUNT=$(echo "$GHA_VM" | jq length)
  if [[ "$GHA_COUNT" -gt 0 ]]; then
    LIVE_GHA_NAME=$(echo "$GHA_VM" | jq -r '.[0].name')
    LIVE_GHA_ID=$(echo "$GHA_VM" | jq -r '.[0].id')
    echo "  ➕ Discovered GHA runner VM: $LIVE_GHA_NAME"
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq \
      --arg name "$LIVE_GHA_NAME" \
      --arg id "$LIVE_GHA_ID" \
      '.hub.ghaRunnerVmName = $name | .hub.ghaRunnerVmResourceId = $id')
    ((CHANGES+=1))
  else
    echo "  ⚠️  No GHA runner VM (gha/runner naming patterns) found in $HUB_RG"
  fi
else
  # Verify it still exists
  GHA_EXISTS=$(az vm show --resource-group "$HUB_RG" --name "$CONFIG_GHA_NAME" --subscription "$SUBSCRIPTION_ID" --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -n "$GHA_EXISTS" ]]; then
    echo "  ✅ GHA runner VM exists ($CONFIG_GHA_NAME)"
  else
    echo "  ⚠️  GHA runner VM '$CONFIG_GHA_NAME' no longer exists — clearing from config"
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq '.hub.ghaRunnerVmName = "" | .hub.ghaRunnerVmResourceId = ""')
    ((CHANGES+=1))
  fi
fi

# ── 5. Remove stale spokes ──
echo ""
echo "── Checking for stale spokes ──"

SPOKE_COUNT=$(echo "$UPDATED_CONFIG" | jq '.spokes | length')
STALE_SPOKES=()

for i in $(seq 0 $((SPOKE_COUNT - 1))); do
  SPOKE_NAME=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].name")
  SPOKE_RG=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].resourceGroupName")
  SPOKE_VNET=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].vnetName")
  SPOKE_SUB=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].subscriptionId // \"$SUBSCRIPTION_ID\"")

  # Check if the RG still exists
  RG_EXISTS=$(az group show --name "$SPOKE_RG" --subscription "$SPOKE_SUB" --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$RG_EXISTS" ]]; then
    echo "  ❌ Spoke '$SPOKE_NAME': resource group '$SPOKE_RG' no longer exists"
    STALE_SPOKES+=("$SPOKE_NAME")
    continue
  fi

  # Check if the VNet still exists
  VNET_EXISTS=$(az network vnet show --resource-group "$SPOKE_RG" --name "$SPOKE_VNET" --subscription "$SPOKE_SUB" --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$VNET_EXISTS" ]]; then
    echo "  ❌ Spoke '$SPOKE_NAME': VNet '$SPOKE_VNET' no longer exists"
    STALE_SPOKES+=("$SPOKE_NAME")
    continue
  fi

  echo "  ✅ Spoke '$SPOKE_NAME' ($SPOKE_VNET) exists"
done

for stale in "${STALE_SPOKES[@]}"; do
  UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --arg name "$stale" '.spokes = [.spokes[] | select(.name != $name)]')
  ((CHANGES+=1))
done

if [[ ${#STALE_SPOKES[@]} -gt 0 ]]; then
  echo "  Removing ${#STALE_SPOKES[@]} stale spoke(s): ${STALE_SPOKES[*]}"
fi

# ── 6. Discover unregistered spokes from hub peerings ──
echo ""
echo "── Discovering unregistered spokes from hub peerings ──"

PEERINGS=$(az network vnet peering list \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[].{name:name, state:peeringState, remoteVnet:remoteVirtualNetwork.id}" \
  -o json 2>/dev/null || echo "[]")

PEERING_COUNT=$(echo "$PEERINGS" | jq length)

for i in $(seq 0 $((PEERING_COUNT - 1))); do
  REMOTE_ID=$(echo "$PEERINGS" | jq -r ".[$i].remoteVnet")
  PEER_STATE=$(echo "$PEERINGS" | jq -r ".[$i].state")
  REMOTE_VNET=$(basename "$REMOTE_ID")
  REMOTE_RG=$(echo "$REMOTE_ID" | grep -oP 'resourceGroups/\K[^/]+')
  REMOTE_SUB=$(echo "$REMOTE_ID" | grep -oP 'subscriptions/\K[^/]+')

  # Check if this spoke is already in config
  ALREADY_REGISTERED=$(echo "$UPDATED_CONFIG" | jq --arg vnet "$REMOTE_VNET" '[.spokes[] | select(.vnetName == $vnet)] | length')
  if [[ "$ALREADY_REGISTERED" -gt 0 ]]; then
    continue
  fi

  # It's a peered VNet not in our config — check if it still exists
  VNET_INFO=$(az network vnet show \
    --resource-group "$REMOTE_RG" \
    --name "$REMOTE_VNET" \
    --subscription "$REMOTE_SUB" \
    --query "{location:location, addressSpace:addressSpace.addressPrefixes[0]}" \
    -o json 2>/dev/null || echo "{}")

  if [[ "$VNET_INFO" == "{}" ]]; then
    echo "  ⚠️  Peered VNet '$REMOTE_VNET' no longer exists (stale peering)"
    continue
  fi

  REMOTE_LOCATION=$(echo "$VNET_INFO" | jq -r '.location')
  REMOTE_SPACE=$(echo "$VNET_INFO" | jq -r '.addressSpace // "unknown"')

  # Derive a spoke name from the VNet name
  SPOKE_NAME=$(echo "$REMOTE_VNET" | sed -E 's/^vnet-//' | sed -E "s/-${REMOTE_LOCATION}$//" | sed -E 's/-[a-z0-9]{10,}$//')
  if [[ -z "$SPOKE_NAME" || "$SPOKE_NAME" == "$REMOTE_VNET" ]]; then
    SPOKE_NAME="$REMOTE_VNET"
  fi

  echo "  ➕ Found unregistered spoke: $REMOTE_VNET ($REMOTE_SPACE, $PEER_STATE)"

  UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq \
    --arg name "$SPOKE_NAME" \
    --arg rg "$REMOTE_RG" \
    --arg sub "$REMOTE_SUB" \
    --arg vnetId "$REMOTE_ID" \
    --arg vnetName "$REMOTE_VNET" \
    --arg addressSpace "$REMOTE_SPACE" \
    --arg location "$REMOTE_LOCATION" \
    '.spokes += [{
      name: $name,
      resourceGroupName: $rg,
      subscriptionId: $sub,
      vnetResourceId: $vnetId,
      vnetName: $vnetName,
      addressSpace: $addressSpace,
      location: $location
    }]')
  ((CHANGES+=1))
done

# ── 7. Refresh spoke address spaces for existing spokes ──
echo ""
echo "── Refreshing spoke address spaces ──"

SPOKE_COUNT_NOW=$(echo "$UPDATED_CONFIG" | jq '.spokes | length')
for i in $(seq 0 $((SPOKE_COUNT_NOW - 1))); do
  S_NAME=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].name")
  S_VNET=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].vnetName")
  S_RG=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].resourceGroupName")
  S_SUB=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].subscriptionId // \"$SUBSCRIPTION_ID\"")
  S_SPACE=$(echo "$UPDATED_CONFIG" | jq -r ".spokes[$i].addressSpace // \"\"")

  if [[ -z "$S_SPACE" || "$S_SPACE" == "null" ]]; then
    LIVE_SPACE=$(az network vnet show --resource-group "$S_RG" --name "$S_VNET" --subscription "$S_SUB" \
      --query "addressSpace.addressPrefixes[0]" -o tsv 2>/dev/null || echo "")
    if [[ -n "$LIVE_SPACE" ]]; then
      echo "  ➕ Spoke '$S_NAME': address space → $LIVE_SPACE"
      UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --arg idx "$i" --arg s "$LIVE_SPACE" '.spokes[$idx | tonumber].addressSpace = $s')
      ((CHANGES+=1))
    fi
  fi
done

# ── 8. Refresh private DNS zones ──
echo ""
echo "── Refreshing private DNS zones ──"

LIVE_ZONES=$(az network private-dns zone list \
  --resource-group "$HUB_RG" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[].name" \
  -o json 2>/dev/null || echo "[]")

CONFIG_ZONES=$(echo "$UPDATED_CONFIG" | jq -c '.privateDnsZones // []')
if [[ "$LIVE_ZONES" != "$CONFIG_ZONES" ]]; then
  ZONE_COUNT=$(echo "$LIVE_ZONES" | jq length)
  echo "  ⚠️  Private DNS zones updated ($ZONE_COUNT zone(s))"
  echo "$LIVE_ZONES" | jq -r '.[]' | head -10 | sed 's/^/    - /'
  if [[ "$ZONE_COUNT" -gt 10 ]]; then
    echo "    ... and $((ZONE_COUNT - 10)) more"
  fi
  UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --argjson z "$LIVE_ZONES" '.privateDnsZones = $z')
  ((CHANGES+=1))
else
  echo "  ✅ Private DNS zones are current ($(echo "$CONFIG_ZONES" | jq length) zone(s))"
fi

# ── 9. Detect Windows VPN adapter name (if running in WSL2) ──
echo ""
echo "── Detecting Windows VPN adapter ──"

CONFIG_VPN_ADAPTER=$(echo "$UPDATED_CONFIG" | jq -r '.local.vpnAdapterName // ""')
if command -v powershell.exe &>/dev/null; then
  LIVE_VPN_ADAPTER=$(powershell.exe -NoProfile -Command "Get-NetAdapter | Where-Object { \$_.InterfaceDescription -like '*VPN*' -or \$_.InterfaceDescription -like '*TAP*' -or \$_.InterfaceDescription -like '*WireGuard*' -or \$_.Name -like '*Azure*' } | Select-Object -First 1 -ExpandProperty Name" 2>/dev/null | tr -d '\r' || echo "")
  if [[ -n "$LIVE_VPN_ADAPTER" && "$LIVE_VPN_ADAPTER" != "$CONFIG_VPN_ADAPTER" ]]; then
    echo "  ⚠️  VPN adapter name: ${CONFIG_VPN_ADAPTER:-<empty>} → $LIVE_VPN_ADAPTER"
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --arg a "$LIVE_VPN_ADAPTER" '.local.vpnAdapterName = $a')
    ((CHANGES+=1))
  elif [[ -n "$LIVE_VPN_ADAPTER" ]]; then
    echo "  ✅ VPN adapter name is current ($LIVE_VPN_ADAPTER)"
  else
    echo "  ⚠️  No VPN adapter detected on Windows host (VPN may not be connected)"
  fi
else
  echo "  ⚠️  powershell.exe not available — skipping VPN adapter detection"
fi

# ── 10. Apply changes ──
echo ""
if [[ "$CHANGES" -eq 0 ]]; then
  echo "═══════════════════════════════════════════════════════"
  echo "  ✅ Config is already in sync — no changes needed"
  echo "═══════════════════════════════════════════════════════"
  exit 0
fi

echo "── $CHANGES change(s) detected ──"
echo ""

# Show diff
CURRENT_SPOKES=$(jq -r '[.spokes[].name] | join(", ")' "$CONFIG_FILE")
NEW_SPOKES=$(echo "$UPDATED_CONFIG" | jq -r '[.spokes[].name] | join(", ")')
echo "  Current spokes: ${CURRENT_SPOKES:-<none>}"
echo "  Updated spokes: ${NEW_SPOKES:-<none>}"
echo ""

if [[ "$MODE" == "dry" ]]; then
  echo "  DRY RUN — no changes written."
  echo "$UPDATED_CONFIG" | jq '.spokes' | sed 's/^/  /'
  exit 0
fi

if [[ "$MODE" == "interactive" ]]; then
  read -rp "  Apply changes? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "  Aborted."
    exit 0
  fi
fi

echo "$UPDATED_CONFIG" | jq . > "$CONFIG_FILE"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Config synced ($CHANGES change(s) applied)"
echo "═══════════════════════════════════════════════════════"
echo ""
