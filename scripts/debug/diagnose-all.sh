#!/usr/bin/env bash
# -------------------------------------------------------------------
# diagnose-all.sh — Run all connectivity diagnostics in sequence
#
# Runs the full diagnostic suite and produces a summary report.
# Optionally test resolution of a specific hostname, and scan
# spoke resource groups for private endpoints.
#
# Usage:
#   ./scripts/debug/diagnose-all.sh
#   ./scripts/debug/diagnose-all.sh myapp.azurewebsites.net
#   ./scripts/debug/diagnose-all.sh --all                    # scan all spoke RGs for PEs
#   ./scripts/debug/diagnose-all.sh --resource-group RG-SPOKE myapp.azurewebsites.net
# -------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
HOSTNAME=""
PE_ARGS=()

for arg in "${ORIG_ARGS[@]:-}"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    echo "diagnose-all.sh — Run all connectivity diagnostics in sequence"
    echo ""
    echo "Usage:"
    echo "  ./scripts/debug/diagnose-all.sh [hostname]"
    echo "  ./scripts/debug/diagnose-all.sh --all [hostname]"
    echo "  ./scripts/debug/diagnose-all.sh --resource-group <rg> [hostname]"
    exit 0
  fi
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) PE_ARGS+=("--all"); shift ;;
    --resource-group) PE_ARGS+=("$2"); shift 2 ;;
    *) HOSTNAME="$1"; shift ;;
  esac
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Azure Landing Zone — Full Diagnostics"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Running all checks. This may take a few minutes..."
echo ""

TOTAL_CHECKS=0
FAILED_CHECKS=()

run_check() {
  local name="$1"
  shift
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  echo ""
  echo "── Step $TOTAL_CHECKS: $name ──"
  if "$@"; then
    true
  else
    FAILED_CHECKS+=("$name")
  fi
}

# 1. VPN connectivity
run_check "VPN Connection" "$SCRIPT_DIR/check-vpn.sh"

# 2. DNS server health
run_check "DNS Server" "$SCRIPT_DIR/check-dns-server.sh"

# 3. DNS resolution
if [[ -n "$HOSTNAME" ]]; then
  run_check "DNS Resolution ($HOSTNAME)" "$SCRIPT_DIR/check-dns.sh" "$HOSTNAME"
else
  run_check "DNS Resolution" "$SCRIPT_DIR/check-dns.sh"
fi

# 4. VNet peerings
run_check "VNet Peerings" "$SCRIPT_DIR/check-peerings.sh"

# 5. Private DNS zones
run_check "Private DNS Zones" "$SCRIPT_DIR/check-private-dns-zones.sh"

# 6. Private endpoints (hub + optional spoke RGs)
if [[ ${#PE_ARGS[@]} -gt 0 ]]; then
  run_check "Private Endpoints (hub + spokes)" "$SCRIPT_DIR/check-private-endpoints.sh" "${PE_ARGS[@]}"
else
  run_check "Private Endpoints (hub)" "$SCRIPT_DIR/check-private-endpoints.sh"
fi

# 7. NSG rules
run_check "NSG Rules" "$SCRIPT_DIR/check-nsg.sh"

# Final report
PASSED_CHECKS=$((TOTAL_CHECKS - ${#FAILED_CHECKS[@]}))
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Summary: $PASSED_CHECKS passed, ${#FAILED_CHECKS[@]} failed, 0 warnings"
echo "═══════════════════════════════════════════════════════"
echo ""
if [[ ${#FAILED_CHECKS[@]} -eq 0 ]]; then
  echo "  ✅ All checks passed!"
else
  echo "  ❌ ${#FAILED_CHECKS[@]} check(s) reported failures:"
  for check in "${FAILED_CHECKS[@]}"; do
    echo "     • $check"
  done
  echo ""
  echo "Suggested next steps:"
  echo "  VPN not connected? → Open Azure VPN Client on Windows → Connect"
  echo "  DNS not resolving? → ./scripts/debug/check-dns-server.sh --restart"
  echo "  Can't reach spoke? → ./scripts/debug/check-peerings.sh"
  echo "  PE resolves to public IP? → ./scripts/debug/check-private-dns-zones.sh <zone>"
  echo "  TCP blocked? → ./scripts/debug/check-nsg.sh --all"
  exit 1
fi
echo ""
