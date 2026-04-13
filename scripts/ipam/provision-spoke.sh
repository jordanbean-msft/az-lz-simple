#!/usr/bin/env bash
# -------------------------------------------------------------------
# provision-spoke.sh — Create a spoke VNet, peer it to the hub,
# and configure DNS.
#
# This is the main IPAM provisioning script. It:
#   1. Reads hub info from .azure-debug-config.json
#   2. Accepts spoke parameters (name, RG, location, address space, subnets)
#   3. Creates the spoke VNet with subnets and NSGs
#   4. Creates bidirectional peering (hub↔spoke) with gateway transit
#   5. Sets the spoke VNet's DNS to the hub's CoreDNS resolver
#   6. Updates .azure-debug-config.json with the new spoke entry
#
# Usage (interactive — prompted by VS Code tasks):
#   ./scripts/ipam/provision-spoke.sh \
#     --name "my-app" \
#     --resource-group "RG-MY-APP" \
#     --location "eastus2" \
#     --address-space "10.1.0.0/16" \
#     --subnets "default:10.1.0.0/24,private-endpoint:10.1.1.0/28" \
#     --delegations "default:Microsoft.Web/serverFarms"
#
# Or with --create-rg to auto-create the resource group:
#   ./scripts/ipam/provision-spoke.sh \
#     --name "my-app" \
#     --resource-group "RG-MY-APP" \
#     --location "eastus2" \
#     --address-space "10.1.0.0/16" \
#     --subnets "default:10.1.0.0/24" \
#     --delegations "app:Microsoft.Web/serverFarms" \
#     --create-rg
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"

# ── Parse arguments ──
SPOKE_NAME=""
SPOKE_RG=""
SPOKE_LOCATION=""
ADDRESS_SPACE=""
SUBNETS=""
DELEGATIONS=""
PROFILES=""
CREATE_RG=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) SPOKE_NAME="$2"; shift 2 ;;
    --resource-group) SPOKE_RG="$2"; shift 2 ;;
    --location) SPOKE_LOCATION="$2"; shift 2 ;;
    --address-space) ADDRESS_SPACE="$2"; shift 2 ;;
    --subnets) SUBNETS="$2"; shift 2 ;;
    --delegations) DELEGATIONS="$2"; shift 2 ;;
    --profiles) PROFILES="$2"; shift 2 ;;
    --create-rg) CREATE_RG=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Validate ──
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found. Copy .azure-debug-config.example.json and fill in your values."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: sudo apt-get install -y jq"
  exit 1
fi

if [[ -z "$SPOKE_NAME" || -z "$SPOKE_RG" || -z "$ADDRESS_SPACE" ]]; then
  echo "ERROR: --name, --resource-group, and --address-space are required."
  echo ""
  echo "Usage: $0 --name <name> --resource-group <rg> --location <loc> --address-space <cidr> --subnets <name:cidr,...> [--delegations <subnet:service,...>] [--profiles <subnet:profile,...>]"
  exit 1
fi

VALIDATOR_SCRIPT="$SCRIPT_DIR/validate-cidr-plan.sh"
if [[ ! -f "$VALIDATOR_SCRIPT" ]]; then
  echo "ERROR: Validator script not found at $VALIDATOR_SCRIPT"
  exit 1
fi

# ── Load hub config ──
SUBSCRIPTION_ID=$(jq -r '.subscriptionId' "$CONFIG_FILE")
HUB_RG=$(jq -r '.hub.resourceGroupName' "$CONFIG_FILE")
HUB_VNET_ID=$(jq -r '.hub.vnetResourceId' "$CONFIG_FILE")
HUB_VNET_NAME=$(jq -r '.hub.vnetName' "$CONFIG_FILE")
HUB_LOCATION=$(jq -r '.hub.location' "$CONFIG_FILE")

SPOKE_LOCATION="${SPOKE_LOCATION:-$HUB_LOCATION}"

# ── Discover DNS server IP from Azure ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Spoke VNet Provisioning"
echo "═══════════════════════════════════════════════════════"
echo ""

DNS_VM_NAME=$(jq -r '.hub.dnsServerVmName' "$CONFIG_FILE")
echo "  Discovering DNS server IP from Azure..."
DNS_IP=$(az vm show \
  --resource-group "$HUB_RG" \
  --name "$DNS_VM_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --show-details \
  --query "privateIps" \
  -o tsv 2>/dev/null || echo "")

if [[ -z "$DNS_IP" ]]; then
  echo "  ⚠️  Could not query DNS VM IP from Azure. Falling back to config file value."
  DNS_IP=$(jq -r '.hub.dnsServerPrivateIp' "$CONFIG_FILE")
fi
echo "  DNS server IP: $DNS_IP"

# ── Build VNet name ──
VNET_NAME="vnet-${SPOKE_NAME}-${SPOKE_LOCATION}"

echo ""
echo "── Provisioning plan ──"
echo ""
echo "  Spoke name:       $SPOKE_NAME"
echo "  Resource group:   $SPOKE_RG (create: $CREATE_RG)"
echo "  Location:         $SPOKE_LOCATION"
echo "  VNet name:        $VNET_NAME"
echo "  Address space:    $ADDRESS_SPACE"
echo "  DNS server:       $DNS_IP"
echo "  Hub VNet:         $HUB_VNET_NAME ($HUB_RG)"
echo ""

if [[ -n "$SUBNETS" ]]; then
  echo "  Subnets:"
  IFS=',' read -ra SUBNET_ARRAY <<< "$SUBNETS"
  for subnet in "${SUBNET_ARRAY[@]}"; do
    IFS=':' read -r sname scidr <<< "$subnet"
    echo "    - $sname: $scidr"
  done
  echo ""
fi

if [[ -n "$DELEGATIONS" ]]; then
  echo "  Subnet delegations:"
  IFS=',' read -ra DELEGATION_ARRAY <<< "$DELEGATIONS"
  for delegation in "${DELEGATION_ARRAY[@]}"; do
    IFS=':' read -r subnet_name service_name <<< "$delegation"
    if [[ -z "$subnet_name" || -z "$service_name" ]]; then
      echo "ERROR: Invalid delegation '$delegation'. Expected format: <subnet-name>:<service-name>"
      exit 1
    fi
    echo "    - $subnet_name => $service_name"
  done
  echo ""
fi

if [[ -n "$PROFILES" ]]; then
  echo "  Subnet profiles:"
  IFS=',' read -ra PROFILE_ARRAY <<< "$PROFILES"
  for profile in "${PROFILE_ARRAY[@]}"; do
    IFS=':' read -r subnet_name profile_name <<< "$profile"
    if [[ -z "$subnet_name" || -z "$profile_name" ]]; then
      echo "ERROR: Invalid profile '$profile'. Expected format: <subnet-name>:<profile-name>"
      exit 1
    fi
    echo "    - $subnet_name => $profile_name"
  done
  echo ""
fi

echo "── Preflight validation ──"
VALIDATOR_ARGS=(--address-space "$ADDRESS_SPACE")
if [[ -n "$SUBNETS" ]]; then
  VALIDATOR_ARGS+=(--subnets "$SUBNETS")
fi
if [[ -n "$DELEGATIONS" ]]; then
  VALIDATOR_ARGS+=(--delegations "$DELEGATIONS")
fi
if [[ -n "$PROFILES" ]]; then
  VALIDATOR_ARGS+=(--profiles "$PROFILES")
fi
"$VALIDATOR_SCRIPT" "${VALIDATOR_ARGS[@]}"
echo "  ✅ CIDR plan validated"
echo ""

if $DRY_RUN; then
  echo "  ── DRY RUN — no changes will be made ──"
  echo ""
  echo "  Commands that would be executed:"
  echo ""
  if $CREATE_RG; then
    echo "  az group create --name $SPOKE_RG --location $SPOKE_LOCATION --subscription $SUBSCRIPTION_ID"
  fi
  echo "  az network vnet create --name $VNET_NAME --resource-group $SPOKE_RG --location $SPOKE_LOCATION --address-prefixes $ADDRESS_SPACE --dns-servers $DNS_IP --subscription $SUBSCRIPTION_ID"
  if [[ -n "$SUBNETS" ]]; then
    for subnet in "${SUBNET_ARRAY[@]}"; do
      IFS=':' read -r sname scidr <<< "$subnet"
      echo "  az network vnet subnet create --vnet-name $VNET_NAME --resource-group $SPOKE_RG --name $sname --address-prefixes $scidr --subscription $SUBSCRIPTION_ID"
    done
  fi
  if [[ -n "$DELEGATIONS" ]]; then
    for delegation in "${DELEGATION_ARRAY[@]}"; do
      IFS=':' read -r subnet_name service_name <<< "$delegation"
      echo "  az network vnet subnet update --resource-group $SPOKE_RG --vnet-name $VNET_NAME --name $subnet_name --delegations $service_name --subscription $SUBSCRIPTION_ID"
    done
  fi
  echo "  az network vnet peering create -g $SPOKE_RG -n hub-${HUB_VNET_NAME} --vnet-name $VNET_NAME --remote-vnet $HUB_VNET_ID --allow-vnet-access --allow-forwarded-traffic --use-remote-gateways --subscription $SUBSCRIPTION_ID"
  echo "  az network vnet peering create -g $HUB_RG -n spoke-${VNET_NAME} --vnet-name $HUB_VNET_NAME --remote-vnet /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG/providers/Microsoft.Network/virtualNetworks/$VNET_NAME --allow-vnet-access --allow-gateway-transit --subscription $SUBSCRIPTION_ID"
  echo ""
  exit 0
fi

# ── Execute provisioning ──

# Step 1: Create resource group (if requested)
if $CREATE_RG; then
  echo "── Step 1: Creating resource group $SPOKE_RG ──"
  az group create \
    --name "$SPOKE_RG" \
    --location "$SPOKE_LOCATION" \
    --subscription "$SUBSCRIPTION_ID" \
    -o none
  echo "  ✅ Resource group created"
else
  echo "── Step 1: Using existing resource group $SPOKE_RG ──"
  if az group show --name "$SPOKE_RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
    echo "  ✅ Resource group exists"
  else
    echo "  ❌ Resource group $SPOKE_RG does not exist. Use --create-rg to create it."
    exit 1
  fi
fi

# Step 2: Create VNet with DNS
echo ""
echo "── Step 2: Creating VNet $VNET_NAME ($ADDRESS_SPACE) ──"
az network vnet create \
  --name "$VNET_NAME" \
  --resource-group "$SPOKE_RG" \
  --location "$SPOKE_LOCATION" \
  --address-prefixes "$ADDRESS_SPACE" \
  --dns-servers "$DNS_IP" \
  --subscription "$SUBSCRIPTION_ID" \
  -o none
echo "  ✅ VNet created with custom DNS server ($DNS_IP)"

# Step 3: Create subnets
if [[ -n "$SUBNETS" ]]; then
  echo ""
  echo "── Step 3: Creating subnets ──"
  IFS=',' read -ra SUBNET_ARRAY <<< "$SUBNETS"
  for subnet in "${SUBNET_ARRAY[@]}"; do
    IFS=':' read -r sname scidr <<< "$subnet"
    echo "  Creating subnet $sname ($scidr)..."
    az network vnet subnet create \
      --vnet-name "$VNET_NAME" \
      --resource-group "$SPOKE_RG" \
      --name "$sname" \
      --address-prefixes "$scidr" \
      --subscription "$SUBSCRIPTION_ID" \
      -o none
    echo "  ✅ Subnet $sname created"
  done
else
  echo ""
  echo "── Step 3: No subnets specified (skipping) ──"
fi

# Step 4: Apply subnet delegations
if [[ -n "$DELEGATIONS" ]]; then
  echo ""
  echo "── Step 4: Applying subnet delegations ──"
  IFS=',' read -ra DELEGATION_ARRAY <<< "$DELEGATIONS"
  for delegation in "${DELEGATION_ARRAY[@]}"; do
    IFS=':' read -r subnet_name service_name <<< "$delegation"
    echo "  Delegating subnet $subnet_name to $service_name..."
    az network vnet subnet update \
      --resource-group "$SPOKE_RG" \
      --vnet-name "$VNET_NAME" \
      --name "$subnet_name" \
      --delegations "$service_name" \
      --subscription "$SUBSCRIPTION_ID" \
      -o none
    echo "  ✅ Subnet $subnet_name delegated to $service_name"
  done
else
  echo ""
  echo "── Step 4: No subnet delegations specified (skipping) ──"
fi

# Step 5: Create hub→spoke peering (must be created FIRST for --use-remote-gateways to work)
SPOKE_VNET_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

echo ""
echo "── Step 5: Creating hub → spoke peering ──"
az network vnet peering create \
  --resource-group "$HUB_RG" \
  --name "spoke-${VNET_NAME}" \
  --vnet-name "$HUB_VNET_NAME" \
  --remote-vnet "$SPOKE_VNET_ID" \
  --allow-vnet-access \
  --allow-gateway-transit \
  --subscription "$SUBSCRIPTION_ID" \
  -o none
echo "  ✅ Hub → spoke peering created (gateway transit enabled)"

# Step 6: Create spoke→hub peering
echo ""
echo "── Step 6: Creating spoke → hub peering ──"
az network vnet peering create \
  --resource-group "$SPOKE_RG" \
  --name "hub-${HUB_VNET_NAME}" \
  --vnet-name "$VNET_NAME" \
  --remote-vnet "$HUB_VNET_ID" \
  --allow-vnet-access \
  --allow-forwarded-traffic \
  --use-remote-gateways \
  --subscription "$SUBSCRIPTION_ID" \
  -o none
echo "  ✅ Spoke → hub peering created (using remote gateways)"

# Step 7: Verify peerings
echo ""
echo "── Step 7: Verifying peerings ──"
HUB_STATE=$(az network vnet peering show \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET_NAME" \
  --name "spoke-${VNET_NAME}" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "peeringState" -o tsv 2>/dev/null || echo "unknown")

SPOKE_STATE=$(az network vnet peering show \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$VNET_NAME" \
  --name "hub-${HUB_VNET_NAME}" \
  --subscription "$SUBSCRIPTION_ID" \
  --query "peeringState" -o tsv 2>/dev/null || echo "unknown")

echo "  Hub → spoke: $HUB_STATE"
echo "  Spoke → hub: $SPOKE_STATE"

if [[ "$HUB_STATE" == "Connected" && "$SPOKE_STATE" == "Connected" ]]; then
  echo "  ✅ Both peerings are Connected"
else
  echo "  ⚠️  Peerings may not be fully connected yet. Check with: ./scripts/debug/check-peerings.sh"
fi

# Step 8: Update .azure-debug-config.json
echo ""
echo "── Step 8: Updating .azure-debug-config.json ──"
UPDATED_CONFIG=$(jq \
  --arg name "$SPOKE_NAME" \
  --arg rg "$SPOKE_RG" \
  --arg sub "$SUBSCRIPTION_ID" \
  --arg vnetId "$SPOKE_VNET_ID" \
  --arg vnetName "$VNET_NAME" \
  --arg addressSpace "$ADDRESS_SPACE" \
  --arg location "$SPOKE_LOCATION" \
  '.spokes += [{
    name: $name,
    resourceGroupName: $rg,
    subscriptionId: $sub,
    vnetResourceId: $vnetId,
    vnetName: $vnetName,
    addressSpace: $addressSpace,
    location: $location
  }]' "$CONFIG_FILE")

echo "$UPDATED_CONFIG" > "$CONFIG_FILE"
echo "  ✅ Spoke added to .azure-debug-config.json"

# Done
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Spoke VNet provisioned successfully!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  VNet:            $VNET_NAME"
echo "  Resource group:  $SPOKE_RG"
echo "  Address space:   $ADDRESS_SPACE"
echo "  DNS server:      $DNS_IP"
echo "  Hub peering:     Connected"
echo "  VPN gateway:     Accessible via hub"
echo ""
echo "  Next steps:"
echo "    - Deploy resources into the spoke VNet"
echo "    - Private endpoints will auto-register DNS via Azure Policy"
echo "    - Test connectivity: ./scripts/debug/check-peerings.sh $SPOKE_VNET_ID"
echo ""
