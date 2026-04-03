#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-private-endpoints.sh — Verify private endpoint connectivity
#
# Lists private endpoints, checks their connection status, DNS config,
# and end-to-end connectivity on the service-appropriate port.
#
# Usage:
#   ./scripts/debug/check-private-endpoints.sh [resource-group]
#   ./scripts/debug/check-private-endpoints.sh --all          # scan hub + all spokes
#   ./scripts/debug/check-private-endpoints.sh --hostname myapp.azurewebsites.net
# -------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
source "$SCRIPT_DIR/load-config.sh"

check_help "check-private-endpoints.sh" "Check private endpoints and their connectivity" \
  "./scripts/debug/check-private-endpoints.sh [resource-group]" \
  "./scripts/debug/check-private-endpoints.sh --all" \
  "./scripts/debug/check-private-endpoints.sh --hostname <fqdn>"

SCAN_ALL=false
TARGET_RGS=()
LOOKUP_HOSTNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) SCAN_ALL=true; shift ;;
    --hostname) LOOKUP_HOSTNAME="$2"; shift 2 ;;
    *) TARGET_RGS+=("$1"); shift ;;
  esac
done

# Build list of RGs to scan
if $SCAN_ALL; then
  TARGET_RGS=("$DBG_HUB_RG")
  for i in $(seq 0 $((DBG_SPOKE_COUNT - 1))); do
    SPOKE_RG=$(jq -r ".spokes[$i].resourceGroupName" "$REPO_ROOT/.azure-debug-config.json")
    TARGET_RGS+=("$SPOKE_RG")
  done
elif [[ ${#TARGET_RGS[@]} -eq 0 ]]; then
  TARGET_RGS=("$DBG_HUB_RG")
fi

# Map PE group IDs to default service ports
port_for_group() {
  case "$1" in
    sites|sites-staging)              echo "443" ;;
    sqlServer)                        echo "1433" ;;
    mysqlServer|mariadbServer)        echo "3306" ;;
    postgresqlServer|flexibleServers) echo "5432" ;;
    vault)                            echo "443" ;;
    blob|blob_secondary)              echo "443" ;;
    file|file_secondary)              echo "445" ;;
    table|table_secondary|queue|queue_secondary) echo "443" ;;
    dfs|dfs_secondary)                echo "443" ;;
    web)                              echo "443" ;;
    namespace)                        echo "5671" ;;
    registry)                         echo "443" ;;
    managedInstance)                   echo "1433" ;;
    Sql)                              echo "443" ;;
    redisCache)                       echo "6380" ;;
    cosmosdb|Sql|MongoDB|Cassandra|Gremlin|Table) echo "443" ;;
    searchService)                    echo "443" ;;
    cognitiveservices|account)        echo "443" ;;
    management)                       echo "443" ;;
    *)                                echo "443" ;;
  esac
}

print_header "Private Endpoint Diagnostics"
if $SCAN_ALL; then
  echo "  Scanning: hub + ${DBG_SPOKE_COUNT} spoke(s)"
elif [[ -n "$LOOKUP_HOSTNAME" ]]; then
  echo "  Looking for PE matching: $LOOKUP_HOSTNAME"
fi

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required."
  exit 1
fi

ALL_PES="[]"

print_step 1 "Scanning resource groups"
for TARGET_RG in "${TARGET_RGS[@]}"; do
  echo ""
  echo "  Resource group: $TARGET_RG"
  RG_PES=$(az network private-endpoint list \
    --resource-group "$TARGET_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[].{name:name, resourceGroup:'$TARGET_RG', privateLinkServiceConnections:privateLinkServiceConnections[0].{status:privateLinkServiceConnectionState.status, resourceId:privateLinkServiceId, groupIds:groupIds}, customDnsConfigs:customDnsConfigs, networkInterfaces:networkInterfaces, subnet:subnet.id}" \
    -o json 2>/dev/null || echo "[]")

  RG_PE_COUNT=$(echo "$RG_PES" | jq length)
  echo "    Found $RG_PE_COUNT private endpoint(s)"

  ALL_PES=$(echo "$ALL_PES" "$RG_PES" | jq -s '.[0] + .[1]')
done

TOTAL_PE_COUNT=$(echo "$ALL_PES" | jq length)

if [[ "$TOTAL_PE_COUNT" -eq 0 ]]; then
  result WARN "No private endpoints found in scanned resource groups"
  echo "         → If you expect private endpoints, try: $0 --all"
  echo "         → Or specify the resource group: $0 <resource-group-name>"
else
  print_step 2 "Checking $TOTAL_PE_COUNT endpoint(s)"
  echo ""

  echo "$ALL_PES" | jq -c '.[]' | while read -r pe; do
    PE_NAME=$(echo "$pe" | jq -r '.name')
    PE_RG=$(echo "$pe" | jq -r '.resourceGroup')
    PE_STATUS=$(echo "$pe" | jq -r '.privateLinkServiceConnections.status // "unknown"')
    PE_RESOURCE=$(echo "$pe" | jq -r '.privateLinkServiceConnections.resourceId // "unknown"' | sed 's|.*/||')
    PE_GROUP=$(echo "$pe" | jq -r '.privateLinkServiceConnections.groupIds[0] // "unknown"')
    PE_SUBNET=$(echo "$pe" | jq -r '.subnet // "unknown"')
    PE_PORT=$(port_for_group "$PE_GROUP")

    # If looking for a specific hostname, filter by matching FQDN
    if [[ -n "$LOOKUP_HOSTNAME" ]]; then
      MATCH=$(echo "$pe" | jq -r '.customDnsConfigs[]?.fqdn // empty' 2>/dev/null | grep -i "$LOOKUP_HOSTNAME" || true)
      if [[ -z "$MATCH" ]]; then
        continue
      fi
    fi

    echo "  ┌─ Endpoint: $PE_NAME (RG: $PE_RG)"
    echo "  │  Resource: $PE_RESOURCE ($PE_GROUP)"
    echo "  │  Connection: $PE_STATUS"
    echo "  │  Expected port: $PE_PORT"

    if [[ "$PE_STATUS" == "Approved" ]]; then
      result PASS "Endpoint '$PE_NAME' connection is Approved"
    elif [[ "$PE_STATUS" == "Pending" ]]; then
      result WARN "Endpoint '$PE_NAME' connection is Pending (needs approval on the target resource)"
    else
      result FAIL "Endpoint '$PE_NAME' connection status: $PE_STATUS"
    fi

    # Check DNS config
    DNS_IPS=$(echo "$pe" | jq -r '.customDnsConfigs[]?.ipAddresses[]? // empty' 2>/dev/null)
    DNS_FQDNS=$(echo "$pe" | jq -r '.customDnsConfigs[]?.fqdn // empty' 2>/dev/null)
    if [[ -n "$DNS_IPS" ]]; then
      echo "  │  Private IPs: $(echo "$DNS_IPS" | tr '\n' ', ' | sed 's/,$//')"
    fi
    if [[ -n "$DNS_FQDNS" ]]; then
      echo "  │  FQDNs: $(echo "$DNS_FQDNS" | tr '\n' ', ' | sed 's/,$//')"
    fi

    # Get NIC private IP
    NIC_ID=$(echo "$pe" | jq -r '.networkInterfaces[0].id // empty')
    if [[ -n "$NIC_ID" ]]; then
      PE_IP=$(az network nic show \
        --ids "$NIC_ID" \
        --subscription "$DBG_SUBSCRIPTION_ID" \
        --query "ipConfigurations[0].privateIpAddress" \
        -o tsv 2>/dev/null || echo "unknown")
      echo "  │  NIC Private IP: $PE_IP"

      # Test connectivity on the service-appropriate port
      if [[ "$PE_IP" != "unknown" ]]; then
        if nc -z -w 5 "$PE_IP" "$PE_PORT" 2>/dev/null; then
          result PASS "Endpoint '$PE_NAME' IP $PE_IP reachable on port $PE_PORT"
        else
          result WARN "Endpoint '$PE_NAME' IP $PE_IP not reachable on port $PE_PORT"
          echo "  │  → Check: VPN connected? Spoke peered to hub? NSG allows inbound $PE_PORT?"
        fi
      fi
    fi

    # Subnet location check
    if [[ "$PE_SUBNET" != "unknown" && "$PE_SUBNET" != "null" ]]; then
      SUBNET_VNET=$(echo "$PE_SUBNET" | grep -oP 'virtualNetworks/\K[^/]+' || true)
      if [[ -n "$SUBNET_VNET" ]]; then
        echo "  │  VNet: $SUBNET_VNET"
      fi
    fi

    # Check DNS zone group (created by DINE policy)
    ZONE_GROUPS=$(az network private-endpoint dns-zone-group list \
      --endpoint-name "$PE_NAME" \
      --resource-group "$PE_RG" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --query "[].privateDnsZoneConfigs[].{zone:privateDnsZoneId}" \
      -o json 2>/dev/null || echo "[]")

    ZG_ZONES=$(echo "$ZONE_GROUPS" | jq -r '.[].zone // empty' 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/,$//')
    if [[ -n "$ZG_ZONES" ]]; then
      echo "  │  DNS zone group: $ZG_ZONES"
      result PASS "Endpoint '$PE_NAME' has DNS zone group (A records managed by policy)"
    else
      result WARN "Endpoint '$PE_NAME' has NO DNS zone group — DINE policy may not have evaluated yet"
      echo "  │  → A records won't exist until a DNS zone group is created"
      echo "  │  → Run: ./scripts/debug/check-dns-policy.sh --remediate"
    fi

    echo "  └──"
    echo ""
  done
fi

# DNS resolution cross-check
print_step 3 "DNS resolution cross-check"
echo "  Testing if private endpoint FQDNs resolve to private IPs..."
echo "$ALL_PES" | jq -r '.[] | .customDnsConfigs[]?.fqdn // empty' 2>/dev/null | sort -u | head -10 | while read -r fqdn; do
  [[ -z "$fqdn" ]] && continue
  if RESOLVED=$(nslookup "$fqdn" "$DBG_DNS_IP" 2>&1); then
    RESOLVED_IP=$(echo "$RESOLVED" | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    if [[ -n "$RESOLVED_IP" ]] && echo "$RESOLVED_IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
      result PASS "$fqdn → $RESOLVED_IP (private)"
    elif [[ -n "$RESOLVED_IP" ]]; then
      result WARN "$fqdn → $RESOLVED_IP (PUBLIC — private DNS zone may be missing or not linked)"
      echo "         → Check: az network private-dns zone list -g $DBG_HUB_RG --subscription $DBG_SUBSCRIPTION_ID -o table"
    fi
  else
    result WARN "Could not resolve $fqdn via DNS server at $DBG_DNS_IP"
  fi
done

print_summary \
  "DNS resolves to public IP? → ./scripts/debug/check-private-dns-zones.sh" \
  "TCP connection times out? → ./scripts/debug/check-vpn.sh or check-peerings.sh" \
  "Connection refused? → approve PE on target resource in Azure portal"
