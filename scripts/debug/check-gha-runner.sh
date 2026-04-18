#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-gha-runner.sh — Check the GitHub Actions runner VM and service
#
# Verifies the runner VM is running, confirms it has outbound egress to
# GitHub, checks whether the runner has a public IP or NAT-backed egress,
# and inspects the guest runner service through Azure Run Command.
#
# Usage:
#   ./scripts/debug/check-gha-runner.sh
# -------------------------------------------------------------------
set -euo pipefail
ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help "check-gha-runner.sh" "Check GitHub Actions runner VM status, egress, and service health" \
  "./scripts/debug/check-gha-runner.sh"

print_header "GitHub Actions Runner Diagnostics"

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required. Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
  exit 1
fi

resolve_repo_url() {
  local repo_url=""
  local env_name=""
  local env_file=""

  if command -v azd >/dev/null 2>&1; then
    repo_url=$(azd env get-value AZURE_GITHUB_REPO_URL 2>/dev/null | head -n 1 || true)
    env_name=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || true)
  fi

  if [[ -z "$repo_url" && -n "$env_name" ]]; then
    env_file="$SCRIPT_DIR/../../.azure/$env_name/.env"
    if [[ -f "$env_file" ]]; then
      repo_url=$(sed -n 's/^AZURE_GITHUB_REPO_URL="\(.*\)"$/\1/p' "$env_file" | tail -n 1)
    fi
  fi

  printf '%s' "$repo_url"
}

print_step 1 "VM power state"
VM_STATUS=$(run_with_timeout 25 az vm get-instance-view \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_GHA_RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "UNKNOWN")

echo "    VM: $DBG_GHA_RUNNER_VM_NAME"
echo "    Power state: $VM_STATUS"

if [[ "$VM_STATUS" == "VM running" ]]; then
  result PASS "GitHub Actions runner VM is running"
elif [[ "$VM_STATUS" == "VM deallocated" || "$VM_STATUS" == "VM stopped" ]]; then
  result FAIL "GitHub Actions runner VM is stopped/deallocated"
  echo "         → The compute schedule Logic App may have stopped this VM."
  echo "         → To start: ./scripts/debug/manage-vm.sh start gha-runner"
else
  result WARN "VM power state is: $VM_STATUS"
fi

print_step 2 "VM provisioning state"
PROV_STATE=$(run_with_timeout 25 az vm show \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_GHA_RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "provisioningState" \
  -o tsv 2>/dev/null || echo "UNKNOWN")

echo "    Provisioning state: $PROV_STATE"
if [[ "$PROV_STATE" == "Succeeded" ]]; then
  result PASS "VM provisioning state is Succeeded"
elif [[ "$PROV_STATE" == "Updating" ]]; then
  result WARN "VM provisioning state is Updating"
  echo "         → This is often transient during extension updates."
else
  result FAIL "VM provisioning state is $PROV_STATE"
fi

print_step 3 "NIC and egress configuration"
NIC_ID=$(run_with_timeout 25 az vm show \
  --resource-group "$DBG_HUB_RG" \
  --name "$DBG_GHA_RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "networkProfile.networkInterfaces[0].id" \
  -o tsv 2>/dev/null || true)

NIC_NAME=""
SUBNET_ID=""
if [[ -z "$NIC_ID" ]]; then
  result FAIL "Could not determine runner VM NIC"
else
  NIC_NAME="${NIC_ID##*/}"
  NIC_INFO=$(run_with_timeout 25 az network nic show \
    --ids "$NIC_ID" \
    --query "ipConfigurations[0].{privateIp:privateIPAddress,publicIpId:publicIPAddress.id,subnetId:subnet.id}" \
    -o json 2>/dev/null || echo "{}")

  PRIVATE_IP=$(echo "$NIC_INFO" | jq -r '.privateIp // "unknown"')
  PUBLIC_IP_ID=$(echo "$NIC_INFO" | jq -r '.publicIpId // ""')
  SUBNET_ID=$(echo "$NIC_INFO" | jq -r '.subnetId // ""')

  echo "    NIC: $NIC_NAME"
  echo "    Private IP: $PRIVATE_IP"

  if [[ -n "$PUBLIC_IP_ID" ]]; then
    PUBLIC_IP=$(run_with_timeout 25 az network public-ip show \
      --ids "$PUBLIC_IP_ID" \
      --query "ipAddress" \
      -o tsv 2>/dev/null || echo "unknown")
    echo "    Public IP:  $PUBLIC_IP"
    result PASS "Runner NIC has a public IP attached"
  else
    echo "    Public IP:  none"
    result WARN "Runner NIC does not have a public IP attached"
  fi

  if [[ -n "$SUBNET_ID" ]]; then
    SUBNET_INFO=$(run_with_timeout 25 az network vnet subnet show \
      --ids "$SUBNET_ID" \
      --query "{defaultOutboundAccess:defaultOutboundAccess,natGateway:natGateway.id,routeTable:routeTable.id}" \
      -o json 2>/dev/null || echo "{}")
    DEFAULT_OUTBOUND=$(echo "$SUBNET_INFO" | jq -r '.defaultOutboundAccess // "unknown"')
    NAT_GATEWAY_ID=$(echo "$SUBNET_INFO" | jq -r '.natGateway // ""')
    ROUTE_TABLE_ID=$(echo "$SUBNET_INFO" | jq -r '.routeTable // ""')

    echo "    Subnet defaultOutboundAccess: $DEFAULT_OUTBOUND"
    echo "    NAT gateway: ${NAT_GATEWAY_ID:-none}"
    echo "    Route table: ${ROUTE_TABLE_ID:-none}"

    if [[ -n "$PUBLIC_IP_ID" || -n "$NAT_GATEWAY_ID" ]]; then
      result PASS "Runner subnet has an explicit outbound path"
    elif [[ "$DEFAULT_OUTBOUND" == "true" ]]; then
      result WARN "Runner subnet relies on default outbound access"
    else
      result FAIL "Runner subnet has no public IP, no NAT gateway, and default outbound access is disabled"
      echo "         → The runner will not be able to reach GitHub until egress is restored."
    fi
  else
    result WARN "Could not determine runner subnet details"
  fi
fi

print_step 4 "Runner repository target"
REPO_URL=$(resolve_repo_url)
if [[ -n "$REPO_URL" ]]; then
  echo "    AZD repo URL: $REPO_URL"
  result PASS "Found configured GitHub repository URL"
else
  result WARN "Could not resolve AZURE_GITHUB_REPO_URL from azd"
  echo "         → Retargeting and repo-side comparisons may need manual input."
fi

if command -v azd >/dev/null 2>&1; then
  if azd env get-value AZURE_GITHUB_PAT >/dev/null 2>&1; then
    result PASS "A GitHub PAT is available in the azd environment"
  elif azd env get-value AZURE_GITHUB_RUNNER_TOKEN >/dev/null 2>&1; then
    result WARN "Only a GitHub runner registration token is available in azd"
    echo "         → Registration tokens expire quickly and cannot be used for full repo diagnostics."
  else
    result WARN "No GitHub credential found in azd environment"
  fi
else
  result WARN "azd is not installed; skipping environment checks"
fi

print_step 5 "Connectivity to GitHub"
if [[ "$VM_STATUS" == "VM running" ]]; then
  GITHUB_RESULT=$(run_with_timeout 60 az network watcher test-connectivity \
    --source-resource "$DBG_GHA_RUNNER_VM_ID" \
    --dest-address github.com \
    --dest-port 443 \
    --query "connectionStatus" \
    -o tsv 2>/dev/null || echo "Unknown")
  API_RESULT=$(run_with_timeout 60 az network watcher test-connectivity \
    --source-resource "$DBG_GHA_RUNNER_VM_ID" \
    --dest-address api.github.com \
    --dest-port 443 \
    --query "connectionStatus" \
    -o tsv 2>/dev/null || echo "Unknown")

  echo "    github.com:     $GITHUB_RESULT"
  echo "    api.github.com: $API_RESULT"

  if [[ "$GITHUB_RESULT" == "Reachable" && "$API_RESULT" == "Reachable" ]]; then
    result PASS "Azure can reach GitHub and the GitHub API from the runner VM"
  elif [[ "$GITHUB_RESULT" == "Unreachable" || "$API_RESULT" == "Unreachable" ]]; then
    result FAIL "Runner VM cannot reach GitHub over port 443"
    echo "         → Check public IP attachment, NAT egress, and any recent NIC or subnet changes."
  else
    result WARN "Connectivity test returned: github.com=$GITHUB_RESULT api.github.com=$API_RESULT"
  fi
else
  result WARN "Skipped — runner VM is not running"
fi

print_step 6 "Runner service and registration"
if [[ "$VM_STATUS" == "VM running" ]]; then
  RUN_COMMAND_OUTPUT=$(run_with_timeout 75 az vm run-command invoke \
    --resource-group "$DBG_HUB_RG" \
    --name "$DBG_GHA_RUNNER_VM_NAME" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --command-id RunShellScript \
    --scripts '
svc=$(systemctl list-unit-files --no-legend | awk "/actions\\.runner/ {print \\$1; exit}")
echo "SERVICE=${svc:-none}"
if [[ -n "$svc" ]]; then
  echo "ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  echo "ACTIVE=$(systemctl is-active "$svc" 2>/dev/null || true)"
fi
ps -ef | grep -i "Runner.Listener\\|runsvc" | grep -v grep || true
if [[ -f /root/actions-runner/.runner ]]; then
  echo "RUNNER_FILE_PRESENT=yes"
  jq -r "\"RUNNER_REPO=\(.gitHubUrl // \"\")\"" /root/actions-runner/.runner 2>/dev/null || true
  jq -r "\"RUNNER_NAME=\(.agentName // \"\")\"" /root/actions-runner/.runner 2>/dev/null || true
else
  echo "RUNNER_FILE_PRESENT=no"
fi
' \
    --query "value[0].message" \
    -o tsv 2>/dev/null || true)

  if [[ -z "$RUN_COMMAND_OUTPUT" ]]; then
    result WARN "Could not inspect runner guest state through Azure Run Command"
    echo "         → The Run Command channel may be busy or the guest agent may be unhealthy."
  else
    echo "$RUN_COMMAND_OUTPUT" | sed 's/^/    /'

    SERVICE_NAME=$(echo "$RUN_COMMAND_OUTPUT" | sed -n 's/^SERVICE=//p' | head -n 1)
    SERVICE_ACTIVE=$(echo "$RUN_COMMAND_OUTPUT" | sed -n 's/^ACTIVE=//p' | head -n 1)
    RUNNER_FILE_PRESENT=$(echo "$RUN_COMMAND_OUTPUT" | sed -n 's/^RUNNER_FILE_PRESENT=//p' | head -n 1)
    RUNNER_REPO=$(echo "$RUN_COMMAND_OUTPUT" | sed -n 's/^RUNNER_REPO=//p' | head -n 1)

    if [[ -n "$SERVICE_NAME" && "$SERVICE_NAME" != "none" ]]; then
      result PASS "Runner systemd service is present ($SERVICE_NAME)"
    else
      result FAIL "Runner systemd service is not installed"
    fi

    if [[ "$SERVICE_ACTIVE" == "active" ]]; then
      result PASS "Runner service is active"
    elif [[ -n "$SERVICE_ACTIVE" ]]; then
      result FAIL "Runner service state is $SERVICE_ACTIVE"
    fi

    if [[ "$RUNNER_FILE_PRESENT" == "yes" ]]; then
      result PASS "Runner registration file exists"
    else
      result FAIL "Runner registration file is missing"
    fi

    if [[ -n "$RUNNER_REPO" ]]; then
      echo "    Registered repo: $RUNNER_REPO"
      if [[ -n "$REPO_URL" && "$RUNNER_REPO" == "$REPO_URL" ]]; then
        result PASS "Runner is registered to the configured repository"
      elif [[ -n "$REPO_URL" ]]; then
        result FAIL "Runner is registered to a different repository than AZD configuration"
      else
        result WARN "Runner repo found but azd repo URL is unavailable for comparison"
      fi
    fi
  fi
else
  result WARN "Skipped — runner VM is not running"
fi

print_summary \
  "1. Start the runner VM if needed: ./scripts/debug/manage-vm.sh start gha-runner" \
  "2. If GitHub is unreachable, reattach the runner public IP or provide NAT egress on the VM subnet" \
  "3. If the service is inactive or the repo target is wrong, run: ./scripts/debug/retarget-gha-runner.sh --repo-url <https://github.com/owner/repo>"
