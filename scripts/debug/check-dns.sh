#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-dns.sh — Test DNS resolution from WSL2 through the VPN
#
# Tests whether private endpoint DNS names resolve to private IPs
# (10.x.x.x / 172.16.x.x) rather than public IPs, and whether the
# configured DNS server is reachable.
#
# Usage:
#   ./scripts/debug/check-dns.sh [hostname-to-resolve]
#
# Examples:
#   ./scripts/debug/check-dns.sh myapp.azurewebsites.net
#   ./scripts/debug/check-dns.sh mystorageaccount.blob.core.windows.net
#   ./scripts/debug/check-dns.sh   # (runs default checks only)
# -------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
source "$SCRIPT_DIR/load-config.sh"

check_help "check-dns.sh" "Test DNS resolution through VPN for a hostname" \
  "./scripts/debug/check-dns.sh [hostname]"

HOSTNAME="${1:-}"

print_header "DNS Resolution Diagnostics"

# 1. Check if DNS server IP is reachable
print_step 1 "DNS server reachability ($DBG_DNS_IP)"
if nc -z -w 3 "$DBG_DNS_IP" 53 2>/dev/null; then
  result PASS "DNS server $DBG_DNS_IP is reachable on port 53"
else
  result FAIL "DNS server $DBG_DNS_IP is NOT reachable on port 53"
  echo "         → The DNS resolver VM may be stopped or CoreDNS is not running."
  echo "         → Run: ./scripts/debug/check-dns-server.sh"
fi

# 2. Check WSL2 /etc/resolv.conf
print_step 2 "WSL2 DNS configuration"
if [[ -f /etc/resolv.conf ]]; then
  RESOLVERS=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}')
  echo "  Current nameservers in /etc/resolv.conf:"
  grep '^nameserver' /etc/resolv.conf | while read -r line; do echo "    $line"; done
  if echo "$RESOLVERS" | grep -q "$DBG_DNS_IP"; then
    result PASS "Azure DNS server $DBG_DNS_IP is configured in resolv.conf"
  else
    result WARN "Azure DNS server $DBG_DNS_IP is NOT in resolv.conf (VPN client handles DNS routing on Windows side)"
  fi
else
  result WARN "/etc/resolv.conf not found"
fi

# 3. Test resolution of the custom hostname if provided
if [[ -n "$HOSTNAME" ]]; then
  print_step 3 "Resolving $HOSTNAME"

  # Try with system resolver
  echo "  Using system DNS:"
  if RESULT=$(nslookup "$HOSTNAME" 2>&1); then
    echo "$RESULT" | sed 's/^/    /'
    if echo "$RESULT" | grep -qE 'Address:.*\b(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
      result PASS "$HOSTNAME resolves to a private IP (system DNS)"
    elif echo "$RESULT" | grep -q 'Address:'; then
      result WARN "$HOSTNAME resolves to a PUBLIC IP — private endpoint DNS may not be working"
    fi
  else
    result FAIL "Failed to resolve $HOSTNAME using system DNS"
    echo "$RESULT" | sed 's/^/    /'
  fi

  # Try directly against the Azure DNS server
  echo ""
  echo "  Using Azure DNS server ($DBG_DNS_IP) directly:"
  if RESULT=$(nslookup "$HOSTNAME" "$DBG_DNS_IP" 2>&1); then
    echo "$RESULT" | sed 's/^/    /'
    if echo "$RESULT" | grep -qE 'Address:.*\b(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
      result PASS "$HOSTNAME resolves to a private IP via Azure DNS server"
    elif echo "$RESULT" | grep -q 'Address:'; then
      result WARN "$HOSTNAME resolves to a PUBLIC IP via Azure DNS — check private DNS zone"
    fi
  else
    result FAIL "Failed to resolve $HOSTNAME via Azure DNS server at $DBG_DNS_IP"
    echo "         → DNS server may be down, or VPN tunnel is not routing to $DBG_DNS_IP"
  fi

  # Check for privatelink CNAME
  echo ""
  echo "  Checking for privatelink CNAME chain:"
  if DIG_RESULT=$(dig +short CNAME "$HOSTNAME" 2>/dev/null); then
    if echo "$DIG_RESULT" | grep -q 'privatelink'; then
      result PASS "CNAME chain includes privatelink zone: $DIG_RESULT"
    elif [[ -z "$DIG_RESULT" ]]; then
      result WARN "No CNAME record found — hostname may not have a private endpoint"
    else
      result WARN "CNAME does not include privatelink: $DIG_RESULT"
    fi
  else
    result WARN "dig not available or failed (install with: sudo apt-get install -y dnsutils)"
  fi
fi

# 4. Test well-known Azure DNS resolution
print_step 4 "Azure DNS infrastructure test"
if RESULT=$(nslookup "management.azure.com" 2>&1) && echo "$RESULT" | grep -q 'Address:'; then
  result PASS "Can resolve management.azure.com (Azure control plane)"
else
  result FAIL "Cannot resolve management.azure.com — general DNS is broken"
fi

# Summary
print_summary \
  "1. Check DNS server VM status:  ./scripts/debug/check-dns-server.sh" \
  "2. Check VPN connection:        ./scripts/debug/check-vpn.sh" \
  "3. Check private DNS zones:     ./scripts/debug/check-private-dns-zones.sh"
