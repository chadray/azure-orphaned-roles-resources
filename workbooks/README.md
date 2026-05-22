# Vendored Workbook — Azure Orphaned Resources

This workbook is vendored from [dolevshor/azure-orphan-resources](https://github.com/dolevshor/azure-orphan-resources) and extended with a **Security** tab for orphaned RBAC role assignments.

## Upstream

| Field | Value |
|-------|-------|
| Source repo | https://github.com/dolevshor/azure-orphan-resources |
| Version | v3.0 |
| License | MIT — Copyright (c) 2023 Dolev Shor |
| Retrieved | 2026-05-21 |

## What was added

- **Workspace parameter** — Log Analytics workspace picker (auto-selects first workspace) for the Security tab
- **Security main tab** — queries `OrphanedRoleAssignments_CL` and `OrphanedRoleScanSummary_CL` custom log tables
- **Overview tile** — orphaned role assignment count in the Overview dashboard (visible when a workspace is selected)

All original tabs (Compute, Storage, Database, Networking, Others) are unmodified.

## Deployment

### Via deploy.sh (recommended)

The `scripts/deploy.sh` script deploys the workbook automatically as part of the full infrastructure deployment. No manual steps needed.

### Azure Portal (manual)

1. Navigate to **Azure Monitor → Workbooks → + New**
2. Click **</>** (Advanced Editor)
3. Select **Gallery Template** as the template type
4. Paste the contents of `azure-orphaned-resources.workbook`
5. Click **Apply** → **Save**
6. In the filter bar, select your **Subscription(s)** and the **Log Analytics Workspace** containing the scan data

### Azure CLI

The workbook is too large (215KB) for Bicep's `loadTextContent()` limit. Deploy via `az rest` with a file-based body:

```bash
# Build the deployment payload
python3 -c "
import json
wb = json.load(open('workbooks/azure-orphaned-resources.workbook'))
body = {
    'location': '<region>',
    'kind': 'shared',
    'properties': {
        'displayName': 'Orphaned Azure Resources & Role Assignments',
        'category': 'workbook',
        'sourceId': 'Azure Monitor',
        'serializedData': json.dumps(wb)
    }
}
json.dump(body, open('/tmp/workbook-body.json', 'w'))
"

# Deploy (use --body @file, not inline JSON — inline silently drops large payloads)
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/workbooks/<guid>?api-version=2023-06-01" \
  --body @/tmp/workbook-body.json
```

> ⚠️ **Important**: Always use `--body @file` (not inline `--body "{...}"`) when deploying the workbook via `az rest`. Inline payloads silently truncate the 215KB serializedData field.

## Updating from upstream

To pull a newer version of the upstream workbook and re-apply the Security tab:

```bash
# 1. Download the latest upstream workbook
curl -sL "https://raw.githubusercontent.com/dolevshor/azure-orphan-resources/main/Workbook/Azure%20Orphaned%20Resources%20v3.0.workbook" \
  -o workbooks/azure-orphaned-resources.workbook

# 2. Re-apply the Security tab patch
python3 scripts/patch-workbook.py

# 3. Redeploy to Azure
./scripts/deploy.sh -g <rg> -s <sub-id>  # or manual import via Portal
```

## Technical Notes

- The Security tab queries use `queryType: 0` (Log Analytics) while all other tabs use `queryType: 1` (Azure Resource Graph)
- Custom table columns use **bare names** (e.g., `ScanId`, `TotalOrphaned`) — the DCR/Logs Ingestion API does not add `_s`/`_d`/`_b` suffixes like the legacy HTTP Data Collector API
- The Workspace parameter uses `resourceTypeFilter` to constrain the picker to `microsoft.operationalinsights/workspaces`
- The workbook file exceeds Bicep's 131KB `loadTextContent()` limit, so it must be deployed via CLI or Portal import
