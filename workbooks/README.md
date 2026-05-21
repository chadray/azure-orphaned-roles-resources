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

- **Workspace parameter** — Log Analytics workspace picker for the Security tab
- **Security main tab** — queries `OrphanedRoleAssignments_CL` and `OrphanedRoleScanSummary_CL` custom log tables
- **Overview tile** — orphaned role assignment count in the Overview dashboard

All original tabs (Compute, Storage, Database, Networking, Others) are unmodified.

## Deployment

### Azure Portal (manual)

1. Navigate to **Azure Monitor → Workbooks → + New**
2. Click **</>** (Advanced Editor)
3. Select **Gallery Template** as the template type
4. Paste the contents of `azure-orphaned-resources.workbook`
5. Click **Apply** → **Save**

### ARM / CLI

```bash
az deployment group create \
  --resource-group <your-rg> \
  --template-file workbooks/deploy-workbook.json \
  --parameters workbookDisplayName="Orphaned Azure Resources"
```
