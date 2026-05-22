#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
#  Deploy Orphaned Role Assignment Scanner to Azure
# ──────────────────────────────────────────────────────────────────────
#  Usage:
#    ./scripts/deploy.sh -g <resource-group> -s <subscription-id> [-l <location>] [-n <base-name>]
#
#  This script:
#   1. Creates the resource group (if needed)
#   2. Deploys infrastructure via Bicep (Function App, Log Analytics, DCE/DCR, Workbook)
#   3. Publishes the Function App code
#   4. Grants the Function App's managed identity Reader at the scan scope
# ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
LOCATION="eastus"
BASE_NAME="orphroles"
SCAN_SCOPE=""

usage() {
  cat <<EOF
Usage: $0 -g <resource-group> -s <subscription-id> [options]

Required:
  -g    Resource group name (created if it doesn't exist)
  -s    Subscription ID to scan for orphaned role assignments

Options:
  -l    Azure region (default: $LOCATION)
  -n    Base name for resources (default: $BASE_NAME)
  -h    Show this help

Example:
  $0 -g rg-orphaned-roles -s 00000000-0000-0000-0000-000000000000
EOF
  exit 1
}

while getopts "g:s:l:n:h" opt; do
  case $opt in
    g) RESOURCE_GROUP="$OPTARG" ;;
    s) SUBSCRIPTION_ID="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    n) BASE_NAME="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ -z "${RESOURCE_GROUP:-}" || -z "${SUBSCRIPTION_ID:-}" ]]; then
  echo "Error: -g (resource group) and -s (subscription ID) are required."
  usage
fi

SCAN_SCOPE="/subscriptions/$SUBSCRIPTION_ID"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Orphaned Role Assignment Scanner — Azure Deployment        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Subscription  : $SUBSCRIPTION_ID"
echo "  Resource Group : $RESOURCE_GROUP"
echo "  Location       : $LOCATION"
echo "  Base Name      : $BASE_NAME"
echo "  Scan Scope     : $SCAN_SCOPE"
echo ""

# Set subscription context
echo "→ Setting subscription context..."
az account set --subscription "$SUBSCRIPTION_ID"

# Create resource group
echo "→ Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# Deploy infrastructure
echo "→ Deploying infrastructure (Bicep)..."
DEPLOY_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$REPO_ROOT/infra/main.bicep" \
  --parameters \
    baseName="$BASE_NAME" \
    location="$LOCATION" \
    scanScope="$SCAN_SCOPE" \
  --output json)

FUNC_APP_NAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.functionAppName.value')
FUNC_PRINCIPAL_ID=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.functionAppPrincipalId.value')
LAW_ID=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.logAnalyticsWorkspaceId.value')
DCE_URI=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.dceUri.value')
DCR_ID=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.dcrImmutableId.value')

echo ""
echo "  Function App   : $FUNC_APP_NAME"
echo "  Principal ID   : $FUNC_PRINCIPAL_ID"
echo "  Workspace ID   : $LAW_ID"
echo "  DCE URI        : $DCE_URI"
echo "  DCR Immutable  : $DCR_ID"
echo ""

# Grant Reader role at subscription scope
echo "→ Granting Reader role to Function App managed identity..."
az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" \
  --scope "$SCAN_SCOPE" \
  --output none 2>/dev/null || echo "  (Reader role may already be assigned)"

# Publish Function App code
echo "→ Publishing Function App code..."
cd "$REPO_ROOT"
func azure functionapp publish "$FUNC_APP_NAME" --powershell

# Deploy workbook (too large for Bicep loadTextContent or inline az rest)
echo "→ Deploying Azure Monitor Workbook..."
WORKBOOK_ID=$(python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, '$RESOURCE_GROUP-orphaned-workbook'))")

python3 -c "
import json
wb = json.load(open('$REPO_ROOT/workbooks/azure-orphaned-resources.workbook'))
body = {
    'location': '$LOCATION',
    'kind': 'shared',
    'properties': {
        'displayName': 'Orphaned Azure Resources & Role Assignments',
        'category': 'workbook',
        'sourceId': 'Azure Monitor',
        'serializedData': json.dumps(wb)
    }
}
json.dump(body, open('/tmp/workbook-deploy-body.json', 'w'))
"

az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/workbooks/$WORKBOOK_ID?api-version=2023-06-01" \
  --body @/tmp/workbook-deploy-body.json \
  --output none 2>/dev/null && echo "  Workbook deployed successfully" || echo "  ⚠️  Workbook deployment failed — import manually via Azure Portal"

rm -f /tmp/workbook-deploy-body.json

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅  Deployment complete!                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo ""
echo "  1. Grant Entra ID read permissions to the Function App identity:"
echo "     az ad app permission add --id <app-id> --api 00000003-0000-0000-c000-000000000000 \\"
echo "       --api-permissions 7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role"
echo ""
echo "  2. View the workbook in Azure Portal:"
echo "     Azure Monitor → Workbooks → 'Orphaned Azure Resources & Role Assignments'"
echo ""
echo "  3. Trigger a manual scan (optional):"
echo "     az functionapp function invoke \\"
echo "       --resource-group $RESOURCE_GROUP \\"
echo "       --name $FUNC_APP_NAME \\"
echo "       --function-name TimerTriggerOrphanedRoles"
echo ""
echo "  4. Monitor Function App logs:"
echo "     func azure functionapp logstream $FUNC_APP_NAME"
echo ""
