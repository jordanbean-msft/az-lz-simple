#!/usr/bin/env bash
# -------------------------------------------------------------------
# trace-resource.sh — Trace private networking chain for an Azure resource
#
# Given a resource ID, traces the full connectivity path:
#   Resource → FQDN → Private Endpoint → NIC/IP → VNet → Peering → DNS → TCP
#
# Usage:
#   ./scripts/debug/trace-resource.sh <resource-id>
#   ./scripts/debug/trace-resource.sh /subscriptions/.../providers/Microsoft.Web/sites/myapp
# -------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
source "$SCRIPT_DIR/load-config.sh"

check_help "trace-resource.sh" "Trace private networking chain for an Azure resource" \
  "./scripts/debug/trace-resource.sh <resource-id>"

RESOURCE_ID="${1:-}"

if [[ -z "$RESOURCE_ID" ]]; then
  echo "ERROR: Resource ID is required."
  echo "Usage: ./scripts/debug/trace-resource.sh <resource-id>"
  echo ""
  echo "Example: ./scripts/debug/trace-resource.sh /subscriptions/abc/resourceGroups/rg/providers/Microsoft.Web/sites/myapp"
  exit 1
fi

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required."
  exit 1
fi

# Parse resource ID components
RESOURCE_SUB=$(echo "$RESOURCE_ID" | grep -oP 'subscriptions/\K[^/]+' || true)
RESOURCE_RG=$(echo "$RESOURCE_ID" | grep -oP 'resourceGroups/\K[^/]+' || true)
RESOURCE_PROVIDER=$(echo "$RESOURCE_ID" | grep -oP 'providers/\K[^/]+' || true)
RESOURCE_TYPE=$(echo "$RESOURCE_ID" | grep -oP 'providers/[^/]+/\K[^/]+' || true)
RESOURCE_NAME=$(echo "$RESOURCE_ID" | awk -F'/' '{print $NF}')

if [[ -z "$RESOURCE_SUB" || -z "$RESOURCE_RG" || -z "$RESOURCE_NAME" ]]; then
  echo "ERROR: Could not parse resource ID. Expected format:"
  echo "  /subscriptions/{sub}/resourceGroups/{rg}/providers/{provider}/{type}/{name}"
  exit 1
fi

print_header "Resource Network Trace"
echo "  Resource: $RESOURCE_NAME"
echo "  Type:     $RESOURCE_PROVIDER/$RESOURCE_TYPE"
echo "  RG:       $RESOURCE_RG"
echo "  Sub:      $RESOURCE_SUB"

# ─────────────────────────────────────────────────────────
# Step 1: Get resource details and determine FQDN
# ─────────────────────────────────────────────────────────
print_step 1 "Resource details and FQDN"

FQDN=""

# Try common FQDN property paths based on resource type
fqdn_from_resource() {
  local props
  props=$(run_with_timeout 25 az resource show --ids "$RESOURCE_ID" -o json 2>/dev/null) || return 1

  # Try well-known property paths (ordered most-specific first)
  local candidates=(
    '.properties.defaultHostName'
    '.properties.fullyQualifiedDomainName'
    '.properties.hostName'
    '.properties.vaultUri'
    '.properties.hsmUri'
    '.properties.endpoint'
    '.properties.loginServer'
    '.properties.host'
    '.properties.hostUri'
    '.properties.gatewayUrl'
    '.properties.workspaceUrl'
    '.properties.discoveryUrl'
    '.properties.scoringUri'
    '.properties.primaryEndpoints.blob'
    '.properties.primaryEndpoints.web'
    '.properties.primaryEndpoints.dfs'
    '.properties.primaryEndpoints.queue'
    '.properties.primaryEndpoints.table'
    '.properties.primaryEndpoints.file'
  )

  for path in "${candidates[@]}"; do
    local val
    val=$(echo "$props" | jq -r "$path // empty" 2>/dev/null)
    if [[ -n "$val" && "$val" != "null" ]]; then
      # Strip https:// prefix and trailing slash if present
      val=$(echo "$val" | sed 's|^https\?://||; s|/$||')
      echo "$val"
      return 0
    fi
  done

  # Fallback: construct FQDN from resource type when property paths fail.
  # Organized by RESOURCE_TYPE with RESOURCE_PROVIDER disambiguation where
  # multiple providers share the same type name (e.g., "servers", "workspaces").
  case "$RESOURCE_TYPE" in
    # ── Web & App Hosting ──
    sites)                echo "${RESOURCE_NAME}.azurewebsites.net" ;;
    staticSites)          echo "${RESOURCE_NAME}.azurestaticapps.net" ;;

    # ── Storage ──
    storageAccounts)      echo "${RESOURCE_NAME}.blob.core.windows.net" ;;
    storageSyncServices)  echo "${RESOURCE_NAME}.afs.azure.net" ;;

    # ── Relational Databases (provider-dependent) ──
    servers)
      case "$RESOURCE_PROVIDER" in
        Microsoft.Sql)             echo "${RESOURCE_NAME}.database.windows.net" ;;
        Microsoft.DBforMySQL)      echo "${RESOURCE_NAME}.mysql.database.azure.com" ;;
        Microsoft.DBforPostgreSQL) echo "${RESOURCE_NAME}.postgres.database.azure.com" ;;
        Microsoft.DBforMariaDB)    echo "${RESOURCE_NAME}.mariadb.database.azure.com" ;;
        *) echo "${RESOURCE_NAME}.database.windows.net" ;;
      esac ;;
    flexibleServers)
      case "$RESOURCE_PROVIDER" in
        Microsoft.DBforMySQL)      echo "${RESOURCE_NAME}.mysql.database.azure.com" ;;
        Microsoft.DBforPostgreSQL) echo "${RESOURCE_NAME}.postgres.database.azure.com" ;;
        *) return 1 ;;
      esac ;;

    # ── Cosmos DB ──
    databaseAccounts)     echo "${RESOURCE_NAME}.documents.azure.com" ;;

    # ── Key Vault & HSM ──
    vaults)
      case "$RESOURCE_PROVIDER" in
        Microsoft.KeyVault)         echo "${RESOURCE_NAME}.vault.azure.net" ;;
        Microsoft.RecoveryServices) return 1 ;; # Recovery Services has no standard FQDN
        *) echo "${RESOURCE_NAME}.vault.azure.net" ;;
      esac ;;
    managedHSMs)          echo "${RESOURCE_NAME}.managedhsm.azure.net" ;;

    # ── Messaging (EventHub, ServiceBus, Relay share the same namespace FQDN pattern) ──
    namespaces)           echo "${RESOURCE_NAME}.servicebus.windows.net" ;;

    # ── Container ──
    registries)           echo "${RESOURCE_NAME}.azurecr.io" ;;
    managedClusters)      return 1 ;; # AKS FQDN is dynamic/regional; use property path
    ManagedEnvironments)  return 1 ;; # Container Apps env; each app has its own FQDN

    # ── AI, Cognitive Services & Azure OpenAI ──
    accounts)
      case "$RESOURCE_PROVIDER" in
        Microsoft.CognitiveServices) echo "${RESOURCE_NAME}.cognitiveservices.azure.com" ;;
        Microsoft.Storage)           echo "${RESOURCE_NAME}.blob.core.windows.net" ;;
        Microsoft.Purview)           echo "${RESOURCE_NAME}.purview.azure.com" ;;
        *) return 1 ;;
      esac ;;

    # ── AI Foundry, ML, Synapse, Databricks, Healthcare (all use "workspaces") ──
    workspaces)
      case "$RESOURCE_PROVIDER" in
        Microsoft.MachineLearningServices) echo "${RESOURCE_NAME}.api.azureml.ms" ;;
        Microsoft.Synapse)                 echo "${RESOURCE_NAME}.dev.azuresynapse.net" ;;
        Microsoft.Databricks)              echo "${RESOURCE_NAME}.azuredatabricks.net" ;;
        Microsoft.HealthcareApis)          echo "${RESOURCE_NAME}.workspace.azurehealthcareapis.com" ;;
        *) return 1 ;;
      esac ;;

    # ── Search ──
    searchServices)       echo "${RESOURCE_NAME}.search.windows.net" ;;

    # ── API Management ──
    service)
      case "$RESOURCE_PROVIDER" in
        Microsoft.ApiManagement) echo "${RESOURCE_NAME}.azure-api.net" ;;
        *) return 1 ;;
      esac ;;

    # ── Data Factory ──
    factories)            echo "${RESOURCE_NAME}.datafactory.azure.net" ;;

    # ── IoT ──
    IotHubs)              echo "${RESOURCE_NAME}.azure-devices.net" ;;
    ProvisioningServices) echo "${RESOURCE_NAME}.azure-devices-provisioning.net" ;;

    # ── Event Grid ──
    domains|topics)
      case "$RESOURCE_PROVIDER" in
        Microsoft.EventGrid) echo "${RESOURCE_NAME}.eventgrid.azure.net" ;;
        *) return 1 ;;
      esac ;;

    # ── Cache ──
    Redis)                echo "${RESOURCE_NAME}.redis.cache.windows.net" ;;
    RedisEnterprise)      echo "${RESOURCE_NAME}.redisenterprise.cache.azure.net" ;;

    # ── Monitoring ──
    privateLinkScopes)    echo "${RESOURCE_NAME}.monitor.azure.com" ;;

    # ── Synapse Private Link Hub ──
    privateLinkHubs)      echo "${RESOURCE_NAME}.azuresynapse.net" ;;

    # ── Digital Twins ──
    digitalTwinsInstances) echo "${RESOURCE_NAME}.digitaltwins.azure.net" ;;

    # ── Automation ──
    automationAccounts)   echo "${RESOURCE_NAME}.azure-automation.net" ;;

    # ── App Configuration ──
    configurationStores)  echo "${RESOURCE_NAME}.azconfig.io" ;;

    # ── Batch ──
    batchAccounts)        echo "${RESOURCE_NAME}.batch.azure.com" ;;

    # ── Bot Service ──
    botServices)          echo "${RESOURCE_NAME}.directline.botframework.com" ;;

    # ── Data Explorer (Kusto) ──
    Clusters)
      case "$RESOURCE_PROVIDER" in
        Microsoft.Kusto) echo "${RESOURCE_NAME}.kusto.windows.net" ;;
        *) return 1 ;;
      esac ;;

    # ── SignalR ──
    SignalR)              echo "${RESOURCE_NAME}.service.signalr.net" ;;

    # ── HDInsight ──
    clusters)
      case "$RESOURCE_PROVIDER" in
        Microsoft.HDInsight) echo "${RESOURCE_NAME}.azurehdinsight.net" ;;
        *) return 1 ;;
      esac ;;

    # ── Power BI ──
    privateLinkServicesForPowerBI) echo "${RESOURCE_NAME}.analysis.windows.net" ;;

    # ── Managed Disks (private export/import — no user-facing FQDN) ──
    diskAccesses)         return 1 ;;

    # ── Azure Arc ──
    hybridcompute)        return 1 ;; # use property path

    # ── Media Services ──
    keydelivery)          echo "${RESOURCE_NAME}.media.azure.net" ;;

    # ── Azure Migrate ──
    assessment|migrate)   return 1 ;; # no standard FQDN; use property path
    discovery)            return 1 ;; # Azure Migrate discovery site

    *)                    return 1 ;;
  esac
}

FQDN=$(fqdn_from_resource) || true

if [[ -n "$FQDN" ]]; then
  echo "    FQDN: $FQDN"
  result PASS "Determined FQDN: $FQDN"
else
  result WARN "Could not determine FQDN automatically"
  echo "         → The resource type '$RESOURCE_PROVIDER/$RESOURCE_TYPE' may not have a standard hostname"
  echo "         → Provide the hostname manually: ./scripts/debug/check-dns.sh <hostname>"
fi

# Check public network access setting
PUB_ACCESS=$(run_with_timeout 20 az resource show --ids "$RESOURCE_ID" --query "properties.publicNetworkAccess" -o tsv 2>/dev/null || echo "unknown")
if [[ "$PUB_ACCESS" == "Disabled" || "$PUB_ACCESS" == "disabled" ]]; then
  result PASS "Public network access is disabled (private-only)"
elif [[ "$PUB_ACCESS" == "Enabled" || "$PUB_ACCESS" == "enabled" ]]; then
  result WARN "Public network access is enabled — resource is reachable from the internet"
  echo "         → Consider disabling if private endpoint is the intended access method"
elif [[ "$PUB_ACCESS" != "unknown" ]]; then
  echo "    Public network access: $PUB_ACCESS"
fi

# ─────────────────────────────────────────────────────────
# Step 2: Find private endpoints targeting this resource
# ─────────────────────────────────────────────────────────
print_step 2 "Private endpoints for this resource"

# Search across hub + all spoke RGs
SEARCH_RGS=("$RESOURCE_RG" "$DBG_HUB_RG")
for i in $(seq 0 $((DBG_SPOKE_COUNT - 1))); do
  SPOKE_RG=$(jq -r ".spokes[$i].resourceGroupName" "$CONFIG_FILE")
  SEARCH_RGS+=("$SPOKE_RG")
done
# Deduplicate
SEARCH_RGS=($(printf '%s\n' "${SEARCH_RGS[@]}" | sort -u))

FOUND_PES="[]"
RESOURCE_ID_LOWER=$(echo "$RESOURCE_ID" | tr '[:upper:]' '[:lower:]')

for RG in "${SEARCH_RGS[@]}"; do
  RG_PES=$(run_with_timeout 30 az network private-endpoint list \
    --resource-group "$RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    -o json 2>/dev/null || echo "[]")

  # Filter PEs that target our resource (case-insensitive match)
  MATCHING=$(echo "$RG_PES" | jq --arg rid "$RESOURCE_ID_LOWER" \
    '[.[] | select((.privateLinkServiceConnections[0].privateLinkServiceId // "") | ascii_downcase == $rid)]')

  MATCH_COUNT=$(echo "$MATCHING" | jq length)
  if [[ "$MATCH_COUNT" -gt 0 ]]; then
    FOUND_PES=$(echo "$FOUND_PES" "$MATCHING" | jq -s '.[0] + .[1]')
  fi
done

PE_COUNT=$(echo "$FOUND_PES" | jq length)

if [[ "$PE_COUNT" -eq 0 ]]; then
  result FAIL "No private endpoints found targeting this resource"
  echo "         → The resource has no private endpoint configured"
  echo "         → Create one in the Azure portal or via Bicep/CLI"
  print_summary \
    "Create a private endpoint for this resource" \
    "Ensure the PE is in a VNet peered to the hub"
  # print_summary exits on failure
fi

echo "    Found $PE_COUNT private endpoint(s)"

# ─────────────────────────────────────────────────────────
# Step 3: Inspect each PE's networking details
# ─────────────────────────────────────────────────────────
print_step 3 "Private endpoint details"

# We'll collect info for the summary
PE_IPS=()
PE_VNETS=()
PE_ZONES=()

echo "$FOUND_PES" | jq -c '.[]' | while read -r pe; do
  PE_NAME=$(echo "$pe" | jq -r '.name')
  PE_RG=$(echo "$pe" | jq -r '.resourceGroup')
  PE_STATUS=$(echo "$pe" | jq -r '.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status // "unknown"')
  PE_GROUP=$(echo "$pe" | jq -r '.privateLinkServiceConnections[0].groupIds[0] // "unknown"')
  PE_SUBNET_ID=$(echo "$pe" | jq -r '.subnet.id // "unknown"')

  echo ""
  echo "  ┌─ PE: $PE_NAME (RG: $PE_RG)"
  echo "  │  Group: $PE_GROUP"
  echo "  │  Status: $PE_STATUS"

  # Connection status
  if [[ "$PE_STATUS" == "Approved" ]]; then
    result PASS "PE '$PE_NAME' connection is Approved"
  elif [[ "$PE_STATUS" == "Pending" ]]; then
    result FAIL "PE '$PE_NAME' connection is Pending — must be approved on the target resource"
    echo "  │  → Go to Azure portal → Resource → Networking → Private endpoint connections → Approve"
  else
    result FAIL "PE '$PE_NAME' connection status: $PE_STATUS"
  fi

  # NIC and private IP
  NIC_ID=$(echo "$pe" | jq -r '.networkInterfaces[0].id // empty')
  PE_IP="unknown"
  if [[ -n "$NIC_ID" ]]; then
    PE_IP=$(run_with_timeout 20 az network nic show --ids "$NIC_ID" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --query "ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || echo "unknown")
    echo "  │  Private IP: $PE_IP"
  fi

  # Subnet and VNet
  PE_VNET="unknown"
  PE_VNET_RG="unknown"
  PE_SUBNET_NAME="unknown"
  if [[ "$PE_SUBNET_ID" != "unknown" && "$PE_SUBNET_ID" != "null" ]]; then
    PE_VNET=$(echo "$PE_SUBNET_ID" | grep -oP 'virtualNetworks/\K[^/]+' || echo "unknown")
    PE_VNET_RG=$(echo "$PE_SUBNET_ID" | grep -oP 'resourceGroups/\K[^/]+' || echo "unknown")
    PE_SUBNET_NAME=$(echo "$PE_SUBNET_ID" | grep -oP 'subnets/\K[^/]+' || echo "unknown")
    echo "  │  VNet: $PE_VNET (RG: $PE_VNET_RG)"
    echo "  │  Subnet: $PE_SUBNET_NAME"
  fi

  # DNS zone group
  ZONE_GROUPS=$(run_with_timeout 20 az network private-endpoint dns-zone-group list \
    --endpoint-name "$PE_NAME" \
    --resource-group "$PE_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[].privateDnsZoneConfigs[].{zone:privateDnsZoneId}" \
    -o json 2>/dev/null || echo "[]")

  ZG_ZONES=$(echo "$ZONE_GROUPS" | jq -r '.[].zone // empty' 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/,$//')
  if [[ -n "$ZG_ZONES" ]]; then
    echo "  │  DNS zones: $ZG_ZONES"
    result PASS "PE '$PE_NAME' has DNS zone group → A records are managed"
  else
    result FAIL "PE '$PE_NAME' has NO DNS zone group — A record won't exist in private DNS"
    echo "  │  → Run: ./scripts/debug/check-dns-policy.sh --all --remediate"
  fi

  echo "  └──"

  # ── Check VNet peering to hub ──
  if [[ "$PE_VNET" != "unknown" && "$PE_VNET" != "$DBG_HUB_VNET_NAME" ]]; then
    echo ""
    echo "    Checking peering: $PE_VNET → $DBG_HUB_VNET_NAME"
    PEERING_TO_HUB=$(run_with_timeout 25 az network vnet peering list \
      --resource-group "$PE_VNET_RG" \
      --vnet-name "$PE_VNET" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      -o json 2>/dev/null || echo "[]")

    HUB_MATCH=$(echo "$PEERING_TO_HUB" | jq -c "[.[] | select(.remoteVirtualNetwork.id | ascii_downcase | contains(\"$(echo "$DBG_HUB_VNET_NAME" | tr '[:upper:]' '[:lower:]')\"))]")
    HUB_MATCH_COUNT=$(echo "$HUB_MATCH" | jq length)

    if [[ "$HUB_MATCH_COUNT" -gt 0 ]]; then
      PEER_STATE=$(echo "$HUB_MATCH" | jq -r '.[0].peeringState')
      USE_GW=$(echo "$HUB_MATCH" | jq -r '.[0].useRemoteGateways')
      if [[ "$PEER_STATE" == "Connected" ]]; then
        result PASS "VNet '$PE_VNET' is peered to hub (Connected)"
      else
        result FAIL "VNet '$PE_VNET' peering to hub is: $PEER_STATE"
      fi
      if [[ "$USE_GW" != "true" ]]; then
        result WARN "Peering does not use remote gateways — VPN clients may not reach this VNet"
      fi
    else
      result FAIL "VNet '$PE_VNET' has NO peering to hub VNet '$DBG_HUB_VNET_NAME'"
      echo "         → VPN clients cannot reach this PE without a peering to the hub"
      echo "         → Use: ./scripts/ipam/provision-spoke.sh or create peering manually"
    fi
  elif [[ "$PE_VNET" == "$DBG_HUB_VNET_NAME" ]]; then
    result PASS "PE is in the hub VNet (no peering needed)"
  fi

  # ── Check NSG on PE subnet ──
  if [[ "$PE_SUBNET_ID" != "unknown" && "$PE_SUBNET_ID" != "null" ]]; then
    echo ""
    echo "    Checking NSG on subnet '$PE_SUBNET_NAME'..."
    SUBNET_NSG=$(run_with_timeout 20 az network vnet subnet show \
      --ids "$PE_SUBNET_ID" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --query "networkSecurityGroup.id" \
      -o tsv 2>/dev/null || echo "")

    if [[ -n "$SUBNET_NSG" && "$SUBNET_NSG" != "None" ]]; then
      NSG_NAME=$(echo "$SUBNET_NSG" | awk -F'/' '{print $NF}')
      echo "    NSG: $NSG_NAME"
      result PASS "Subnet '$PE_SUBNET_NAME' has NSG '$NSG_NAME'"
      echo "         → To check rules: ./scripts/debug/check-nsg.sh --resource-group $PE_VNET_RG"
    else
      result WARN "Subnet '$PE_SUBNET_NAME' has no NSG (unfiltered access)"
    fi
  fi

  # ── TCP connectivity test ──
  if [[ "$PE_IP" != "unknown" ]]; then
    echo ""
    # Determine expected port from the PE group ID (subresource)
    PE_PORT="443"
    case "$PE_GROUP" in
      # Web & App Hosting
      sites|sites-staging|staticSites)  PE_PORT="443" ;;

      # Relational Databases
      sqlServer|managedInstance)         PE_PORT="1433" ;;
      mysqlServer)                      PE_PORT="3306" ;;
      mariadbServer)                    PE_PORT="3306" ;;
      postgresqlServer)                 PE_PORT="5432" ;;

      # Key Vault & HSM
      vault|managedHSM)                 PE_PORT="443" ;;

      # Messaging
      namespace)                        PE_PORT="5671" ;;

      # Cache
      redisCache)                       PE_PORT="6380" ;;
      redisEnterprise)                  PE_PORT="6380" ;;

      # Storage
      blob|blob_secondary)              PE_PORT="443" ;;
      file|file_secondary)              PE_PORT="445" ;;
      queue|queue_secondary)            PE_PORT="443" ;;
      table|table_secondary)            PE_PORT="443" ;;
      dfs|dfs_secondary)                PE_PORT="443" ;;
      web|web_secondary)                PE_PORT="443" ;;
      afs)                              PE_PORT="443" ;;

      # Container
      registry)                         PE_PORT="443" ;;
      management)                       PE_PORT="443" ;; # AKS

      # Cosmos DB (all APIs)
      Sql|MongoDB|Cassandra|Gremlin|Table) PE_PORT="443" ;;

      # AI & Cognitive Services
      account)                          PE_PORT="443" ;; # Cognitive Services / OpenAI / Purview

      # AI Foundry / ML
      amlworkspace)                     PE_PORT="443" ;;

      # Search
      searchService)                    PE_PORT="443" ;;

      # API Management
      Gateway)                          PE_PORT="443" ;;

      # Data Factory
      dataFactory|portal)               PE_PORT="443" ;;

      # Databricks
      databricks_ui_api|browser_authentication) PE_PORT="443" ;;

      # IoT
      iotHub)                           PE_PORT="8883" ;;
      iotDps)                           PE_PORT="443" ;;

      # Event Grid
      domain|topic)                     PE_PORT="443" ;;

      # Synapse
      Sql|SqlOnDemand)                  PE_PORT="1433" ;;
      Dev|Web)                          PE_PORT="443" ;;

      # Digital Twins
      digitalTwinsInstances)            PE_PORT="443" ;;

      # Batch
      batchAccount|nodeManagement)      PE_PORT="443" ;;

      # Bot Service
      Bot|Token)                        PE_PORT="443" ;;

      # SignalR
      signalR)                          PE_PORT="443" ;;

      # App Configuration
      configurationStores)              PE_PORT="443" ;;

      # Automation
      Webhook|DSCAndHybridWorker)       PE_PORT="443" ;;

      # Monitoring
      azuremonitor)                     PE_PORT="443" ;;

      # Healthcare
      healthcareworkspace)              PE_PORT="443" ;;

      # Kusto / Data Explorer
      cluster)                          PE_PORT="443" ;;

      # Container Apps Environment
      managedEnvironments)              PE_PORT="443" ;;

      # Managed Disk Access
      disks)                            PE_PORT="443" ;;

      # HDInsight
      hdinsight)                        PE_PORT="443" ;;

      # Azure Arc
      his)                              PE_PORT="443" ;;

      # Media Services
      keydelivery)                      PE_PORT="443" ;;

      # Azure Migrate
      project|site|projects)            PE_PORT="443" ;;

      # Power BI
      privatelink.analysis.windows.net) PE_PORT="443" ;;

      *)                                PE_PORT="443" ;;
    esac

    echo "    Testing TCP connectivity: $PE_IP:$PE_PORT"
    if nc -z -w 5 "$PE_IP" "$PE_PORT" 2>/dev/null; then
      result PASS "TCP connection to $PE_IP:$PE_PORT succeeded"
    else
      result WARN "TCP connection to $PE_IP:$PE_PORT failed"
      echo "         → Is VPN connected? Run: ./scripts/debug/check-vpn.sh"
      echo "         → Is NSG blocking? Run: ./scripts/debug/check-nsg.sh --resource-group $PE_VNET_RG"
    fi
  fi

done

# ─────────────────────────────────────────────────────────
# Step 4: DNS resolution check
# ─────────────────────────────────────────────────────────
if [[ -n "$FQDN" ]]; then
  print_step 4 "DNS resolution for $FQDN"

  # Test via CoreDNS server (what Azure sees)
  echo "    Via CoreDNS ($DBG_DNS_IP):"
  if DNS_RESULT=$(nslookup "$FQDN" "$DBG_DNS_IP" 2>&1); then
    RESOLVED_IP=$(echo "$DNS_RESULT" | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    if [[ -n "$RESOLVED_IP" ]] && echo "$RESOLVED_IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
      echo "      $FQDN → $RESOLVED_IP (private)"
      result PASS "DNS resolves to private IP: $RESOLVED_IP"
    elif [[ -n "$RESOLVED_IP" ]]; then
      echo "      $FQDN → $RESOLVED_IP (PUBLIC)"
      result FAIL "DNS resolves to PUBLIC IP — private DNS zone may be missing or not linked to hub VNet"
      echo "         → Run: ./scripts/debug/check-private-dns-zones.sh"
    else
      result WARN "DNS query returned no address for $FQDN"
    fi
  else
    result WARN "Could not resolve $FQDN via CoreDNS at $DBG_DNS_IP"
    echo "         → Is DNS server VM running? Run: ./scripts/debug/check-dns-server.sh"
  fi

  # Test via Windows resolver (what apps actually see)
  echo ""
  echo "    Via Windows Resolve-DnsName (ground truth for apps):"
  if command -v powershell.exe &>/dev/null; then
    WIN_RESULT=$(run_with_timeout 20 powershell.exe -NoProfile -NonInteractive -Command "try { (Resolve-DnsName '$FQDN' -ErrorAction Stop | Where-Object { \$_.QueryType -eq 'A' } | Select-Object -First 1).IPAddress } catch { 'ERROR' }" 2>/dev/null | tr -d '\r')
    if [[ "$WIN_RESULT" == "ERROR" || -z "$WIN_RESULT" ]]; then
      result WARN "Windows Resolve-DnsName could not resolve $FQDN"
    elif echo "$WIN_RESULT" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
      echo "      $FQDN → $WIN_RESULT (private)"
      result PASS "Windows resolves to private IP: $WIN_RESULT"
    else
      echo "      $FQDN → $WIN_RESULT (PUBLIC)"
      result FAIL "Windows resolves to PUBLIC IP — VPN DNS may not be configured"
      echo "         → Check VPN XML profile has <dnsservers> entry for $DBG_DNS_IP"
    fi
  else
    echo "      ⚠️  powershell.exe not available — skipping Windows DNS check"
  fi
fi

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
print_summary \
  "No PE found? → Create a private endpoint for this resource" \
  "PE Pending? → Approve in Azure portal → Resource → Networking → Private endpoint connections" \
  "DNS resolves to public IP? → ./scripts/debug/check-private-dns-zones.sh" \
  "No DNS zone group? → ./scripts/debug/check-dns-policy.sh --all --remediate" \
  "TCP blocked? → ./scripts/debug/check-vpn.sh then ./scripts/debug/check-nsg.sh --all" \
  "VNet not peered? → ./scripts/debug/check-peerings.sh"
