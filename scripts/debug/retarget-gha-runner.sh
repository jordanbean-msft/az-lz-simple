#!/usr/bin/env bash
# -------------------------------------------------------------------
# retarget-gha-runner.sh — Re-register the GitHub Actions runner VM
#
# Re-points the existing self-hosted runner on the hub VM to a new
# GitHub repository using Azure VM Run Command (no manual SSH needed).
#
# Usage:
#   ./scripts/debug/retarget-gha-runner.sh --repo-url https://github.com/owner/repo
#   GITHUB_PAT=... ./scripts/debug/retarget-gha-runner.sh --repo-url https://github.com/owner/repo
#
# Notes:
#   - Requires Azure CLI login and access to the runner VM.
#   - PAT must have permission to manage self-hosted runners on repos.
#   - Updates AZD env var AZURE_GITHUB_REPO_URL by default.
# -------------------------------------------------------------------
set -euo pipefail

ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

check_help \
  "retarget-gha-runner.sh" \
  "Re-register the GitHub Actions self-hosted runner VM to a different repository" \
  "./scripts/debug/retarget-gha-runner.sh --repo-url https://github.com/<owner>/<repo> [--vm-name <name>] [--no-azd-update] [--pat <token>]" \
  "GITHUB_PAT=<token> ./scripts/debug/retarget-gha-runner.sh --repo-url https://github.com/<owner>/<repo>"

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
UPDATE_AZD_ENV=1
RUNNER_VM_NAME="${DBG_GHA_RUNNER_VM_NAME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
  echo "ERROR: --repo-url is required"
  exit 1
fi

if [[ ! "$TARGET_REPO_URL" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
  echo "ERROR: --repo-url must be in the format https://github.com/<owner>/<repo>"
  exit 1
fi

TARGET_REPO_URL="${TARGET_REPO_URL%/}"
TARGET_REPO_PATH="${TARGET_REPO_URL#https://github.com/}"

if [[ -z "${RUNNER_VM_NAME:-}" || "$RUNNER_VM_NAME" == "null" ]]; then
  # First fallback: parse VM name from configured resource ID
  if [[ -n "${DBG_GHA_RUNNER_VM_ID:-}" && "$DBG_GHA_RUNNER_VM_ID" != "null" ]]; then
    RUNNER_VM_NAME="${DBG_GHA_RUNNER_VM_ID##*/}"
  fi
fi

if [[ -z "${RUNNER_VM_NAME:-}" || "$RUNNER_VM_NAME" == "null" ]]; then
  # Second fallback: discover candidates in hub RG
  VM_CANDIDATES=$(run_with_timeout 30 az vm list \
    --resource-group "$DBG_HUB_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[?name != '$DBG_DNS_VM_NAME'].name" \
    -o tsv 2>/dev/null || true)

  if [[ -n "$VM_CANDIDATES" ]]; then
    MATCHED_CANDIDATE=$(echo "$VM_CANDIDATES" | grep -Ei 'gha|runner' | head -n 1 || true)
    if [[ -n "$MATCHED_CANDIDATE" ]]; then
      RUNNER_VM_NAME="$MATCHED_CANDIDATE"
      echo "INFO: Auto-discovered runner VM by name pattern: $RUNNER_VM_NAME"
    else
      CANDIDATE_COUNT=$(echo "$VM_CANDIDATES" | sed '/^$/d' | wc -l)
      if [[ "$CANDIDATE_COUNT" -eq 1 ]]; then
        RUNNER_VM_NAME="$(echo "$VM_CANDIDATES" | head -n 1)"
        echo "INFO: Auto-selected only non-DNS VM in hub RG: $RUNNER_VM_NAME"
      fi
    fi
  fi
fi

if [[ -z "${RUNNER_VM_NAME:-}" || "$RUNNER_VM_NAME" == "null" ]]; then
  echo "ERROR: Could not determine GHA runner VM name."
  echo "Try one of:"
  echo "  1) Run ./scripts/ipam/sync-config.sh --yes"
  echo "  2) Rerun with --vm-name <runner-vm-name>"
  exit 1
fi

if [[ -z "$PAT_INPUT" ]]; then
  PAT_INPUT="$(resolve_pat_from_azd || true)"
  if [[ -n "$PAT_INPUT" ]]; then
    echo "INFO: Using GitHub credential from azd environment configuration"
  fi
fi

if [[ -z "$PAT_INPUT" ]]; then
  read -rsp "Enter GitHub PAT (repo administration write): " PAT_INPUT
  echo ""
fi

if [[ -z "$PAT_INPUT" ]]; then
  echo "ERROR: GitHub PAT is required"
  exit 1
fi

print_header "Retarget GitHub Actions Runner"
print_step 1 "Validating Azure access and VM state"

if ! run_with_timeout 15 az account show --query id -o tsv >/dev/null 2>&1; then
  result FAIL "Azure CLI is not logged in. Run: az login" || true
  print_summary
fi

POWER_STATE=$(run_with_timeout 25 az vm get-instance-view \
  --resource-group "$DBG_HUB_RG" \
  --name "$RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || true)

if [[ "$POWER_STATE" != *"running"* ]]; then
  result WARN "Runner VM is not running ($POWER_STATE). Starting VM..." || true
  run_with_timeout 35 az vm start \
    --resource-group "$DBG_HUB_RG" \
    --name "$RUNNER_VM_NAME" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --no-wait >/dev/null

  run_with_timeout 90 az vm wait \
    --resource-group "$DBG_HUB_RG" \
    --name "$RUNNER_VM_NAME" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --created >/dev/null

  result PASS "Runner VM is running" || true
else
  result PASS "Runner VM is already running" || true
fi

print_step 2 "Re-registering runner on VM to ${TARGET_REPO_PATH}"

TARGET_REPO_B64=$(printf '%s' "$TARGET_REPO_URL" | base64 -w0)
PAT_B64=$(printf '%s' "$PAT_INPUT" | base64 -w0)

REMOTE_SCRIPT=$(cat <<'EOF'
set -eu

TARGET_REPO_URL=$(printf '%s' '__TARGET_REPO_B64__' | base64 -d)
GITHUB_PAT=$(printf '%s' '__PAT_B64__' | base64 -d)
TARGET_REPO_PATH="${TARGET_REPO_URL#https://github.com/}"
RUNNER_DIR="/root/actions-runner"

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

echo "Current runner repo: ${CURRENT_REPO_PATH:-unknown}"
echo "Target runner repo:  $TARGET_REPO_PATH"

if [ -f .service ]; then
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi

if [ -n "$CURRENT_REPO_PATH" ]; then
  REMOVE_TOKEN=$(curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${CURRENT_REPO_PATH}/actions/runners/remove-token" \
    | jq -r '.token')

  if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
    ./config.sh remove --token "$REMOVE_TOKEN" || true
  fi
fi

REG_TOKEN=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_PAT}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${TARGET_REPO_PATH}/actions/runners/registration-token" \
  | jq -r '.token')

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  echo "ERROR: Failed to get registration token for ${TARGET_REPO_PATH}"
  exit 1
fi

./config.sh --unattended \
  --url "$TARGET_REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$(hostname)" \
  --labels "self-hosted,Linux,X64" \
  --work _work \
  --replace

./svc.sh install root
SERVICE_FILE=$(cat .service)
if ! grep -q "RUNNER_ALLOW_RUNASROOT=1" "/etc/systemd/system/${SERVICE_FILE}"; then
  sed -i '/\[Service\]/a Environment=RUNNER_ALLOW_RUNASROOT=1' "/etc/systemd/system/${SERVICE_FILE}"
fi

systemctl daemon-reload
./svc.sh start
systemctl is-active "$SERVICE_FILE"

echo "Runner service: $SERVICE_FILE"
echo "Runner successfully retargeted to: $TARGET_REPO_URL"
EOF
)

REMOTE_SCRIPT="${REMOTE_SCRIPT/__TARGET_REPO_B64__/$TARGET_REPO_B64}"
REMOTE_SCRIPT="${REMOTE_SCRIPT/__PAT_B64__/$PAT_B64}"

RUN_OUTPUT=$(run_with_timeout 120 az vm run-command invoke \
  --resource-group "$DBG_HUB_RG" \
  --name "$RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --query "value[0].message" \
  -o tsv)

if echo "$RUN_OUTPUT" | grep -qi "error:"; then
  result FAIL "VM command reported an error while retargeting the runner" || true
  echo ""
  echo "$RUN_OUTPUT"
  print_summary
fi

# Verify runner is now pointed at the requested repository.
LIVE_REPO_URL=$(run_with_timeout 120 az vm run-command invoke \
  --resource-group "$DBG_HUB_RG" \
  --name "$RUNNER_VM_NAME" \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --command-id RunShellScript \
  --scripts "if [ -f /root/actions-runner/.runner ]; then jq -r '.gitHubUrl // \"\"' /root/actions-runner/.runner; fi" \
  --query "value[0].message" \
  -o tsv | grep -Eo 'https://github.com/[^[:space:]]+' | tail -n 1 | tr -d '\r' | tr -d '\n')

if [[ "$LIVE_REPO_URL" != "$TARGET_REPO_URL" ]]; then
  result FAIL "Runner retarget did not take effect" || true
  echo ""
  echo "Current runner repo: ${LIVE_REPO_URL:-<unknown>}"
  echo "Expected runner repo: $TARGET_REPO_URL"
  echo ""
  echo "Most common causes:"
  echo "  1) PAT lacks runner admin permission on source or target repo"
  echo "  2) PAT was entered incorrectly"
  echo "  3) Runner remove/register token request was denied by GitHub API"
  echo ""
  echo "VM run-command output:"
  echo "$RUN_OUTPUT"
  print_summary
fi

result PASS "Runner VM re-registered to ${TARGET_REPO_PATH}" || true

print_step 3 "Verifying runner is online in GitHub"

ONLINE_STATUS=$(curl -fsSL -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${PAT_INPUT}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${TARGET_REPO_PATH}/actions/runners?per_page=100" \
  | jq -r --arg expected_name "$RUNNER_VM_NAME" \
      '.runners[]? | select(.name == $expected_name) | .status' \
  | head -n 1)

if [[ "$ONLINE_STATUS" != "online" ]]; then
  result FAIL "Runner is not online in GitHub after retarget" || true
  echo ""
  echo "Expected runner name: $RUNNER_VM_NAME"
  echo "Observed status: ${ONLINE_STATUS:-<not-found>}"
  echo "Target repo: $TARGET_REPO_URL"
  echo ""
  echo "Most common causes:"
  echo "  1) PAT lacks repo self-hosted runner admin permission"
  echo "  2) Runner service failed to start on VM"
  echo "  3) GitHub API rate limit or transient API failure"
  print_summary
fi

result PASS "Runner is online in GitHub for ${TARGET_REPO_PATH}" || true

print_step 4 "Persisting repo URL in azd environment"
if [[ "$UPDATE_AZD_ENV" -eq 1 ]]; then
  if azd env set AZURE_GITHUB_REPO_URL "$TARGET_REPO_URL" >/dev/null 2>&1; then
    result PASS "Updated azd env var AZURE_GITHUB_REPO_URL" || true
  else
    result WARN "Could not update azd env var. Set it manually: azd env set AZURE_GITHUB_REPO_URL '$TARGET_REPO_URL'" || true
  fi
else
  result WARN "Skipped azd env update (--no-azd-update)" || true
fi

print_step 5 "Verification commands"
echo "  Check runner service logs on VM:"
echo "    az vm run-command invoke -g '$DBG_HUB_RG' -n '$RUNNER_VM_NAME' --subscription '$DBG_SUBSCRIPTION_ID' --command-id RunShellScript --scripts \"svc=\\\$(cat /root/actions-runner/.service); journalctl -u \\\$svc -n 100 --no-pager\" --query 'value[0].message' -o tsv"

echo ""
print_summary
