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
VPN_ROUTE_LINES=$(echo "$ROUTES" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | grep -Ev ' dev eth0 proto kernel| scope link src ' || true)
if [[ -n "$VPN_ROUTE_LINES" ]]; then
  echo "$VPN_ROUTE_LINES" | head -10 | sed 's/^/    /'
  result PASS "VPN routes found in routing table"
else
  result WARN "No obvious VPN routes in WSL2 routing table (VPN routes may be on the Windows host)"
  echo "         → WSL2 typically relies on the Windows host for VPN routing."
  echo "         → Check VPN connection in the Azure VPN Client app on Windows."
fi

# 2. Test connectivity to the DNS server IP (hub VNet)
print_step 2 "Connectivity to hub VNet (DNS server at $DBG_DNS_IP)"
if nc -z -w 3 "$DBG_DNS_IP" 53 2>/dev/null; then
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
    GW_STATE=$(run_with_timeout 25 az network vnet-gateway show \
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
    VPN_GW=$(run_with_timeout 25 az network vnet-gateway list \
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
    VPN_CLIENT_CONFIG=$(run_with_timeout 25 az network vnet-gateway show \
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

# Function to search and validate VPN XML files
check_vpn_xml_config() {
  local dns_ip="$1"
  local found_valid_xml=false
  local xml_issues=()

  echo "  Searching for VPN profile XML files on Windows (timeout: 5s)..."

  # Timeout wrapper for slow /mnt/c operations
  search_vpn_files() {
    local timeout_cmd="timeout 5"

    # Check if VPN profiles exist in common locations
    if [[ -d "/mnt/c/Users" ]]; then
      # Use timeout to prevent hanging on /mnt/c operations
      $timeout_cmd bash -c "
        for user_dir in /mnt/c/Users/*/AppData/Roaming/Microsoft/Network/Connections/Pbk; do
          [[ -d \"\$user_dir\" ]] && find \"\$user_dir\" -maxdepth 1 -type f -name '*.pbk' 2>/dev/null | head -5
        done
      " || true

      $timeout_cmd bash -c "
        for user_dir in /mnt/c/Users/*/Downloads; do
          [[ -d \"\$user_dir\" ]] && find \"\$user_dir\" -maxdepth 1 -type f \\( -name '*.xml' -o -name '*.pbk' \\) 2>/dev/null | head -5
        done
      " || true
    fi
  }

  local found_files=$(search_vpn_files)

  if [[ -n "$found_files" ]]; then
    echo "$found_files" | while read -r pbk_file; do
      [[ -z "$pbk_file" ]] && continue

      echo "    Found profile: $(basename "$pbk_file")"

      # Check for DNS server entry (non-blocking timeout)
      if timeout 2 grep -q "$dns_ip" "$pbk_file" 2>/dev/null; then
        echo "      ✓ DNS server $dns_ip found in configuration"
        found_valid_xml=true
      else
        echo "      ⚠ DNS server $dns_ip NOT found in configuration"
        xml_issues+=("Missing DNS server $dns_ip")
      fi
    done
  fi

  # Report findings
  echo ""
  if [[ "$found_valid_xml" == true ]]; then
    result PASS "VPN XML configuration found with correct DNS server"
    return 0
  elif [[ ${#xml_issues[@]} -gt 0 ]]; then
    result WARN "VPN profile found but DNS server entry is incorrect or missing"
    for issue in "${xml_issues[@]}"; do
      echo "      • $issue"
    done
    return 1
  else
    result WARN "VPN XML configuration files not found in typical locations"
    echo ""
    echo "  Next steps:"
    echo "    1. Download VPN profile from Azure Portal → VPN Gateway → Point-to-site configuration"
    echo "    2. Extract the profile ZIP file"
    echo "    3. Locate the .xml file (typically under 'OpenVPN/' folder)"
    echo "    4. Edit the XML and add/verify this DNS configuration:"
    echo "       <dnsservers>"
    echo "         <dnsserver>$dns_ip</dnsserver>"
    echo "       </dnsservers>"
    echo "    5. Re-import the profile into Azure VPN Client on Windows"
    echo "    6. Verify connection status in Azure VPN Client"
    return 2
  fi
}

# Run the XML check
check_vpn_xml_config "$DBG_DNS_IP" || true

# 5. Check Windows VPN status via PowerShell (if accessible)
print_step 5 "Windows VPN adapter check"
if command -v powershell.exe &>/dev/null; then
  # Check Windows VPN connection state first (ground truth on host)
  WIN_VPN_CONN=$(timeout 15 powershell.exe -NoProfile -Command "Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue | Select-Object Name, ConnectionStatus, SplitTunneling | ConvertTo-Json -Depth 3 -Compress" 2>/dev/null | tr -d '\r' || echo "")

  if [[ -n "$WIN_VPN_CONN" && "$WIN_VPN_CONN" != "null" ]]; then
    CONNECTED_VPN_COUNT=$(echo "$WIN_VPN_CONN" | jq '[if type=="array" then .[] else . end | select(.ConnectionStatus=="Connected")] | length' 2>/dev/null || echo "0")
    if [[ "$CONNECTED_VPN_COUNT" -gt 0 ]]; then
      CONNECTED_VPNS=$(echo "$WIN_VPN_CONN" | jq -r '[if type=="array" then .[] else . end | select(.ConnectionStatus=="Connected") | .Name] | unique | join(", ")' 2>/dev/null || echo "")
      echo "  Connected VPN profile(s): ${CONNECTED_VPNS:-unknown}"
      result PASS "Windows reports at least one connected VPN profile"

      SPLIT_TUNNEL_DISABLED=$(echo "$WIN_VPN_CONN" | jq '[if type=="array" then .[] else . end | select(.ConnectionStatus=="Connected" and (.SplitTunneling == false))] | length' 2>/dev/null || echo "0")
      if [[ "$SPLIT_TUNNEL_DISABLED" -gt 0 ]]; then
        result WARN "Connected VPN profile uses forced tunneling (SplitTunneling=false)"
        echo "         → This can route all internet traffic through VPN and cause internet loss if remote egress is unavailable."
      else
        result PASS "Connected VPN profile is split-tunnel or does not enforce forced tunneling"
      fi
    else
      result WARN "Windows reports no connected VPN profiles"
      echo "         → Open Azure VPN Client and confirm profile state is Connected."
    fi
  else
    result WARN "Could not query Windows VPN connection state (Get-VpnConnection returned no data)"
  fi

  # Use cached adapter name if available for faster targeted check
  if [[ -n "$DBG_VPN_ADAPTER_NAME" ]]; then
    echo "  Checking cached VPN adapter: $DBG_VPN_ADAPTER_NAME"
    ADAPTER_STATUS=$(timeout 15 powershell.exe -NoProfile -Command "Get-NetAdapter -Name '$DBG_VPN_ADAPTER_NAME' -ErrorAction SilentlyContinue | Select-Object Name, Status | ConvertTo-Json" 2>/dev/null || echo "")
    if [[ -n "$ADAPTER_STATUS" && ! "$ADAPTER_STATUS" =~ ^[[:space:]]*$ ]]; then
      echo "    Status: $(echo "$ADAPTER_STATUS" | grep -o '"Status":"[^"]*"' || echo 'Unknown')"
      result PASS "VPN adapter '$DBG_VPN_ADAPTER_NAME' found on Windows host"
    else
      result WARN "Cached adapter '$DBG_VPN_ADAPTER_NAME' not found or timed out"

      echo "  Falling back to heuristic adapter discovery (Azure/VPN/OpenVPN/WireGuard)..."
      DISCOVERED_ADAPTERS=$(timeout 20 powershell.exe -NoProfile -Command "Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ( $_.Name -match 'Azure|VPN|OpenVPN|WireGuard|WAN Miniport' -or $_.InterfaceDescription -match 'Azure|VPN|OpenVPN|WireGuard|WAN Miniport' ) } | Select-Object Name, InterfaceDescription, Status | ConvertTo-Json -Depth 3 -Compress" 2>/dev/null | tr -d '\r' || echo "")
      if [[ -n "$DISCOVERED_ADAPTERS" && "$DISCOVERED_ADAPTERS" != "null" ]]; then
        echo "    Candidate active VPN adapters detected on Windows:"
        echo "$DISCOVERED_ADAPTERS" | jq -r '. as $v | if ($v|type)=="array" then $v[] else $v end | "      - \(.Name) [\(.Status)]"' 2>/dev/null || true
        result PASS "Heuristic adapter discovery found at least one active VPN-like adapter"
      else
        result WARN "No active VPN-like adapters found by heuristic discovery"
      fi
    fi
  else
    result WARN "No cached VPN adapter name — run sync-config.sh to discover"

    echo "  Running heuristic adapter discovery (Azure/VPN/OpenVPN/WireGuard)..."
    DISCOVERED_ADAPTERS=$(timeout 20 powershell.exe -NoProfile -Command "Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ( $_.Name -match 'Azure|VPN|OpenVPN|WireGuard|WAN Miniport' -or $_.InterfaceDescription -match 'Azure|VPN|OpenVPN|WireGuard|WAN Miniport' ) } | Select-Object Name, InterfaceDescription, Status | ConvertTo-Json -Depth 3 -Compress" 2>/dev/null | tr -d '\r' || echo "")
    if [[ -n "$DISCOVERED_ADAPTERS" && "$DISCOVERED_ADAPTERS" != "null" ]]; then
      echo "    Candidate active VPN adapters detected on Windows:"
      echo "$DISCOVERED_ADAPTERS" | jq -r '. as $v | if ($v|type)=="array" then $v[] else $v end | "      - \(.Name) [\(.Status)]"' 2>/dev/null || true
      result PASS "Heuristic adapter discovery found at least one active VPN-like adapter"
    else
      result WARN "No active VPN-like adapters found by heuristic discovery"
    fi
  fi

  # Check Windows DNS configuration for our DNS server
  echo ""
  echo "  Checking if $DBG_DNS_IP is configured as a DNS server on Windows..."
  WIN_DNS=$(timeout 10 powershell.exe -NoProfile -Command "Get-DnsClientServerAddress | ConvertTo-Json -Depth 2" 2>/dev/null || echo "")
  if [[ -n "$WIN_DNS" ]] && echo "$WIN_DNS" | grep -q "$DBG_DNS_IP" 2>/dev/null; then
    result PASS "Windows has $DBG_DNS_IP configured as a DNS server"
  else
    result WARN "$DBG_DNS_IP not found in Windows DNS client configuration"
    echo "         → Verify VPN XML has <dnsservers><dnsserver>$DBG_DNS_IP</dnsserver></dnsservers>"
  fi

  # Check default route behavior on Windows host
  print_step 6 "Windows default route sanity check"
  DEFAULT_ROUTES=$(timeout 15 powershell.exe -NoProfile -Command "Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, ifMetric | Select-Object -First 5 InterfaceAlias, NextHop, RouteMetric, ifMetric | ConvertTo-Json -Depth 3 -Compress" 2>/dev/null | tr -d '\r' || echo "")
  if [[ -n "$DEFAULT_ROUTES" && "$DEFAULT_ROUTES" != "null" ]]; then
    echo "  Top Windows default route candidates (lowest metric first):"
    echo "$DEFAULT_ROUTES" | jq -r '. as $v | if ($v|type)=="array" then $v[] else $v end | "    - if=\(.InterfaceAlias // "unknown") nextHop=\(.NextHop // "?") routeMetric=\(.RouteMetric // "?") ifMetric=\(.ifMetric // "?")"' 2>/dev/null || true

    VPN_DEFAULT_ROUTE_COUNT=$(echo "$DEFAULT_ROUTES" | jq '[if type=="array" then .[] else . end | select((.InterfaceAlias // "") | test("Azure|VPN|OpenVPN|WireGuard"; "i"))] | length' 2>/dev/null || echo "0")
    if [[ "$VPN_DEFAULT_ROUTE_COUNT" -gt 0 ]]; then
      result WARN "A low-metric default route appears to use a VPN-like interface"
      echo "         → Possible forced-tunnel behavior. This can explain Windows internet loss while VPN is connected."
    else
      result PASS "Default route does not appear to be pinned to a VPN-like interface"
    fi
  else
    result WARN "Could not query Windows default routes"
  fi
else
  result WARN "powershell.exe not available from WSL2 — cannot check Windows VPN status"
fi

# Summary
print_summary \
  "Open Azure VPN Client on Windows and verify it shows 'Connected'" \
  "Re-download VPN profile and add DNS server entry to XML" \
  "Check DNS server VM:  ./scripts/debug/check-dns-server.sh" \
  "Inspect Windows default routes when internet drops: powershell.exe -NoProfile -Command \"Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0'\""
