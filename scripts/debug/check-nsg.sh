#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-nsg.sh — Verify NSG rules on hub and spoke subnets
#
# Checks that NSGs allow expected traffic for VPN clients, DNS,
# private endpoints, and peered VNets. Reports rules that may block
# connectivity and highlights common misconfigurations.
#
# Usage:
#   ./scripts/debug/check-nsg.sh                        # check hub NSGs
#   ./scripts/debug/check-nsg.sh --all                  # check hub + all spoke NSGs
#   ./scripts/debug/check-nsg.sh --resource-group RG    # check NSGs in a specific RG
#   ./scripts/debug/check-nsg.sh --nic <nic-name> --resource-group RG  # effective rules for a NIC
# -------------------------------------------------------------------
set -euo pipefail
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help "check-nsg.sh" "Check NSG rules on hub and spoke subnets" \
  "./scripts/debug/check-nsg.sh" \
  "./scripts/debug/check-nsg.sh --all" \
  "./scripts/debug/check-nsg.sh --resource-group <rg>" \
  "./scripts/debug/check-nsg.sh --nic <nic-name> --resource-group <rg>"

CHECK_ALL=false
SPECIFIC_RG=""
SPECIFIC_NIC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) CHECK_ALL=true; shift ;;
    --resource-group) SPECIFIC_RG="$2"; shift 2 ;;
    --nic) SPECIFIC_NIC="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

print_header "NSG Diagnostics"

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required."
  exit 1
fi

# ─────────────────────────────────────────────────────────
# If --nic was specified, show effective security rules and exit
# ─────────────────────────────────────────────────────────
if [[ -n "$SPECIFIC_NIC" ]]; then
  NIC_RG="${SPECIFIC_RG:-$DBG_HUB_RG}"
  print_step 1 "Effective security rules for NIC: $SPECIFIC_NIC (RG: $NIC_RG)"
  echo ""
  echo "    This shows the ACTUAL rules applied to the NIC after merging"
  echo "    subnet-level NSG + NIC-level NSG + Azure default rules."
  echo ""

  EFFECTIVE=$(run_with_timeout 30 az network nic list-effective-nsg \
    --name "$SPECIFIC_NIC" \
    --resource-group "$NIC_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    -o json 2>/dev/null) || {
    result FAIL "Could not retrieve effective NSG rules for NIC '$SPECIFIC_NIC'"
    echo "         → Verify the NIC name and resource group are correct"
    print_summary
  }

  # Parse and display effective rules grouped by NSG
  echo "$EFFECTIVE" | jq -r '
    .value[]? |
    "    NSG: \(.networkSecurityGroup.id // "default" | split("/") | last)",
    (.effectiveSecurityRules[]? |
      "      [\(.priority)] \(.direction) \(.access) \(.protocol) src=\(.sourceAddressPrefix // (.sourceAddressPrefixes | join(","))) dst=\(.destinationAddressPrefix // (.destinationAddressPrefixes | join(","))) ports=\(.destinationPortRange // (.destinationPortRanges | join(",")))"
    ),
    ""
  ' 2>/dev/null || echo "    (no effective rules returned)"

  result PASS "Retrieved effective security rules for NIC '$SPECIFIC_NIC'"
  print_summary
fi

# ─────────────────────────────────────────────────────────
# Build list of resource groups to check
# ─────────────────────────────────────────────────────────
RG_LIST=()

if [[ -n "$SPECIFIC_RG" ]]; then
  RG_LIST+=("$SPECIFIC_RG")
elif $CHECK_ALL; then
  RG_LIST+=("$DBG_HUB_RG")
  for i in $(seq 0 $((DBG_SPOKE_COUNT - 1))); do
    SPOKE_RG=$(jq -r ".spokes[$i].resourceGroupName" "$REPO_ROOT/.azure-debug-config.json")
    RG_LIST+=("$SPOKE_RG")
  done
else
  RG_LIST+=("$DBG_HUB_RG")
fi

# ─────────────────────────────────────────────────────────
# Check NSGs in each resource group
# ─────────────────────────────────────────────────────────
NSG_STEP=0
check_nsg_in_rg() {
  local RG="$1"
  NSG_STEP=$((NSG_STEP + 1))
  print_step $NSG_STEP "Checking NSGs in resource group: $RG"

  # List all NSGs in the RG
  NSGS=$(run_with_timeout 30 az network nsg list \
    --resource-group "$RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[].{name:name, id:id, subnets:subnets[].id, nics:networkInterfaces[].id}" \
    -o json 2>/dev/null || echo "[]")

  NSG_COUNT=$(echo "$NSGS" | jq length)

  if [[ "$NSG_COUNT" -eq 0 ]]; then
    result WARN "No NSGs found in $RG"
    echo "         → Subnets without NSGs have no network-level filtering"
    return
  fi

  echo "    Found $NSG_COUNT NSG(s)"

  # List all subnets in VNets in this RG to find unprotected ones
  VNETS=$(run_with_timeout 30 az network vnet list \
    --resource-group "$RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[].{name:name, subnets:subnets[].{name:name, nsg:networkSecurityGroup.id, prefix:addressPrefix}}" \
    -o json 2>/dev/null || echo "[]")

  while read -r nsg; do
    NSG_NAME=$(echo "$nsg" | jq -r '.name')
    SUBNET_COUNT=$(echo "$nsg" | jq '[.subnets // [] | length] | add')
    NIC_COUNT=$(echo "$nsg" | jq '[.nics // [] | length] | add')

    echo ""
    echo "    NSG: $NSG_NAME"
    echo "      Attached to: $SUBNET_COUNT subnet(s), $NIC_COUNT NIC(s)"

    if [[ "$SUBNET_COUNT" -eq 0 && "$NIC_COUNT" -eq 0 ]]; then
      result WARN "NSG '$NSG_NAME' is not attached to any subnet or NIC (orphaned)"
      continue
    fi

    # Get all rules
    RULES=$(run_with_timeout 25 az network nsg rule list \
      --nsg-name "$NSG_NAME" \
      --resource-group "$RG" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --query "[].{name:name, priority:priority, access:access, direction:direction, protocol:protocol, srcPrefix:sourceAddressPrefix, srcPrefixes:sourceAddressPrefixes, dstPrefix:destinationAddressPrefix, dstPrefixes:destinationAddressPrefixes, dstPort:destinationPortRange, dstPorts:destinationPortRanges}" \
      -o json 2>/dev/null || echo "[]")

    RULE_COUNT=$(echo "$RULES" | jq length)
    echo "      Custom rules: $RULE_COUNT"

    # Display rules in a compact table
    echo ""
    printf "      %-5s %-30s %-8s %-8s %-6s %-20s %-20s %s\n" "PRI" "NAME" "DIR" "ACCESS" "PROTO" "SOURCE" "DESTINATION" "PORTS"
    printf "      %-5s %-30s %-8s %-8s %-6s %-20s %-20s %s\n" "───" "──────────────────────────────" "────────" "────────" "──────" "────────────────────" "────────────────────" "─────"

    while read -r rule; do
      PRI=$(echo "$rule" | jq -r '.priority')
      NAME=$(echo "$rule" | jq -r '.name')
      DIR=$(echo "$rule" | jq -r '.direction')
      ACCESS=$(echo "$rule" | jq -r '.access')
      PROTO=$(echo "$rule" | jq -r '.protocol')
      SRC=$(echo "$rule" | jq -r 'if .srcPrefix != "" and .srcPrefix != null then .srcPrefix else (.srcPrefixes // [] | join(",")) end')
      DST=$(echo "$rule" | jq -r 'if .dstPrefix != "" and .dstPrefix != null then .dstPrefix else (.dstPrefixes // [] | join(",")) end')
      PORTS=$(echo "$rule" | jq -r 'if .dstPort != "" and .dstPort != null then .dstPort else (.dstPorts // [] | join(",")) end')

      # Truncate long values for display
      [[ ${#NAME} -gt 30 ]] && NAME="${NAME:0:27}..."
      [[ ${#SRC} -gt 20 ]] && SRC="${SRC:0:17}..."
      [[ ${#DST} -gt 20 ]] && DST="${DST:0:17}..."

      printf "      %-5s %-30s %-8s %-8s %-6s %-20s %-20s %s\n" "$PRI" "$NAME" "$DIR" "$ACCESS" "$PROTO" "$SRC" "$DST" "$PORTS"
    done < <(echo "$RULES" | jq -c 'sort_by(.priority) | .[]')

    echo ""

    # Analyze for common issues
    INBOUND_RULES=$(echo "$RULES" | jq '[.[] | select(.direction == "Inbound")]')
    OUTBOUND_RULES=$(echo "$RULES" | jq '[.[] | select(.direction == "Outbound")]')

    # Private endpoint subnet NSGs often have intentionally narrow egress.
    # Missing outbound 53/443 there usually impacts PE subnet diagnostics, not local internet on Windows.
    NSG_SUBNET_IDS=$(echo "$nsg" | jq -r '.subnets[]? // empty')
    IS_PRIVATE_ENDPOINT_NSG=false
    if echo "$NSG_NAME" | grep -qi "private-endpoint" || echo "$NSG_SUBNET_IDS" | grep -qi "private-endpoint"; then
      IS_PRIVATE_ENDPOINT_NSG=true
    fi

    # Check: Does inbound allow VPN client traffic (10.0.0.0/8 covers VPN P2S pool and spokes)?
    VPN_INBOUND=$(echo "$INBOUND_RULES" | jq '[.[] | select(.access == "Allow") | select(
      .srcPrefix == "VirtualNetwork" or
      .srcPrefix == "*" or
      .srcPrefix == "10.0.0.0/8" or
      (.srcPrefixes // [] | any(. == "VirtualNetwork" or . == "*" or . == "10.0.0.0/8"))
    )] | length')

    if [[ "$VPN_INBOUND" -gt 0 ]]; then
      result PASS "NSG '$NSG_NAME' allows inbound from VirtualNetwork or VPN address space"
    else
      result WARN "NSG '$NSG_NAME' may block inbound VPN client traffic — no rule allows VirtualNetwork or 10.0.0.0/8"
      echo "         → VPN P2S clients use addresses from the VPN pool (check gateway config)"
      echo "         → Spokes use 10.x.x.x addresses. Verify 'VirtualNetwork' service tag covers your scenario."
    fi

    # Check: Does inbound have a catch-all deny?
    INBOUND_DENY_ALL=$(echo "$INBOUND_RULES" | jq '[.[] | select(.access == "Deny" and .srcPrefix == "*" and (.dstPort == "*" or .dstPort == null) and (.dstPrefix == "*"))] | length')
    if [[ "$INBOUND_DENY_ALL" -gt 0 ]]; then
      result PASS "NSG '$NSG_NAME' has explicit inbound deny-all (defense in depth)"
    fi

    # Check: Does outbound allow DNS (port 53)?
    DNS_OUTBOUND=$(echo "$OUTBOUND_RULES" | jq '[.[] | select(.access == "Allow") | select(
      (.dstPort == "53" or (.dstPorts // [] | any(. == "53")) or .dstPort == "*")
    )] | length')

    if [[ "$DNS_OUTBOUND" -gt 0 ]]; then
      result PASS "NSG '$NSG_NAME' allows outbound DNS (port 53)"
    else
      # Only warn if there's an explicit outbound deny (otherwise Azure defaults allow it)
      OUTBOUND_DENY=$(echo "$OUTBOUND_RULES" | jq '[.[] | select(.access == "Deny")] | length')
      if [[ "$OUTBOUND_DENY" -gt 0 ]]; then
        if [[ "$IS_PRIVATE_ENDPOINT_NSG" == true ]]; then
          result WARN "NSG '$NSG_NAME' lacks explicit outbound DNS allow (port 53) with deny rules present"
          echo "         → Impact likely limited to resources in the PE subnet and diagnostic signal quality."
          echo "         → This is unlikely to be the primary cause of local Windows internet loss."
        else
          result FAIL "NSG '$NSG_NAME' has outbound deny rules but no allow for DNS (port 53)"
          echo "         → Resources in this subnet won't be able to resolve DNS"
          echo "         → Add: az network nsg rule create --nsg-name $NSG_NAME -g $RG --name AllowDns --priority 100 --direction Outbound --access Allow --protocol '*' --destination-port-ranges 53"
        fi
      fi
    fi

    # Check: Does outbound allow HTTPS (port 443)?
    HTTPS_OUTBOUND=$(echo "$OUTBOUND_RULES" | jq '[.[] | select(.access == "Allow") | select(
      (.dstPort == "443" or (.dstPorts // [] | any(. == "443")) or .dstPort == "*")
    )] | length')

    if [[ "$HTTPS_OUTBOUND" -gt 0 ]]; then
      result PASS "NSG '$NSG_NAME' allows outbound HTTPS (port 443)"
    else
      OUTBOUND_DENY=$(echo "$OUTBOUND_RULES" | jq '[.[] | select(.access == "Deny")] | length')
      if [[ "$OUTBOUND_DENY" -gt 0 ]]; then
        if [[ "$IS_PRIVATE_ENDPOINT_NSG" == true ]]; then
          result WARN "NSG '$NSG_NAME' lacks explicit outbound HTTPS allow (port 443) with deny rules present"
          echo "         → Impact likely limited to PE-subnet egress behavior, not broad Windows internet connectivity."
        else
          result FAIL "NSG '$NSG_NAME' has outbound deny rules but no allow for HTTPS (port 443)"
          echo "         → Most Azure PaaS services and private endpoints use port 443"
        fi
      fi
    fi
  done < <(echo "$NSGS" | jq -c '.[]')

  # Check for subnets without NSGs (excluding GatewaySubnet which must not have NSGs)
  echo ""
  echo "    Checking for unprotected subnets..."
  while read -r vnet; do
    VNET_NAME=$(echo "$vnet" | jq -r '.name')
    while read -r subnet; do
      SUBNET_NAME=$(echo "$subnet" | jq -r '.name')
      SUBNET_NSG=$(echo "$subnet" | jq -r '.nsg // ""')
      SUBNET_PREFIX=$(echo "$subnet" | jq -r '.prefix // ""')

      if [[ "$SUBNET_NAME" == "GatewaySubnet" ]]; then
        if [[ -z "$SUBNET_NSG" || "$SUBNET_NSG" == "null" ]]; then
          result PASS "GatewaySubnet ($VNET_NAME) correctly has no NSG (required for VPN Gateway)"
        else
          result WARN "GatewaySubnet ($VNET_NAME) has an NSG — this can cause VPN Gateway issues"
          echo "         → Azure recommends NOT attaching NSGs to the GatewaySubnet"
        fi
      elif [[ -z "$SUBNET_NSG" || "$SUBNET_NSG" == "null" ]]; then
        result WARN "Subnet '$SUBNET_NAME' ($SUBNET_PREFIX) in $VNET_NAME has no NSG"
        echo "         → Consider attaching an NSG for defense in depth"
      fi
    done < <(echo "$vnet" | jq -c '.subnets[]?')
  done < <(echo "$VNETS" | jq -c '.[]')
}

# ─────────────────────────────────────────────────────────
# Run checks across all target resource groups
# ─────────────────────────────────────────────────────────
for RG in "${RG_LIST[@]}"; do
  check_nsg_in_rg "$RG"
done

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
print_summary \
  "1. Review effective rules for a specific NIC:" \
  "   ./scripts/debug/check-nsg.sh --nic <nic-name> --resource-group <rg>" \
  "2. Common fix — allow DNS outbound:" \
  "   az network nsg rule create --nsg-name <nsg> -g <rg> --name AllowDns \\" \
  "     --priority 100 --direction Outbound --access Allow --protocol '*' --destination-port-ranges 53" \
  "3. Common fix — allow HTTPS to private endpoints:" \
  "   az network nsg rule create --nsg-name <nsg> -g <rg> --name AllowHttpsPE \\" \
  "     --priority 110 --direction Outbound --access Allow --protocol Tcp --destination-port-ranges 443 \\" \
  "     --destination-address-prefix <pe-subnet-cidr>"
