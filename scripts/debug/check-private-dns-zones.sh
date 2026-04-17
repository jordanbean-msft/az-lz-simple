#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-private-dns-zones.sh — Verify private DNS zones and VNet links
#
# Lists all private DNS zones in the hub resource group, checks VNet
# links, and optionally checks if a specific zone exists for a service.
#
# Usage:
#   ./scripts/debug/check-private-dns-zones.sh
#   ./scripts/debug/check-private-dns-zones.sh privatelink.blob.core.windows.net
#   ./scripts/debug/check-private-dns-zones.sh --check-records myaccount.blob.core.windows.net
# -------------------------------------------------------------------
set -euo pipefail
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help "check-private-dns-zones.sh" "Verify private DNS zones and their VNet links" \
  "./scripts/debug/check-private-dns-zones.sh" \
  "./scripts/debug/check-private-dns-zones.sh <zone-name>" \
  "./scripts/debug/check-private-dns-zones.sh --check-records <hostname>"

ZONE_FILTER="${1:-}"

print_header "Private DNS Zone Diagnostics"

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required."
  exit 1
fi

# 1. List all private DNS zones (use cached list if available, always query live for record counts)
print_step 1 "Private DNS zones in $DBG_HUB_RG"

# Check if cached zones exist in config
CACHED_ZONES=$(jq -r '.privateDnsZones // [] | length' "$REPO_ROOT/.azure-debug-config.json")

ZONES=$(run_with_timeout 30 az network private-dns zone list \
  --resource-group "$DBG_HUB_RG" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "[].{name:name, numberOfRecordSets:numberOfRecordSets, numberOfVirtualNetworkLinks:numberOfVirtualNetworkLinks}" \
  -o json 2>/dev/null || echo "[]")

ZONE_COUNT=$(echo "$ZONES" | jq length)
echo "    Found $ZONE_COUNT private DNS zone(s)"

if [[ "$ZONE_COUNT" -eq 0 ]]; then
  result FAIL "No private DNS zones found in $DBG_HUB_RG"
  echo "         → Azure Policy may not have created zones yet."
  echo "         → Run: az deployment group create ... to trigger policy evaluation"
else
  echo ""
  echo "    Zone Name                                              Records  VNet Links"
  echo "    ─────────────────────────────────────────────────────   ───────  ──────────"
  echo "$ZONES" | jq -r '.[] | "    \(.name | . + " " * (56 - length))   \(.numberOfRecordSets | tostring | . + " " * (7 - length))  \(.numberOfVirtualNetworkLinks)"' 2>/dev/null || \
    echo "$ZONES" | jq -r '.[] | "    \(.name)  Records: \(.numberOfRecordSets)  Links: \(.numberOfVirtualNetworkLinks)"'
  result PASS "$ZONE_COUNT private DNS zone(s) found"
fi

# 2. Check VNet links for each zone (or specific zone)
print_step 2 "VNet link verification"

check_zone_links() {
  local zone_name="$1"
  LINKS=$(run_with_timeout 20 az network private-dns link vnet list \
    --resource-group "$DBG_HUB_RG" \
    --zone-name "$zone_name" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[].{name:name, vnetId:virtualNetwork.id, linkState:provisioningState, registrationEnabled:registrationEnabled}" \
    -o json 2>/dev/null || echo "[]")

  LINK_COUNT=$(echo "$LINKS" | jq length)
  if [[ "$LINK_COUNT" -eq 0 ]]; then
    result FAIL "Zone '$zone_name' has NO VNet links"
    echo "         → DNS queries for this zone won't resolve within the VNet."
  else
    HUB_LINKED=false
    echo "$LINKS" | jq -c '.[]' | while read -r link; do
      LINK_NAME=$(echo "$link" | jq -r '.name')
      LINK_VNET=$(echo "$link" | jq -r '.vnetId')
      LINK_STATE=$(echo "$link" | jq -r '.linkState')
      echo "    Link: $LINK_NAME → $(basename "$LINK_VNET") ($LINK_STATE)"
    done

    if echo "$LINKS" | jq -r '.[].vnetId' | tr '[:upper:]' '[:lower:]' | grep -qi "$DBG_HUB_VNET_NAME"; then
      result PASS "Zone '$zone_name' is linked to hub VNet"
    else
      result WARN "Zone '$zone_name' may not be linked to hub VNet '$DBG_HUB_VNET_NAME'"
    fi
  fi
}

if [[ -n "$ZONE_FILTER" && "$ZONE_FILTER" != --* ]]; then
  echo "  Checking zone: $ZONE_FILTER"
  if echo "$ZONES" | jq -r '.[].name' | grep -q "^${ZONE_FILTER}$"; then
    check_zone_links "$ZONE_FILTER"
  else
    result FAIL "Zone '$ZONE_FILTER' does not exist in $DBG_HUB_RG"
    echo "         → You may need to create a private endpoint to trigger zone creation via policy."
    echo "         → Or manually create: az network private-dns zone create -g $DBG_HUB_RG -n $ZONE_FILTER"
  fi
elif [[ "$ZONE_FILTER" == "--check-records" ]]; then
  HOSTNAME="${2:-}"
  if [[ -z "$HOSTNAME" ]]; then
    echo "  Usage: $0 --check-records <hostname>"
    exit 1
  fi
  echo "  Checking A records for $HOSTNAME across all private DNS zones..."
  echo "$ZONES" | jq -r '.[].name' | while read -r zone; do
    SHORTNAME="${HOSTNAME%%.$zone}"
    if [[ "$SHORTNAME" != "$HOSTNAME" ]]; then
      echo ""
      echo "  Zone: $zone → Record name: $SHORTNAME"
      RECORDS=$(run_with_timeout 20 az network private-dns record-set a show \
        --resource-group "$DBG_HUB_RG" \
        --zone-name "$zone" \
        --name "$SHORTNAME" \
        --subscription "$DBG_SUBSCRIPTION_ID" \
        --query "aRecords[].ipv4Address" \
        -o json 2>/dev/null || echo "[]")
      if [[ "$RECORDS" != "[]" ]]; then
        echo "    A records: $RECORDS"
        result PASS "Found A record for $SHORTNAME in $zone"
      else
        result WARN "No A record for $SHORTNAME in zone $zone"
      fi
    fi
  done
else
  # Check a sample of important zones
  IMPORTANT_ZONES=("privatelink.blob.core.windows.net" "privatelink.vaultcore.azure.net" "privatelink.azurewebsites.net" "privatelink.database.windows.net")
  for z in "${IMPORTANT_ZONES[@]}"; do
    if echo "$ZONES" | jq -r '.[].name' | grep -q "^${z}$"; then
      check_zone_links "$z"
    fi
  done
fi

# 3. Check Azure Policy for DNS zone creation
print_step 3 "Azure Policy assignments for DNS zones"
POLICY_ASSIGNMENTS=$(run_with_timeout 25 az policy assignment list \
  --resource-group "$DBG_HUB_RG" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "[?contains(displayName, 'dns') || contains(displayName, 'DNS') || contains(displayName, 'private')].{name:name, displayName:displayName, enforcementMode:enforcementMode}" \
  -o json 2>/dev/null || echo "[]")

PA_COUNT=$(echo "$POLICY_ASSIGNMENTS" | jq length)
if [[ "$PA_COUNT" -gt 0 ]]; then
  echo "    Found $PA_COUNT DNS-related policy assignment(s):"
  echo "$POLICY_ASSIGNMENTS" | jq -r '.[] | "    - \(.displayName // .name) (enforcement: \(.enforcementMode // "default"))"'
  result PASS "DNS zone policy assignments found"
else
  result WARN "No DNS-related policy assignments found in $DBG_HUB_RG"
  echo "         → Policy assignments may be at subscription scope. Checking..."
  SUB_POLICIES=$(run_with_timeout 25 az policy assignment list \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[?contains(displayName, 'dns') || contains(displayName, 'DNS') || contains(displayName, 'private')].{name:name, displayName:displayName}" \
    -o json 2>/dev/null || echo "[]")
  SUB_PA_COUNT=$(echo "$SUB_POLICIES" | jq length)
  if [[ "$SUB_PA_COUNT" -gt 0 ]]; then
    echo "    Found $SUB_PA_COUNT at subscription scope."
    result PASS "DNS policy assignments found at subscription scope"
  fi
fi

# Summary
print_summary \
  "1. Create missing private DNS zones manually or trigger via policy" \
  "2. Ensure zones are linked to the hub VNet" \
  "3. Check policy compliance: az policy state list --subscription $DBG_SUBSCRIPTION_ID"
