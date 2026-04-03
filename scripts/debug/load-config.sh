#!/usr/bin/env bash
# -------------------------------------------------------------------
# load-config.sh — Shared helper for all debug scripts
#
# Provides:
#   1. Config loading from .azure-debug-config.json (DBG_* env vars)
#   2. Auto-sync with Azure if config is stale (>1 hour)
#   3. Shared output functions for consistent formatting:
#      - result PASS|FAIL|WARN "message"
#      - print_header "Title"
#      - print_step N "Description"
#      - print_summary [suggested-next-steps]
#      - check_help "$@" "script-name" "description" "usage-lines..."
# -------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.azure-debug-config.json"
SYNC_MARKER="$REPO_ROOT/.azure-debug-config.last-sync"
SYNC_SCRIPT="$REPO_ROOT/scripts/ipam/sync-config.sh"
SYNC_MAX_AGE=3600 # seconds (1 hour)

# ─── Shared output functions ───────────────────────────────────────

PASS=0
FAIL=0
WARN=0

result() {
  local status="$1" msg="$2"
  case "$status" in
    PASS) echo "  ✅ $msg"; ((PASS++)) ;;
    FAIL) echo "  ❌ $msg"; ((FAIL++)) ;;
    WARN) echo "  ⚠️  $msg"; ((WARN++)) ;;
  esac
}

print_header() {
  local title="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  $title"
  echo "═══════════════════════════════════════════════════════"
}

print_step() {
  local num="$1" desc="$2"
  echo ""
  echo "── Step $num: $desc ──"
}

print_summary() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Summary: $PASS passed, $FAIL failed, $WARN warnings"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  if [[ $FAIL -gt 0 && $# -gt 0 ]]; then
    echo "Suggested next steps:"
    while [[ $# -gt 0 ]]; do
      echo "  $1"
      shift
    done
  fi
  [[ $FAIL -gt 0 ]] && exit 1 || true
}

check_help() {
  local script_name="$1" description="$2"
  shift 2
  local -a usage_lines=("$@")

  for arg in "${ORIG_ARGS[@]:-}"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      echo "$script_name — $description"
      echo ""
      echo "Usage:"
      for line in "${usage_lines[@]}"; do
        echo "  $line"
      done
      exit 0
    fi
  done
}

# ─── Config loading ────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found."
  echo "Copy .azure-debug-config.example.json to .azure-debug-config.json and fill in your values."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed. Install with: sudo apt-get install -y jq"
  exit 1
fi

# Auto-sync if stale (skip if SKIP_SYNC=1 to avoid recursion or in CI)
if [[ "${SKIP_SYNC:-}" != "1" && -f "$SYNC_SCRIPT" ]]; then
  NEEDS_SYNC=false
  if [[ ! -f "$SYNC_MARKER" ]]; then
    NEEDS_SYNC=true
  else
    LAST_SYNC=$(stat -c %Y "$SYNC_MARKER" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - LAST_SYNC ))
    if [[ "$AGE" -gt "$SYNC_MAX_AGE" ]]; then
      NEEDS_SYNC=true
    fi
  fi

  if $NEEDS_SYNC; then
    echo "⟳ Config is stale (>1h since last sync). Syncing with Azure..."
    SKIP_SYNC=1 bash "$SYNC_SCRIPT" --yes 2>/dev/null || echo "  ⚠️  Sync failed (Azure CLI may not be logged in). Using cached config."
    touch "$SYNC_MARKER"
    echo ""
  fi
fi

export DBG_TENANT_ID=$(jq -r '.tenantId' "$CONFIG_FILE")
export DBG_SUBSCRIPTION_ID=$(jq -r '.subscriptionId' "$CONFIG_FILE")
export DBG_HUB_RG=$(jq -r '.hub.resourceGroupName' "$CONFIG_FILE")
export DBG_HUB_VNET_ID=$(jq -r '.hub.vnetResourceId' "$CONFIG_FILE")
export DBG_HUB_VNET_NAME=$(jq -r '.hub.vnetName' "$CONFIG_FILE")
export DBG_HUB_ADDRESS_SPACE=$(jq -r '.hub.addressSpace // ""' "$CONFIG_FILE")
export DBG_DNS_VM_ID=$(jq -r '.hub.dnsServerVmResourceId' "$CONFIG_FILE")
export DBG_DNS_VM_NAME=$(jq -r '.hub.dnsServerVmName' "$CONFIG_FILE")
export DBG_DNS_IP=$(jq -r '.hub.dnsServerPrivateIp' "$CONFIG_FILE")
export DBG_HUB_LOCATION=$(jq -r '.hub.location' "$CONFIG_FILE")
export DBG_VPN_GW_NAME=$(jq -r '.hub.vpnGateway.name // ""' "$CONFIG_FILE")
export DBG_VPN_GW_ID=$(jq -r '.hub.vpnGateway.resourceId // ""' "$CONFIG_FILE")
export DBG_VPN_GW_SKU=$(jq -r '.hub.vpnGateway.sku // ""' "$CONFIG_FILE")
export DBG_VPN_P2S_POOL=$(jq -r '.hub.vpnGateway.p2sAddressPool // [] | join(",")' "$CONFIG_FILE")
export DBG_VPN_ADAPTER_NAME=$(jq -r '.local.vpnAdapterName // ""' "$CONFIG_FILE")
export DBG_GHA_RUNNER_VM_NAME=$(jq -r '.hub.ghaRunnerVmName // ""' "$CONFIG_FILE")
export DBG_GHA_RUNNER_VM_ID=$(jq -r '.hub.ghaRunnerVmResourceId // ""' "$CONFIG_FILE")
export DBG_SPOKE_COUNT=$(jq '.spokes | length' "$CONFIG_FILE")

echo "✓ Loaded config: tenant=$DBG_TENANT_ID subscription=$DBG_SUBSCRIPTION_ID hub-rg=$DBG_HUB_RG"
