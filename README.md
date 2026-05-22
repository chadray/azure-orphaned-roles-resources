# Azure Orphaned Resources & Role Assignment Scanner

Detects orphaned Azure RBAC role assignments and orphaned infrastructure resources, with an integrated Azure Monitor Workbook dashboard for visualization.

> Repo: [chadray/azure-orphaned-roles-resources](https://github.com/chadray/azure-orphaned-roles-resources)

## Overview

This project combines two complementary capabilities:

1. **Orphaned Role Assignment Scanner** — a PowerShell Azure Function App that detects (and optionally removes) RBAC role assignments pointing to deleted principals or deleted resource scopes
2. **Orphaned Resources Dashboard** — an Azure Monitor Workbook (based on [dolevshor/azure-orphan-resources](https://github.com/dolevshor/azure-orphan-resources), MIT license) that visualizes orphaned infrastructure resources (disks, NICs, IPs, NSGs, etc.) via Azure Resource Graph, extended with a **Security** tab for orphaned role assignments

### How It Works

```
┌──────────────────────┐     ┌─────────────────────┐     ┌──────────────────────┐
│   Azure Function App │     │   Log Analytics      │     │  Azure Monitor       │
│   (Timer Trigger)    │────▶│   Workspace          │◀────│  Workbook            │
│                      │     │                      │     │                      │
│  • Scan RBAC roles   │     │  • OrphanedRole-     │     │  • Security tab      │
│  • Detect orphans    │     │    Assignments_CL    │     │    (Log Analytics)   │
│  • Push to LA        │     │  • OrphanedRoleScan- │     │  • Compute, Storage, │
│  • Write blob report │     │    Summary_CL        │     │    Network, etc.     │
└──────────────────────┘     └─────────────────────┘     │    (Resource Graph)  │
                                                          └──────────────────────┘
```

The Function App runs daily, scans for orphaned role assignments, and pushes results to Log Analytics via the Logs Ingestion API (managed identity, no shared keys). The workbook queries both Log Analytics and Azure Resource Graph to provide a unified view.

## What It Detects

### Orphaned Role Assignments (Function App scan)

| Type                   | Description                                                                          | Detection Method                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| **Orphaned Principal** | The Entra ID identity (user, group, service principal, managed identity) was deleted | `ObjectType -eq "Unknown"` + confirmation via `Get-AzADServicePrincipal`/`Get-AzADUser`/`Get-AzADGroup` |
| **Orphaned Scope**     | The Azure resource the assignment targets no longer exists                           | Scope-type-aware validation (management group, subscription, resource group, resource)                  |

### Orphaned Infrastructure Resources (Workbook real-time queries)

Compute (App Service Plans, Availability Sets), Storage (Managed Disks), Database (SQL Elastic Pools), Networking (Public IPs, NICs, NSGs, Route Tables, Load Balancers, NAT Gateways, VNet Gateways, and more), Others (empty Resource Groups, API Connections, expired Certificates).

## Quick Start — Deploy to a New Subscription

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) with Bicep support (`az bicep install`)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local) (`npm install -g azure-functions-core-tools@4`)
- Python 3 (for workbook patching, already included on most systems)
- An Azure subscription with **Owner** or **Contributor + User Access Administrator**

### Step 1 — Deploy

```bash
git clone https://github.com/chadray/azure-orphaned-roles-resources.git
cd azure-orphaned-roles-resources

# Deploy everything to your subscription
./scripts/deploy.sh -g rg-azure-orphans -s <your-subscription-id>
```

This single command creates all Azure resources, publishes the Function App code, deploys the workbook, and configures role assignments. See [What Gets Deployed](#what-gets-deployed) for the full resource list.

**Options:**

```
./scripts/deploy.sh -g <resource-group> -s <subscription-id> [-l <location>] [-n <base-name>]

  -g    Resource group name (created if it doesn't exist)
  -s    Subscription ID to scan for orphaned role assignments
  -l    Azure region (default: eastus)
  -n    Base name prefix for resources (default: orphroles)
```

### Step 2 — Grant Entra ID Permissions

The deploy script handles all Azure RBAC permissions, but principal validation requires **Entra ID read access** which must be granted by a tenant administrator:

```bash
# Option A: Grant via Microsoft Graph application permission (requires admin consent)
az ad app permission add \
  --id <function-app-enterprise-app-object-id> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions 7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role

az ad app permission admin-consent --id <function-app-enterprise-app-object-id>

# Option B: Assign Directory Readers role (simpler, requires Privileged Role Administrator)
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=88d8e3e3-8f55-4a1e-953a-9b9898b8876b/members/\$ref" \
  --body "{\"@odata.id\": \"https://graph.microsoft.com/v1.0/servicePrincipals/<function-app-principal-id>\"}"
```

> ⚠️ Without Entra ID read permissions, the scanner will still detect orphaned principals (via `ObjectType -eq "Unknown"`) but cannot confirm them with secondary lookups. Detections will be marked as `Suspected` instead of `Confirmed`.

### Step 3 — Verify

1. **Trigger a manual scan** (or wait for the daily 6 AM UTC run):

   ```bash
   # Get the master key
   MASTER_KEY=$(az rest --method POST \
     --url "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<func-app-name>/host/default/listKeys?api-version=2023-12-01" \
     --query "masterKey" -o tsv)

   # Trigger the function
   curl -X POST \
     "https://<func-app-name>.azurewebsites.net/admin/functions/TimerTriggerOrphanedRoles" \
     -H "x-functions-key: $MASTER_KEY" \
     -H "Content-Type: application/json" \
     -d '{}'
   ```

2. **View the workbook**: Azure Portal → **Azure Monitor → Workbooks** → open **"Orphaned Azure Resources & Role Assignments"**

3. **Select the workspace**: In the workbook filter bar, select your **Log Analytics Workspace** (the `orphroles-law-*` workspace) to view the Security tab data

### Step 4 — (Optional) Enable Cleanup

Cleanup is disabled by default. To enable it, update the Function App settings:

```bash
az functionapp config appsettings set \
  --name <func-app-name> \
  --resource-group <rg> \
  --settings \
    ENABLE_ROLE_ASSIGNMENT_CLEANUP=true \
    CLEANUP_ORPHANED_PRINCIPALS=true
```

## What Gets Deployed

The `deploy.sh` script and Bicep template create the following resources:

| Resource | Purpose |
|----------|---------|
| **Resource Group** | Container for all resources |
| **Storage Account** | Function App runtime storage + report blob container |
| **App Service Plan** (B1) | Hosts the Function App |
| **Function App** (PowerShell 7.4) | Runs the orphaned role assignment scanner on a daily schedule |
| **Application Insights** | Function App monitoring and diagnostics |
| **Log Analytics Workspace** | Stores scan results in custom tables |
| **Custom Tables** | `OrphanedRoleAssignments_CL` and `OrphanedRoleScanSummary_CL` |
| **Data Collection Endpoint** | Ingestion endpoint for the Logs Ingestion API |
| **Data Collection Rule** | Maps ingestion streams to custom tables |
| **Azure Monitor Workbook** | Dashboard combining Resource Graph + Log Analytics data |
| **Role Assignments** | Reader (scan scope), Monitoring Metrics Publisher (DCR), Storage Blob Data Owner + Account Contributor + Queue/Table Data Contributor (storage) |

> 💡 The Function App uses **managed identity for all Azure access** — no shared keys or connection strings. Storage access uses identity-based auth (`AzureWebJobsStorage__accountName`) which is compatible with subscriptions that enforce `allowSharedKeyAccess=false`.

## Manual / Step-by-Step Deployment

If you prefer to deploy infrastructure and code separately:

```bash
# 1. Create resource group
az group create --name <rg> --location <region>

# 2. Deploy infrastructure via Bicep
az deployment group create \
  --resource-group <rg> \
  --template-file infra/main.bicep \
  --parameters \
    baseName=orphroles \
    scanScope=/subscriptions/<sub-id>

# 3. Publish Function App code
func azure functionapp publish <func-app-name> --powershell

# 4. Import workbook manually
#    Azure Portal → Azure Monitor → Workbooks → + New → </> Advanced Editor
#    Select "Gallery Template" → paste contents of workbooks/azure-orphaned-resources.workbook
#    Click Apply → Save

# 5. Grant Reader at scan scope
az role assignment create \
  --assignee-object-id <func-principal-id> \
  --assignee-principal-type ServicePrincipal \
  --role Reader \
  --scope /subscriptions/<sub-id>
```

## Azure Monitor Workbook Dashboard

The workbook combines orphaned RBAC role assignments (from Log Analytics) with orphaned Azure resources (from Resource Graph) in a unified dashboard.

**Tabs:**

| Tab | Data Source | Content |
|-----|-------------|---------|
| Overview | Resource Graph + Log Analytics | Tile counters for all orphaned resource types |
| Compute | Resource Graph | App Service Plans, Availability Sets |
| Storage | Resource Graph | Managed Disks |
| Database | Resource Graph | SQL Elastic Pools |
| Networking | Resource Graph | Public IPs, NICs, NSGs, Route Tables, Load Balancers, etc. |
| Others | Resource Graph | Resource Groups, API Connections, Certificates |
| **Security** | **Log Analytics** | **Orphaned role assignments — last scan summary, pie charts by reason/status/role, detail table** |

> ℹ️ The Resource Graph tabs (Compute, Storage, etc.) show **real-time** data. The Security tab shows **scan-based** data updated each Function App run. The workbook displays the last scan timestamp prominently.

### Workbook Filters

- **Subscription** — select which subscriptions to query (affects all tabs)
- **Resource Group** — filter by resource group (affects Resource Graph tabs)
- **Log Analytics Workspace** — select the workspace containing scan data (affects Security tab)
- **Enable Deletion** — toggle to show delete buttons on Resource Graph tabs (does not apply to Security tab — role assignment cleanup is handled by the Function App)

### Updating the Workbook

The workbook is vendored from [dolevshor/azure-orphan-resources](https://github.com/dolevshor/azure-orphan-resources) and patched with the Security tab using `scripts/patch-workbook.py`. To update to a newer upstream version:

```bash
# Download the latest upstream workbook
curl -sL "https://raw.githubusercontent.com/dolevshor/azure-orphan-resources/main/Workbook/Azure%20Orphaned%20Resources%20v3.0.workbook" \
  -o workbooks/azure-orphaned-resources.workbook

# Re-apply the Security tab patch
python3 scripts/patch-workbook.py

# Redeploy (via deploy.sh or manual import)
```

## Report Output

Every scan produces a JSON report with:

- **ReportMetadata** — timestamp, scope, counts by orphan type, detection confidence breakdown
- **OrphanedAssignments** — full details per assignment:
  - `RoleAssignmentId`, `RoleDefinitionName`, `PrincipalId`, `Scope`
  - `OrphanReasons` — `OrphanedPrincipal`, `OrphanedScope`, or both
  - `DetectionStatus` — `Confirmed` or `Suspected`
  - `CanSafelyDelete` — only `true` when detection is `Confirmed`
- **CleanupResults** — action taken per assignment (`Deleted`, `WouldDelete`, `Skipped`, `Failed`)

Reports are written to:
1. **Function App logs** (always)
2. **Azure Blob Storage** (if `REPORT_OUTPUT_BLOB_CONTAINER` is set)
3. **Log Analytics** (if `LOG_INGESTION_DCE_URI` and `LOG_INGESTION_DCR_IMMUTABLE_ID` are set)

### Converting Reports to CSV / HTML

The `scripts/convert-report.py` script converts a JSON report into user-friendly CSV and HTML formats. No external dependencies — just Python 3.

```bash
# Generate both CSV and HTML (default)
python3 scripts/convert-report.py sample-report.json

# CSV only
python3 scripts/convert-report.py report.json --no-html

# HTML only
python3 scripts/convert-report.py report.json --no-csv

# Custom output paths
python3 scripts/convert-report.py report.json --csv results.csv --html results.html
```

**HTML report** — self-contained dashboard with summary cards and a color-coded table (green = safe to delete, yellow = needs review):

![HTML report example](docs/images/html-report.png)

**CSV report** — flat table that opens directly in Excel, Google Sheets, or any spreadsheet tool. Includes shortened IDs, friendly scope names, and clear Yes/No safe-to-delete values:

![CSV report example](docs/images/csv-report.png)

## Safety Features

- **Dry-run by default** — no deletions occur unless explicitly enabled via app settings
- **Tri-state scope validation** — only flags `NotFound` as orphaned; permission errors and ambiguous results are not treated as orphaned
- **Principal confirmation** — secondary Entra ID lookups confirm deletion beyond the `Unknown` ObjectType signal
- **Confidence-gated deletion** — only `Confirmed` orphans are eligible for cleanup; `Suspected` items are reported but never deleted
- **Granular cleanup toggles** — principals and scopes can be enabled/disabled independently
- **Non-fatal ingestion** — Log Analytics push failures are logged as warnings; scan results remain available in logs and blob storage

## Required Permissions

### Function App Managed Identity

| Permission                                       | Purpose                                    | Granted by deploy script? |
| ------------------------------------------------ | ------------------------------------------ | :-----------------------: |
| `Reader` at scan scope                           | Read resources for scope validation        | ✅ |
| `Storage Blob Data Owner` on storage account     | Blob report storage + Functions runtime    | ✅ |
| `Storage Account Contributor` on storage account | Content share management                   | ✅ |
| `Storage Queue Data Contributor` on storage account | Internal queue management               | ✅ |
| `Storage Table Data Contributor` on storage account | Timer trigger lease management           | ✅ |
| `Monitoring Metrics Publisher` on DCR            | Push scan results to Log Analytics         | ✅ |
| `Directory.Read.All` (Entra ID)                  | Confirm principal existence                | ❌ Manual |
| `Microsoft.Authorization/roleAssignments/delete` | Remove orphaned assignments (cleanup only) | ❌ Manual |

### Workbook Viewers

- `Reader` on target subscriptions (for Resource Graph tabs)
- `Log Analytics Reader` on the workspace (for Security tab)

## App Settings

| Setting                              | Default                                  | Description                                      |
| ------------------------------------ | ---------------------------------------- | ------------------------------------------------ |
| `ORPHANED_ROLES_SCAN_SCOPE`          | `/`                                      | Azure scope to scan                              |
| `ENABLE_ROLE_ASSIGNMENT_CLEANUP`     | `false`                                  | Set to `true` to enable the cleanup phase        |
| `CLEANUP_ORPHANED_PRINCIPALS`        | `false`                                  | Allow deletion of orphaned-principal assignments |
| `CLEANUP_ORPHANED_SCOPES`            | `false`                                  | Allow deletion of orphaned-scope assignments     |
| `REPORT_OUTPUT_BLOB_CONTAINER`       | `orphaned-role-reports`                  | Blob container for report output                 |
| `LOG_INGESTION_DCE_URI`              | *(empty — disables ingestion)*           | Data Collection Endpoint URI                     |
| `LOG_INGESTION_DCR_IMMUTABLE_ID`     | *(empty — disables ingestion)*           | Data Collection Rule immutable ID                |
| `LOG_INGESTION_STREAM_NAME`          | `Custom-OrphanedRoleAssignments_CL`      | DCR stream for assignment detail records         |
| `LOG_INGESTION_SUMMARY_STREAM_NAME`  | `Custom-OrphanedRoleScanSummary_CL`      | DCR stream for scan summary records              |

## Standalone Usage

The PowerShell module can be used independently outside the Function App:

```powershell
Import-Module ./modules/OrphanedRoleAssignments.psm1

# Scan only (no cleanup)
$orphaned = Find-OrphanedRoleAssignments -Scope '/'

# View results
$orphaned | Format-Table RoleDefinitionName, PrincipalId, Scope, OrphanReasons, DetectionStatus

# Dry-run cleanup (see what would be deleted)
$results = Remove-OrphanedRoleAssignments -OrphanedAssignments $orphaned -DryRun $true -CleanupPrincipals $true
$results | Where-Object Action -eq 'WouldDelete' | Format-Table

# Live cleanup (confirmed orphaned principals only)
$results = Remove-OrphanedRoleAssignments -OrphanedAssignments $orphaned -DryRun $false -CleanupPrincipals $true

# Generate full report
$report = New-OrphanedRoleReport -OrphanedAssignments $orphaned -CleanupResults $results
$report | ConvertTo-Json -Depth 10 | Out-File report.json
```

## Local Development

```bash
# Clone the repo
git clone https://github.com/chadray/azure-orphaned-roles-resources.git
cd azure-orphaned-roles-resources

# Install Azure Functions Core Tools
npm install -g azure-functions-core-tools@4

# Copy the sample local settings and adjust if needed
cp local.settings.json.sample local.settings.json

# Sign in to Azure (the local runtime uses your Az context)
pwsh -Command 'Connect-AzAccount'

# Run locally
func start
```

A sanitized example of the JSON report produced by a scan lives in [sample-report.json](sample-report.json).

## Schedule

Default: daily at 6:00 AM UTC (`0 0 6 * * *`). Modify in `TimerTriggerOrphanedRoles/function.json`.

## Architecture

```
├── host.json                              # Function App host config
├── requirements.psd1                      # Az module dependencies (Accounts, Resources, Storage)
├── profile.ps1                            # Managed identity auth on startup
├── local.settings.json.sample             # Template for local dev settings
├── sample-report.json                     # Example scan report (sanitized)
├── .funcignore                            # Files excluded from func publish
├── docs/
│   └── images/                            # Screenshots for README
│       ├── html-report.png
│       └── csv-report.png
├── infra/
│   ├── main.bicep                         # Azure infrastructure (all resources)
│   └── main.bicepparam                    # Parameter defaults
├── modules/
│   ├── OrphanedRoleAssignments.psm1       # Core detection & cleanup logic
│   └── LogAnalyticsIngestion.psm1         # Logs Ingestion API client (managed identity)
├── scripts/
│   ├── convert-report.py                  # JSON → CSV / HTML converter
│   ├── deploy.sh                          # One-command Azure deployment
│   ├── patch-workbook.py                  # Adds Security tab to vendored workbook
│   └── test-scan.ps1                      # Local dry-run harness
├── workbooks/
│   ├── azure-orphaned-resources.workbook  # Azure Monitor Workbook (patched with Security tab)
│   └── README.md                          # Workbook attribution & deployment notes
└── TimerTriggerOrphanedRoles/
    ├── function.json                      # Timer trigger binding (daily 6 AM UTC)
    └── run.ps1                            # Function entry point
```

## Contributing

Issues and PRs are welcome. When opening a PR:

- Keep the module (`modules/OrphanedRoleAssignments.psm1`) free of Function-runtime-specific code so it stays reusable as a standalone PowerShell module.
- Do not commit `local.settings.json` or any scan output containing real subscription, tenant, or principal IDs — these are already excluded via `.gitignore`.
- Run `scripts/test-scan.ps1` against a dev subscription before submitting changes that touch detection logic.
- If updating the workbook, use `scripts/patch-workbook.py` to re-patch from upstream rather than editing the `.workbook` file directly.

## Disclaimer

This project is provided as-is, with no warranty. Cleanup of role assignments is irreversible — always run with `ENABLE_ROLE_ASSIGNMENT_CLEANUP=false` first and review the report before enabling deletion.
