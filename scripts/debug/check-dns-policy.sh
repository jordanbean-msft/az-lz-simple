#!/usr/bin/env bash
# -------------------------------------------------------------------
# check-dns-policy.sh — Verify DINE policy compliance for private DNS
#
# This repo deploys DeployIfNotExists (DINE) Azure Policies that
# automatically create DNS zone groups on private endpoints. This
# script checks whether those policies are assigned, compliant, and
# whether any private endpoints are missing DNS zone groups.
#
# Usage:
#   ./scripts/debug/check-dns-policy.sh                    # check compliance
#   ./scripts/debug/check-dns-policy.sh --remediate        # trigger remediation for non-compliant resources
#   ./scripts/debug/check-dns-policy.sh --resource-group RG # check PEs in a specific RG
#   ./scripts/debug/check-dns-policy.sh --all              # check PEs in hub + all spoke RGs
# -------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
source "$SCRIPT_DIR/load-config.sh"

check_help "check-dns-policy.sh" "Verify DINE policies created DNS zone groups on private endpoints" \
  "./scripts/debug/check-dns-policy.sh" \
  "./scripts/debug/check-dns-policy.sh --all" \
  "./scripts/debug/check-dns-policy.sh --remediate" \
  "./scripts/debug/check-dns-policy.sh --all --remediate"

REMEDIATE=false
SCAN_ALL=false
TARGET_RGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remediate) REMEDIATE=true; shift ;;
    --all) SCAN_ALL=true; shift ;;
    --resource-group) TARGET_RGS+=("$2"); shift 2 ;;
    *) TARGET_RGS+=("$1"); shift ;;
  esac
done

if $SCAN_ALL; then
  TARGET_RGS=("$DBG_HUB_RG")
  for i in $(seq 0 $((DBG_SPOKE_COUNT - 1))); do
    SPOKE_RG=$(jq -r ".spokes[$i].resourceGroupName" "$REPO_ROOT/.azure-debug-config.json")
    TARGET_RGS+=("$SPOKE_RG")
  done
elif [[ ${#TARGET_RGS[@]} -eq 0 ]]; then
  TARGET_RGS=("$DBG_HUB_RG")
fi

print_header "DNS DINE Policy Diagnostics"

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI is required."
  exit 1
fi

# ── 1. Check DINE policy assignments ──
print_step 1 "DINE policy assignments"
echo "  Looking for 'Azure PaaS Private DNS Zone' policy assignments..."

# These policies are assigned at subscription scope by this repo's Bicep
DINE_POLICIES=$(run_with_timeout 25 az policy assignment list \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --query "[?contains(displayName, 'Azure PaaS Private DNS Zone')].{name:name, displayName:displayName, enforcementMode:enforcementMode, id:id}" \
  -o json 2>/dev/null || echo "[]")

DINE_COUNT=$(echo "$DINE_POLICIES" | jq length)

if [[ "$DINE_COUNT" -eq 0 ]]; then
  # Fall back to RG-scoped check
  DINE_POLICIES=$(run_with_timeout 25 az policy assignment list \
    --resource-group "$DBG_HUB_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[?contains(displayName, 'Azure PaaS Private DNS Zone')].{name:name, displayName:displayName, enforcementMode:enforcementMode, id:id}" \
    -o json 2>/dev/null || echo "[]")
  DINE_COUNT=$(echo "$DINE_POLICIES" | jq length)
fi

if [[ "$DINE_COUNT" -eq 0 ]]; then
  result FAIL "No DINE policy assignments found for private DNS zone groups"
  echo "         → The Bicep deployment may not have completed, or policies were removed."
  echo "         → Run: azd provision to redeploy infrastructure including policies."
else
  echo "    Found $DINE_COUNT DINE policy assignment(s)"
  echo "$DINE_POLICIES" | jq -r '.[0:10] | .[] | "    - \(.displayName) [\(.enforcementMode // "Default")]"'
  if [[ "$DINE_COUNT" -gt 10 ]]; then
    echo "    ... and $((DINE_COUNT - 10)) more"
  fi
  result PASS "$DINE_COUNT DINE policy assignment(s) for private DNS zones"
fi

# ── 2. Check overall policy compliance ──
print_step 2 "Policy compliance state"
echo "  Querying compliance for private DNS DINE policies..."

NON_COMPLIANT=$(run_with_timeout 35 az policy state list \
  --subscription "$DBG_SUBSCRIPTION_ID" \
  --filter "policyDefinitionAction eq 'deployifnotexists' and complianceState eq 'NonCompliant'" \
  --query "[?contains(policyAssignmentName, 'dns') || contains(policyAssignmentName, 'privatelink') || contains(policyAssignmentName, 'blob') || contains(policyAssignmentName, 'vault') || contains(policyAssignmentName, 'sql') || contains(policyAssignmentName, 'sites') || contains(policyAssignmentName, 'registry')].{resourceId:resourceId, policyAssignment:policyAssignmentName, complianceState:complianceState}" \
  -o json 2>/dev/null || echo "[]")

NC_COUNT=$(echo "$NON_COMPLIANT" | jq length)

if [[ "$NC_COUNT" -eq 0 ]]; then
  result PASS "All private endpoint DINE policies are compliant"
else
  result WARN "$NC_COUNT non-compliant resource(s) found"
  echo ""
  echo "    Non-compliant resources (PEs missing DNS zone groups):"
  echo "$NON_COMPLIANT" | jq -r '.[] | "    ❌ \(.resourceId | split("/") | last) → policy: \(.policyAssignment)"' | head -20
  if [[ "$NC_COUNT" -gt 20 ]]; then
    echo "    ... and $((NC_COUNT - 20)) more"
  fi
fi

# ── 3. Check DNS zone groups on private endpoints ──
print_step 3 "DNS zone group verification on private endpoints"

MISSING_ZONE_GROUPS=()

for TARGET_RG in "${TARGET_RGS[@]}"; do
  echo ""
  echo "  Scanning: $TARGET_RG"

  PE_LIST=$(run_with_timeout 30 az network private-endpoint list \
    --resource-group "$TARGET_RG" \
    --subscription "$DBG_SUBSCRIPTION_ID" \
    --query "[].{name:name, groupIds:privateLinkServiceConnections[0].groupIds[0], resource:privateLinkServiceConnections[0].privateLinkServiceId}" \
    -o json 2>/dev/null || echo "[]")

  PE_COUNT=$(echo "$PE_LIST" | jq length)
  if [[ "$PE_COUNT" -eq 0 ]]; then
    echo "    No private endpoints in $TARGET_RG"
    continue
  fi

  echo "$PE_LIST" | jq -c '.[]' | while read -r pe; do
    PE_NAME=$(echo "$pe" | jq -r '.name')
    PE_GROUP=$(echo "$pe" | jq -r '.groupIds // "unknown"')
    PE_RESOURCE=$(echo "$pe" | jq -r '.resource // "unknown"' | sed 's|.*/||')

    # Check for DNS zone groups on this PE
    ZONE_GROUPS=$(run_with_timeout 20 az network private-endpoint dns-zone-group list \
      --endpoint-name "$PE_NAME" \
      --resource-group "$TARGET_RG" \
      --subscription "$DBG_SUBSCRIPTION_ID" \
      --query "[].{name:name, zones:privateDnsZoneConfigs[].{zone:privateDnsZoneId, name:name}}" \
      -o json 2>/dev/null || echo "[]")

    ZG_COUNT=$(echo "$ZONE_GROUPS" | jq length)

    if [[ "$ZG_COUNT" -eq 0 ]]; then
      result FAIL "PE '$PE_NAME' ($PE_RESOURCE/$PE_GROUP) has NO DNS zone group"
      echo "         → DINE policy may not have evaluated yet, or the policy is missing for this resource type."
      echo "         → A records will NOT be created until a DNS zone group exists."
      # Track for remediation
      echo "$TARGET_RG/$PE_NAME" >> /tmp/missing-zone-groups.$$ 2>/dev/null || true
    else
      ZONE_NAMES=$(echo "$ZONE_GROUPS" | jq -r '.[].zones[]?.zone // empty' | xargs -I{} basename {} | tr '\n' ', ' | sed 's/,$//')
      result PASS "PE '$PE_NAME' → DNS zone group linked to: $ZONE_NAMES"
    fi
  done
done

# ── 4. Trigger remediation if requested ──
if $REMEDIATE && [[ "$NC_COUNT" -gt 0 || -f /tmp/missing-zone-groups.$$ ]]; then
  print_step 4 "Triggering policy remediation"
  echo ""

  if [[ "$DINE_COUNT" -eq 0 ]]; then
    result FAIL "Cannot remediate — no DINE policy assignments found"
  else
    # Trigger remediation for each non-compliant policy assignment
    REMEDIATED=0
    echo "$DINE_POLICIES" | jq -r '.[].id' | while read -r assignment_id; do
      ASSIGNMENT_NAME=$(echo "$assignment_id" | sed 's|.*/||')
      echo "  Triggering remediation for: $ASSIGNMENT_NAME"
      run_with_timeout 30 az policy remediation create \
        --name "remediate-${ASSIGNMENT_NAME}-$(date +%s)" \
        --policy-assignment "$assignment_id" \
        --subscription "$DBG_SUBSCRIPTION_ID" \
        --resource-discovery-mode ReEvaluateCompliance \
        -o none 2>/dev/null && echo "    ✅ Remediation task created" || echo "    ⚠️  Failed to create remediation task"
    done

    echo ""
    echo "  Remediation tasks created. Azure will evaluate and deploy DNS zone groups."
    echo "  This typically takes 5-15 minutes. Re-run this script to check progress."
  fi
else
  echo ""
  if [[ "$NC_COUNT" -gt 0 ]]; then
    echo "  To trigger remediation for non-compliant resources, run:"
    echo "    $0 --remediate"
  fi
fi

# Clean up temp file
rm -f /tmp/missing-zone-groups.$$ 2>/dev/null || true

print_summary \
  "DINE policy may not have evaluated yet → Wait 15-30 min, or run: $0 --remediate" \
  "Policy managed identity may lack permissions → Needs 'Network Contributor' + 'Private DNS Zone Contributor'" \
  "Private DNS zone may not exist → Run: ./scripts/debug/check-private-dns-zones.sh" \
  "Policy assignment may be disabled → Run: az policy assignment list --subscription $DBG_SUBSCRIPTION_ID -o table"
