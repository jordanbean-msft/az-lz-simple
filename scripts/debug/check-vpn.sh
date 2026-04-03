#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-vpn.sh — Verify Azure Point-to-Site VPN connectivity from WSL2
#
# Checks whether the VPN tunnel is up, whether traffic is routing
# through the VPN, and whether the VPN gateway is healthy.
#
# Usage:
#   ./scripts/debug/check-vpn.sh
# -------------------------------------------------------------------
set -euo pipefail
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help "check-vpn.sh" "Verify Azure P2S VPN connectivity from WSL2" \
  "./scripts/debug/check-vpn.sh"

print_header "VPN Connectivity Diagnostics"

# 1. Check if VPN-related routes exist
print_step 1 "Check routing table for VPN routes"
echo "  Looking for routes to 10.0.0.0/8 or 172.16.0.0/12 (custom routes)..."
ROUTES=$(ip route 2>/dev/null || true)
if echo "$ROUTES" | grep -qE '10\.|172\.(1[6-9]|2[0-9]|3[01])\.'; then
  echo "$ROUTES" | grep -E '10\.|172\.(1[6-9]|2[0-9]|3[01])\.' | head -10 | sed 's/^/    /'
  result PASS "VPN routes found in routing table"
else
  result WARN "No obvious VPN routes in WSL2 routing table (VPN routes may be on the Windows host)"
  echo "         → WSL2 typically relies on the Windows host for VPN routing."
  echo "         → Check VPN connection in the Azure VPN Client app on Windows."
fi

# 2. Test connectivity to the DNS server IP (hub VNet)
print_step 2 "Connectivity to hub VNet (DNS server at $DBG_DNS_IP)"
if ping -c 2 -W 3 "$DBG_DNS_IP" &>/dev/null; then
  result PASS "Can ping DNS server at $DBG_DNS_IP"
elif nc -z -w 3 "$DBG_DNS_IP" 53 2>/dev/null; then
  result PASS "DNS server $DBG_DNS_IP reachable on port 53 (ICMP blocked but TCP works)"
else
  result FAIL "Cannot reach DNS server at $DBG_DNS_IP"
  echo "         → VPN may not be connected, or routing is misconfigured."
  echo "         → Check Azure VPN Client on Windows is connected."
fi

# 3. Check Azure VPN Gateway health via Azure CLI
print_step 3 "VPN Gateway status (Azure)"
if command -v az &>/dev/null; then
  # Use cached gateway info if available, fall back to live query
  if [[ -n "$DBG_VPN_GW_NAME" ]]; then
    echo "  Using cached gateway info: $DBG_VPN_GW_NAME (SKU: $DBG_VPN_GW_SKU)"
    GW_NAME="$DBG_VPN_GW_NAME"
    GW_SKU="$DBG_VPN_GW_SKU"

    # Only query provisioning state live (it's the volatile part)
    GW_STATE=$(az network vnet-gateway show \
      --resource-group "$DBG_HUB_RG" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --name "$GW_NAME" \
      --query "provisioningState" -o tsv 2>/dev/null || echo "unknown")
    echo "    Gateway: $GW_NAME  State: $GW_STATE  SKU: $GW_SKU"
    if [[ "$GW_STATE" == "Succeeded" ]]; then
      result PASS "VPN Gateway provisioning state is Succeeded"
    else
      result FAIL "VPN Gateway provisioning state is $GW_STATE"
    fi
  else
    echo "  Querying VPN Gateway in $DBG_HUB_RG..."
    VPN_GW=$(az network vnet-gateway list \
      --resource-group "$DBG_HUB_RG" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --query "[0].{name:name, provisioningState:provisioningState, vpnType:vpnType, sku:sku.name}" \
      -o json 2>/dev/null || echo "")

    if [[ -n "$VPN_GW" && "$VPN_GW" != "[]" ]]; then
      GW_NAME=$(echo "$VPN_GW" | jq -r '.name // "unknown"')
      GW_STATE=$(echo "$VPN_GW" | jq -r '.provisioningState // "unknown"')
      GW_SKU=$(echo "$VPN_GW" | jq -r '.sku // "unknown"')
      echo "    Gateway: $GW_NAME  State: $GW_STATE  SKU: $GW_SKU"
      if [[ "$GW_STATE" == "Succeeded" ]]; then
        result PASS "VPN Gateway provisioning state is Succeeded"
      else
        result FAIL "VPN Gateway provisioning state is $GW_STATE"
      fi
    else
      result WARN "No VPN Gateway found in $DBG_HUB_RG"
    fi
  fi

  # Check P2S VPN client address pool (use cached if available)
  echo ""
  echo "  Checking P2S VPN client address pool..."
  if [[ -n "$DBG_VPN_P2S_POOL" ]]; then
    echo "    Client address pool: $DBG_VPN_P2S_POOL"
    result PASS "P2S VPN client address pool is configured (cached)"
  elif [[ -n "${GW_NAME:-}" ]]; then
    VPN_CLIENT_CONFIG=$(az network vnet-gateway show \
      --resource-group "$DBG_HUB_RG" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --name "$GW_NAME" \
      --query "vpnClientConfiguration.vpnClientAddressPool.addressPrefixes" \
      -o json 2>/dev/null || echo "[]")
    if [[ "$VPN_CLIENT_CONFIG" != "[]" && -n "$VPN_CLIENT_CONFIG" ]]; then
      echo "    Client address pool: $VPN_CLIENT_CONFIG"
      result PASS "P2S VPN client address pool is configured"
    else
      result WARN "Could not retrieve P2S client address pool"
    fi
  fi
else
  result WARN "Azure CLI not available — skipping gateway health check"
fi

# 4. Check VPN XML configuration for DNS
print_step 4 "VPN client XML configuration check"
echo "  Tip: After downloading a new VPN client profile, ensure the XML includes:"
echo "    <clientconfig>"
echo "      <dnsservers>"
echo "        <dnsserver>$DBG_DNS_IP</dnsserver>"
echo "      </dnsservers>"
echo "    </clientconfig>"
echo ""
echo "  If the <dnsservers> element is missing, private DNS resolution will fail."
echo "  Re-download and edit the profile, then re-import into Azure VPN Client."
result WARN "VPN XML config must be checked manually in the Azure VPN Client app on Windows"

# 5. Check Windows VPN status via PowerShell (if accessible)
print_step 5 "Windows VPN adapter check"
if command -v powershell.exe &>/dev/null; then
  # Use cached adapter name if available for faster targeted check
  if [[ -n "$DBG_VPN_ADAPTER_NAME" ]]; then
    echo "  Checking cached VPN adapter: $DBG_VPN_ADAPTER_NAME"
    ADAPTER_STATUS=$(powershell.exe -NoProfile -Command "Get-NetAdapter -Name '$DBG_VPN_ADAPTER_NAME' -ErrorAction SilentlyContinue | Select-Object Name, Status, InterfaceDescription | Format-Table -AutoSize | Out-String" 2>/dev/null || echo "")
    if [[ -n "$ADAPTER_STATUS" && ! "$ADAPTER_STATUS" =~ ^[[:space:]]*$ ]]; then
      echo "$ADAPTER_STATUS" | sed 's/^/    /'
      result PASS "VPN adapter '$DBG_VPN_ADAPTER_NAME' found on Windows host"
    else
      echo "  Cached adapter '$DBG_VPN_ADAPTER_NAME' not found, scanning all adapters..."
      VPN_ADAPTERS=$(powershell.exe -NoProfile -Command "Get-NetAdapter | Where-Object { \$_.InterfaceDescription -like '*VPN*' -or \$_.InterfaceDescription -like '*TAP*' -or \$_.InterfaceDescription -like '*WireGuard*' -or \$_.Name -like '*Azure*' } | Select-Object Name, Status, InterfaceDescription | Format-Table -AutoSize | Out-String" 2>/dev/null || echo "")
      if [[ -n "$VPN_ADAPTERS" && ! "$VPN_ADAPTERS" =~ ^[[:space:]]*$ ]]; then
        echo "$VPN_ADAPTERS" | sed 's/^/    /'
        result WARN "Cached adapter name may be stale — run sync-config.sh to update"
      else
        result WARN "No VPN adapters detected — VPN may not be connected"
      fi
    fi
  else
    echo "  Checking Windows VPN adapters..."
    VPN_ADAPTERS=$(powershell.exe -NoProfile -Command "Get-NetAdapter | Where-Object { \$_.InterfaceDescription -like '*VPN*' -or \$_.InterfaceDescription -like '*TAP*' -or \$_.InterfaceDescription -like '*WireGuard*' -or \$_.Name -like '*Azure*' } | Select-Object Name, Status, InterfaceDescription | Format-Table -AutoSize | Out-String" 2>/dev/null || echo "")
    if [[ -n "$VPN_ADAPTERS" && ! "$VPN_ADAPTERS" =~ ^[[:space:]]*$ ]]; then
      echo "$VPN_ADAPTERS" | sed 's/^/    /'
      result PASS "VPN adapter(s) found on Windows host"
    else
      result WARN "No VPN adapters detected — VPN may not be connected or uses a different adapter name"
      echo "         → Open Azure VPN Client on Windows and verify connection status."
    fi
  fi

  # Check Windows DNS configuration
  echo ""
  echo "  Checking Windows DNS client resolution for Azure DNS server..."
  WIN_DNS=$(powershell.exe -NoProfile -Command "Get-DnsClientServerAddress | Where-Object { \$_.ServerAddresses -contains '$DBG_DNS_IP' } | Select-Object InterfaceAlias, ServerAddresses | Format-Table -AutoSize | Out-String" 2>/dev/null || echo "")
  if [[ -n "$WIN_DNS" && ! "$WIN_DNS" =~ ^[[:space:]]*$ ]]; then
    echo "$WIN_DNS" | sed 's/^/    /'
    result PASS "Windows has $DBG_DNS_IP configured as DNS on a VPN interface"
  else
    result WARN "Windows does not show $DBG_DNS_IP as a DNS server on any interface"
    echo "         → VPN XML config may be missing <dnsservers> entry."
  fi
else
  result WARN "powershell.exe not available from WSL2 — cannot check Windows VPN status"
fi

# Summary
print_summary \
  "Open Azure VPN Client on Windows and verify it shows 'Connected'" \
  "Re-download VPN profile and add DNS server entry to XML" \
  "Check DNS server VM:  ./scripts/debug/check-dns-server.sh"
