#!/usr/bin/env bash
# -------------------------------------------------------------------
# update-gha-runner.sh — Fully automated GitHub Actions runner update
#
# Updates the GitHub Actions self-hosted runner to point to a new repo.
# Automates: config discovery, PAT generation (if needed), re-registration,
# and verification. No manual steps required.
#
# Usage:
#   ./scripts/debug/update-gha-runner.sh https://github.com/owner/repo
#   ./scripts/debug/update-gha-runner.sh --repo https://github.com/owner/repo [--pat YOUR_PAT]
#
# Environment variables:
#   GITHUB_PAT         — Use this PAT instead of generating one
#   SKIP_PAT_CREATION  — Set to 1 to skip PAT generation (requires GITHUB_PAT)
#
# -------------------------------------------------------------------
set -euo pipefail

ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help \
  "update-gha-runner.sh" \
  "Fully automated GitHub Actions runner repository update" \
  "./scripts/debug/update-gha-runner.sh https://github.com/owner/repo" \
  "GITHUB_PAT=ghp_xxx ./scripts/debug/update-gha-runner.sh --repo https://github.com/owner/repo"

resolve_pat_from_azd() {
  local azd_values env_name env_file resolved_pat

  resolved_pat="${AZURE_GITHUB_PAT:-${AZURE_GITHUB_RUNNER_TOKEN:-}}"
  if [[ -n "$resolved_pat" ]]; then
    printf '%s' "$resolved_pat"
    return 0
  fi

  if command -v azd >/dev/null 2>&1; then
    azd_values=$(azd env get-values 2>/dev/null || true)
    if [[ -n "$azd_values" ]]; then
      resolved_pat=$(printf '%s\n' "$azd_values" | sed -n 's/^AZURE_GITHUB_PAT="\(.*\)"$/\1/p' | tail -n 1)
      if [[ -z "$resolved_pat" ]]; then
        resolved_pat=$(printf '%s\n' "$azd_values" | sed -n 's/^AZURE_GITHUB_RUNNER_TOKEN="\(.*\)"$/\1/p' | tail -n 1)
      fi
      if [[ -n "$resolved_pat" ]]; then
        printf '%s' "$resolved_pat"
        return 0
      fi
    fi
  fi

  env_name=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || true)
  if [[ -z "$env_name" ]]; then
    env_name="${AZURE_ENV_NAME:-}"
  fi

  if [[ -n "$env_name" ]]; then
    env_file="$SCRIPT_DIR/../../.azure/$env_name/.env"
    if [[ -f "$env_file" ]]; then
      resolved_pat=$(sed -n 's/^AZURE_GITHUB_PAT="\(.*\)"$/\1/p' "$env_file" | tail -n 1)
      if [[ -z "$resolved_pat" ]]; then
        resolved_pat=$(sed -n 's/^AZURE_GITHUB_RUNNER_TOKEN="\(.*\)"$/\1/p' "$env_file" | tail -n 1)
      fi
      if [[ -n "$resolved_pat" ]]; then
        printf '%s' "$resolved_pat"
        return 0
      fi
    fi
  fi

  return 1
}

TARGET_REPO_URL=""
PAT_INPUT="${GITHUB_PAT:-}"
SKIP_PAT_CREATION="${SKIP_PAT_CREATION:-0}"
UPDATE_AZD_ENV=1
RUNNER_VM_NAME="${DBG_GHA_RUNNER_VM_NAME:-}"

# Parse arguments (support both positional and --flag styles)
if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
  TARGET_REPO_URL="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      TARGET_REPO_URL="${2:-}"
      shift 2
      ;;
    --repo-url)
      TARGET_REPO_URL="${2:-}"
      shift 2
      ;;
    --pat)
      PAT_INPUT="${2:-}"
      shift 2
      ;;
    --vm-name)
      RUNNER_VM_NAME="${2:-}"
      shift 2
      ;;
    --no-azd-update)
      UPDATE_AZD_ENV=0
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_REPO_URL" ]]; then
  echo "ERROR: Repository URL is required"
  echo "Usage: $0 https://github.com/owner/repo [--pat TOKEN] [--vm-name NAME] [--no-azd-update]"
  exit 1
fi

if [[ ! "$TARGET_REPO_URL" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
  echo "ERROR: Invalid repository URL format"
  echo "Expected: https://github.com/owner/repo"
  exit 1
fi

TARGET_REPO_URL="${TARGET_REPO_URL%/}"
TARGET_REPO_PATH="${TARGET_REPO_URL#https://github.com/}"

print_header "GitHub Actions Runner Update"
print_step 1 "Discovering runner VM configuration"

RUNNER_VM_NAME="${DBG_GHA_RUNNER_VM_NAME:-}"
RUNNER_PATH="/home/azureuser/actions-runner"

if [[ -z "$RUNNER_VM_NAME" || "$RUNNER_VM_NAME" == "null" ]]; then
  if [[ -n "${DBG_GHA_RUNNER_VM_ID:-}" && "$DBG_GHA_RUNNER_VM_ID" != "null" ]]; then
    RUNNER_VM_NAME="${DBG_GHA_RUNNER_VM_ID##*/}"
  fi
fi

if [[ -z "$RUNNER_VM_NAME" || "$RUNNER_VM_NAME" == "null" ]]; then
  VM_CANDIDATES=$(run_with_timeout 30 az vm list \
    --resource-group "$DBG_HUB_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[?name != '$DBG_DNS_VM_NAME'].name" \
    -o tsv 2>/dev/null || true)

  if [[ -n "$VM_CANDIDATES" ]]; then
    MATCHED_CANDIDATE=$(echo "$VM_CANDIDATES" | grep -Ei 'gha|runner' | head -n 1 || true)
    if [[ -n "$MATCHED_CANDIDATE" ]]; then
      RUNNER_VM_NAME="$MATCHED_CANDIDATE"
    else
      CANDIDATE_COUNT=$(echo "$VM_CANDIDATES" | sed '/^$/d' | wc -l)
      if [[ "$CANDIDATE_COUNT" -eq 1 ]]; then
        RUNNER_VM_NAME="$(echo "$VM_CANDIDATES" | head -n 1)"
      fi
    fi
  fi
fi

if [[ -z "$RUNNER_VM_NAME" || "$RUNNER_VM_NAME" == "null" ]]; then
  result FAIL "Could not discover runner VM. Please run: ./scripts/ipam/sync-config.sh --yes" || true
  print_summary
  exit 1
fi

result PASS "Discovered runner VM: $RUNNER_VM_NAME" || true

# Verify runner path exists on VM
RUNNER_PATH_CHECK=$(az vm run-command invoke \
  --resource-group "$DBG_HUB_RG" \
  --name "$RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --command-id RunShellScript \
  --scripts "test -d $RUNNER_PATH && echo 'OK' || echo 'NOT_FOUND'" \
  --query "value[0].message" \
  -o tsv 2>/dev/null | grep -oE '(OK|NOT_FOUND)' | tail -1 || echo "")

if [[ "$RUNNER_PATH_CHECK" != "OK" ]]; then
  result FAIL "Runner directory not found at $RUNNER_PATH on $RUNNER_VM_NAME" || true
  print_summary
  exit 1
fi

result PASS "Confirmed runner directory: $RUNNER_PATH" || true

print_step 2 "Preparing GitHub authentication"

# Try to resolve PAT from environment, azd, or gh CLI
if [[ -z "$PAT_INPUT" ]] && [[ "$SKIP_PAT_CREATION" != "1" ]]; then
  # First try direct environment variables
  if [[ -n "${GITHUB_PAT:-}" ]]; then
    PAT_INPUT="$GITHUB_PAT"
    result PASS "Using GITHUB_PAT environment variable" || true
  else
    # Try azd environment resolution
    if PAT_INPUT="$(resolve_pat_from_azd)" && [[ -n "$PAT_INPUT" ]]; then
      result PASS "Using GitHub credential from azd environment" || true
    elif command -v gh >/dev/null 2>&1; then
      # Fall back to gh CLI if available
      result PASS "Using gh CLI to manage GitHub authentication" || true
      
      # Verify gh is authenticated
      if ! run_with_timeout 10 gh auth status >/dev/null 2>&1; then
        result FAIL "gh CLI is not authenticated. Run: gh auth login" || true
        print_summary
        exit 1
      fi
      
      # Get or create a PAT
      result PASS "Obtaining GitHub authentication token..." || true
      PAT_INPUT=$(run_with_timeout 30 gh auth token 2>/dev/null || true)
      
      if [[ -z "$PAT_INPUT" ]]; then
        result FAIL "Failed to obtain GitHub authentication token" || true
        print_summary
        exit 1
      fi
      
      result PASS "GitHub authentication ready" || true
    fi
  fi
fi

if [[ -z "$PAT_INPUT" ]]; then
  read -rsp "Enter GitHub PAT (with repo admin permission): " PAT_INPUT
  echo ""
  if [[ -z "$PAT_INPUT" ]]; then
    result FAIL "GitHub PAT is required" || true
    print_summary
    exit 1
  fi
fi

result PASS "GitHub authentication configured" || true

print_step 3 "Ensuring runner VM is running"

POWER_STATE=$(run_with_timeout 25 az vm get-instance-view \
  --resource-group "$DBG_HUB_RG" \
  --name "$RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || true)

if [[ "$POWER_STATE" != *"running"* ]]; then
  result WARN "Runner VM is not running ($POWER_STATE). Starting..." || true
  run_with_timeout 35 az vm start \
    --resource-group "$DBG_HUB_RG" \
    --name "$RUNNER_VM_NAME" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --no-wait >/dev/null 2>&1
  
  run_with_timeout 90 az vm wait \
    --resource-group "$DBG_HUB_RG" \
    --name "$RUNNER_VM_NAME" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --created >/dev/null 2>&1
  
  result PASS "Runner VM is now running" || true
else
  result PASS "Runner VM is already running" || true
fi

print_step 4 "Re-registering runner to ${TARGET_REPO_PATH}"

# Base64 encode credentials for safe transport over az vm run-command
TARGET_REPO_B64=$(printf '%s' "$TARGET_REPO_URL" | base64 -w0)
PAT_B64=$(printf '%s' "$PAT_INPUT" | base64 -w0)

REMOTE_SCRIPT=$(cat <<'EOF'
set -eu

TARGET_REPO_URL=$(printf '%s' '__TARGET_REPO_B64__' | base64 -d)
GITHUB_PAT=$(printf '%s' '__PAT_B64__' | base64 -d)
TARGET_REPO_PATH="${TARGET_REPO_URL#https://github.com/}"
RUNNER_DIR="__RUNNER_PATH__"

if [ ! -d "$RUNNER_DIR" ]; then
  echo "ERROR: Runner directory not found at $RUNNER_DIR"
  exit 1
fi

cd "$RUNNER_DIR"
export RUNNER_ALLOW_RUNASROOT=1

CURRENT_REPO_PATH=""
if [ -f .runner ]; then
  CURRENT_REPO_URL=$(jq -r '.gitHubUrl // ""' .runner 2>/dev/null || true)
  if [ -n "$CURRENT_REPO_URL" ]; then
    CURRENT_REPO_PATH="${CURRENT_REPO_URL#https://github.com/}"
  fi
fi

echo "INFO: Current runner repo: ${CURRENT_REPO_PATH:-unknown}"
echo "INFO: Target runner repo:  $TARGET_REPO_PATH"

# Stop and remove old registration
if [ -f .service ]; then
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi

# Unregister from old repo if different
if [ -n "$CURRENT_REPO_PATH" ] && [ "$CURRENT_REPO_PATH" != "$TARGET_REPO_PATH" ]; then
  REMOVE_TOKEN=$(curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${CURRENT_REPO_PATH}/actions/runners/remove-token" \
    2>/dev/null | jq -r '.token' 2>/dev/null || true)

  if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
    ./config.sh remove --token "$REMOVE_TOKEN" 2>/dev/null || true
  fi
fi

# Get registration token for new repo
echo "INFO: Requesting registration token for ${TARGET_REPO_PATH}..."
REG_TOKEN=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_PAT}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${TARGET_REPO_PATH}/actions/runners/registration-token" \
  2>/dev/null | jq -r '.token' 2>/dev/null || true)

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  echo "ERROR: Failed to get registration token for ${TARGET_REPO_PATH}"
  echo "  Check: Is the PAT valid? Does it have repo admin permissions?"
  exit 1
fi

# Configure and start runner with new repo
echo "INFO: Configuring runner for ${TARGET_REPO_PATH}..."
./config.sh --unattended \
  --url "$TARGET_REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$(hostname)" \
  --labels "self-hosted,Linux,X64" \
  --work _work \
  --replace

# Install and start systemd service
./svc.sh install root
SERVICE_FILE=$(cat .service)

# Ensure RUNNER_ALLOW_RUNASROOT is set
if ! grep -q "RUNNER_ALLOW_RUNASROOT=1" "/etc/systemd/system/${SERVICE_FILE}"; then
  sed -i '/\[Service\]/a Environment=RUNNER_ALLOW_RUNASROOT=1' "/etc/systemd/system/${SERVICE_FILE}"
fi

systemctl daemon-reload
./svc.sh start

# Verify service is running
if systemctl is-active "$SERVICE_FILE" >/dev/null 2>&1; then
  echo "SUCCESS: Runner service started successfully"
  echo "Service: $SERVICE_FILE"
else
  echo "WARNING: Runner service did not start immediately, checking status..."
  sleep 2
  systemctl is-active "$SERVICE_FILE" || true
fi

echo "INFO: Runner retargeted to: $TARGET_REPO_URL"
EOF
)

REMOTE_SCRIPT="${REMOTE_SCRIPT/__TARGET_REPO_B64__/$TARGET_REPO_B64}"
REMOTE_SCRIPT="${REMOTE_SCRIPT/__PAT_B64__/$PAT_B64}"
REMOTE_SCRIPT="${REMOTE_SCRIPT/__RUNNER_PATH__/$RUNNER_PATH}"

RUN_OUTPUT=$(run_with_timeout 120 az vm run-command invoke \
  --resource-group "$DBG_HUB_RG" \
  --name "$RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --query "value[0].message" \
  -o tsv 2>/dev/null || echo "")

if echo "$RUN_OUTPUT" | grep -qi "error:"; then
  result FAIL "Error during runner reconfiguration" || true
  echo ""
  echo "$RUN_OUTPUT"
  print_summary
  exit 1
fi

result PASS "Runner successfully reconfigured on VM" || true

print_step 5 "Verifying runner is online in GitHub"

# Give GitHub a moment to register the runner
sleep 3

ONLINE_STATUS=$(curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${PAT_INPUT}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${TARGET_REPO_PATH}/actions/runners?per_page=100" \
  2>/dev/null | jq -r --arg name "$RUNNER_VM_NAME" \
      '.runners[]? | select(.name == $name) | .status' \
  | head -n 1 || echo "")

if [[ "$ONLINE_STATUS" == "online" ]]; then
  result PASS "✓ Runner is ONLINE in ${TARGET_REPO_PATH}" || true
else
  # Check if runner exists but not yet online
  RUNNER_FOUND=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${PAT_INPUT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${TARGET_REPO_PATH}/actions/runners?per_page=100" \
    2>/dev/null | jq -r --arg name "$RUNNER_VM_NAME" \
        '.runners[]? | select(.name == $name) | .id' \
    | head -n 1 || echo "")

  if [[ -n "$RUNNER_FOUND" ]]; then
    result WARN "Runner found but status is '${ONLINE_STATUS:-unknown}' (may come online shortly)" || true
  else
    result FAIL "Runner not found in GitHub after reconfiguration" || true
    echo ""
    echo "Troubleshooting:"
    echo "  1. Verify GitHub PAT has repo admin permission"
    echo "  2. Check runner service on VM: systemctl status actions.runner.*"
    echo "  3. View runner logs: journalctl -u actions.runner.* -n 50"
    print_summary
    exit 1
  fi
fi

print_step 6 "Updating azd environment variables"

if command -v azd >/dev/null 2>&1; then
  if azd env set AZURE_GITHUB_REPO_URL "$TARGET_REPO_URL" >/dev/null 2>&1; then
    result PASS "Updated azd env var AZURE_GITHUB_REPO_URL" || true
  else
    result WARN "Could not update azd environment. Update manually: azd env set AZURE_GITHUB_REPO_URL '$TARGET_REPO_URL'" || true
  fi
fi

echo ""
print_summary

echo ""
echo "✅ GitHub Actions runner successfully updated to:"
echo "   Repository: $TARGET_REPO_URL"
echo "   Runner VM:  $RUNNER_VM_NAME"
echo "   Status:     $ONLINE_STATUS"
echo ""
echo "The runner is ready for workflows! Use 'runs-on: self-hosted' in your GitHub Actions YAML."
