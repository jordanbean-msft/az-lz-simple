#!/usr/bin/env bash
# -------------------------------------------------------------------
# manage-vm.sh — Start, stop, restart, or deallocate hub VMs
#
# Manages the DNS server VM and GitHub Actions runner VM by alias
# or by explicit VM name. Reads VM names from .azure-debug-config.json.
#
# Usage:
#   ./scripts/debug/manage-vm.sh <action> <vm-alias|vm-name>
#
# Actions:
#   start       Start a stopped/deallocated VM
#   stop        Stop (deallocate) a VM
#   restart     Restart a running VM
#   status      Show VM power state
#
# VM aliases:
#   dns         DNS resolver VM (hub.dnsServerVmName)
#   gha-runner  GitHub Actions runner VM (hub.ghaRunnerVmName)
#
# Examples:
#   ./scripts/debug/manage-vm.sh status dns
#   ./scripts/debug/manage-vm.sh start gha-runner
#   ./scripts/debug/manage-vm.sh stop dns
#   ./scripts/debug/manage-vm.sh restart VM-DNS-YV4QKEFIBMVUQ
# -------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

ACTION="${1:-}"
VM_ALIAS="${2:-}"

usage() {
  echo "Usage: $0 <start|stop|restart|status> <dns|gha-runner|vm-name>"
  echo ""
  echo "Actions: start, stop, restart, status"
  echo "Aliases: dns (DNS resolver VM), gha-runner (GitHub Actions runner VM)"
  exit 1
}

if [[ -z "$ACTION" || -z "$VM_ALIAS" ]]; then
  usage
fi

# Resolve alias to VM name
case "$VM_ALIAS" in
  dns|dns-server)
    VM_NAME="$DBG_DNS_VM_NAME"
    VM_LABEL="DNS Server"
    ;;
  gha-runner|gha|runner)
    VM_NAME="$DBG_GHA_RUNNER_VM_NAME"
    VM_LABEL="GitHub Actions Runner"
    ;;
  *)
    VM_NAME="$VM_ALIAS"
    VM_LABEL="$VM_ALIAS"
    ;;
esac

if [[ -z "$VM_NAME" ]]; then
  echo "❌ VM name not found. Run sync-config.sh to discover VMs, or specify the name directly."
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  VM Management: $VM_LABEL ($VM_NAME)"
echo "═══════════════════════════════════════════════════════"
echo ""

# Get current power state
get_power_state() {
  az vm get-instance-view \
    --resource-group "$DBG_HUB_RG" \
    --name "$VM_NAME" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
    -o tsv 2>/dev/null || echo "unknown"
}

case "$ACTION" in
  status)
    POWER_STATE=$(get_power_state)
    echo "  VM: $VM_NAME"
    echo "  RG: $DBG_HUB_RG"
    echo "  Power state: $POWER_STATE"
    echo ""
    if [[ "$POWER_STATE" == *"running"* ]]; then
      echo "  ✅ VM is running"
    elif [[ "$POWER_STATE" == *"deallocated"* ]]; then
      echo "  ⚠️  VM is deallocated (stopped and not incurring compute charges)"
    elif [[ "$POWER_STATE" == *"stopped"* ]]; then
      echo "  ⚠️  VM is stopped (still incurring charges — deallocate to stop billing)"
    else
      echo "  ⚠️  VM power state: $POWER_STATE"
    fi
    ;;

  start)
    POWER_STATE=$(get_power_state)
    if [[ "$POWER_STATE" == *"running"* ]]; then
      echo "  ✅ VM is already running — nothing to do"
      exit 0
    fi
    echo "  Starting $VM_LABEL..."
    az vm start \
      --resource-group "$DBG_HUB_RG" \
      --name "$VM_NAME" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --no-wait
    echo "  ✅ Start command issued (--no-wait). VM will be available in 1-2 minutes."
    echo ""
    echo "  To check status: $0 status $VM_ALIAS"
    ;;

  stop)
    POWER_STATE=$(get_power_state)
    if [[ "$POWER_STATE" == *"deallocated"* ]]; then
      echo "  ✅ VM is already deallocated — nothing to do"
      exit 0
    fi
    echo "  Stopping (deallocating) $VM_LABEL..."
    az vm deallocate \
      --resource-group "$DBG_HUB_RG" \
      --name "$VM_NAME" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --no-wait
    echo "  ✅ Deallocate command issued (--no-wait). Compute billing will stop once complete."
    echo ""
    echo "  To check status: $0 status $VM_ALIAS"
    ;;

  restart)
    POWER_STATE=$(get_power_state)
    if [[ "$POWER_STATE" == *"deallocated"* || "$POWER_STATE" == *"stopped"* ]]; then
      echo "  VM is stopped — starting instead of restarting..."
      az vm start \
        --resource-group "$DBG_HUB_RG" \
        --name "$VM_NAME" \
        --subscription "$DBG_SUBSCRIPTION_ID" \
        --no-wait
      echo "  ✅ Start command issued (--no-wait)."
    else
      echo "  Restarting $VM_LABEL..."
      az vm restart \
        --resource-group "$DBG_HUB_RG" \
        --name "$VM_NAME" \
        --subscription "$DBG_SUBSCRIPTION_ID" \
        --no-wait
      echo "  ✅ Restart command issued (--no-wait). VM will be available in 1-2 minutes."
    fi
    echo ""
    echo "  To check status: $0 status $VM_ALIAS"
    ;;

  *)
    echo "❌ Unknown action: $ACTION"
    usage
    ;;
esac

echo ""
