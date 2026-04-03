#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-dns-server.sh — Check the DNS resolver VM status and CoreDNS
#
# Verifies the DNS resolver VM is running, checks CoreDNS container
# health, and offers to restart if needed.
#
# Usage:
#   ./scripts/debug/check-dns-server.sh
#   ./scripts/debug/check-dns-server.sh --restart   # restart the VM
# -------------------------------------------------------------------
set -euo pipefail
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help "check-dns-server.sh" "Check DNS resolver VM status and CoreDNS health" \
  "./scripts/debug/check-dns-server.sh" \
  "./scripts/debug/check-dns-server.sh --restart"

ACTION="${1:-}"

print_header "DNS Resolver VM Diagnostics"

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required. Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
  exit 1
fi

# 1. Check VM power state
print_step 1 "VM power state"
VM_STATUS=$(az vm get-instance-view \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_DNS_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "UNKNOWN")

echo "    VM: $DBG_DNS_VM_NAME"
echo "    Power state: $VM_STATUS"

if [[ "$VM_STATUS" == "VM running" ]]; then
  result PASS "DNS resolver VM is running"
elif [[ "$VM_STATUS" == "VM deallocated" || "$VM_STATUS" == "VM stopped" ]]; then
  result FAIL "DNS resolver VM is stopped/deallocated"
  echo "         → The compute schedule Logic App may have stopped this VM."
  echo "         → To start: az vm start --resource-group $DBG_HUB_RG --name $DBG_DNS_VM_NAME --subscription $DBG_SUBSCRIPTION_ID"

  if [[ "$ACTION" == "--restart" ]]; then
    echo ""
    echo "  Starting VM..."
    az vm start --resource-group "$DBG_HUB_RG" --name "$DBG_DNS_VM_NAME" --subscription "$DBG_SUBSCRIPTION_ID"
    echo "  ✅ VM start command issued. Waiting 30s for boot..."
    sleep 30
  fi
else
  result WARN "VM power state is: $VM_STATUS"
fi

# 2. Check VM provisioning state
print_step 2 "VM provisioning state"
PROV_STATE=$(az vm show \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_DNS_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "provisioningState" \
  -o tsv 2>/dev/null || echo "UNKNOWN")

echo "    Provisioning state: $PROV_STATE"
if [[ "$PROV_STATE" == "Succeeded" ]]; then
  result PASS "VM provisioning state is Succeeded"
else
  result FAIL "VM provisioning state is $PROV_STATE"
fi

# 3. Check NIC and private IP
print_step 3 "Network interface and IP"
NIC_INFO=$(az vm show \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_DNS_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --show-details \
  --query "{privateIps:privateIps, publicIps:publicIps}" \
  -o json 2>/dev/null || echo "{}")

ACTUAL_IP=$(echo "$NIC_INFO" | jq -r '.privateIps // "unknown"')
echo "    Expected IP: $DBG_DNS_IP"
echo "    Actual IP:   $ACTUAL_IP"

if [[ "$ACTUAL_IP" == "$DBG_DNS_IP" ]]; then
  result PASS "Private IP matches expected ($DBG_DNS_IP)"
elif [[ "$ACTUAL_IP" == "unknown" ]]; then
  result WARN "Could not determine private IP"
else
  result FAIL "Private IP mismatch: expected $DBG_DNS_IP, got $ACTUAL_IP"
  echo "         → Update .azure-debug-config.json with the correct IP."
fi

# 4. Test DNS port reachability
print_step 4 "DNS service reachability"
if nc -z -w 5 "$DBG_DNS_IP" 53 2>/dev/null; then
  result PASS "Port 53 is open on $DBG_DNS_IP (CoreDNS is likely running)"
else
  if [[ "$VM_STATUS" == "VM running" ]]; then
    result FAIL "Port 53 is NOT reachable on $DBG_DNS_IP even though VM is running"
    echo "         → CoreDNS Docker container may have crashed."
    echo "         → SSH into the VM and check: sudo systemctl status coredns"
    echo "         → Or restart: sudo systemctl restart coredns"
  else
    result WARN "Port 53 check skipped — VM is not running"
  fi
fi

# 5. Test DNS resolution through the server
print_step 5 "DNS resolution test via the resolver"
if nc -z -w 3 "$DBG_DNS_IP" 53 2>/dev/null; then
  if RESULT=$(nslookup "management.azure.com" "$DBG_DNS_IP" 2>&1) && echo "$RESULT" | grep -q 'Address:'; then
    result PASS "DNS resolution through $DBG_DNS_IP works (resolved management.azure.com)"
  else
    result FAIL "DNS server is reachable but cannot resolve queries"
    echo "         → CoreDNS may be misconfigured or upstream Azure DNS is unreachable."
  fi
else
  result WARN "Skipped — DNS server not reachable"
fi

# Summary
print_summary \
  "1. Start VM if stopped:   az vm start -g $DBG_HUB_RG -n $DBG_DNS_VM_NAME --subscription $DBG_SUBSCRIPTION_ID" \
  "2. Or use:                ./scripts/debug/check-dns-server.sh --restart" \
  "3. If VM is running but port 53 is closed, SSH in and run: sudo systemctl restart coredns"
