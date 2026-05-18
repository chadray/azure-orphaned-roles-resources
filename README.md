# Orphaned Role Assignment Scanner

Azure Function App (PowerShell) that detects and optionally removes orphaned Azure RBAC role assignments on a schedule.

> Repo: [chadray/azure-orphaned-roles-resources](https://github.com/chadray/azure-orphaned-roles-resources)

## What It Detects

| Type                   | Description                                                                          | Detection Method                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| **Orphaned Principal** | The Entra ID identity (user, group, service principal, managed identity) was deleted | `ObjectType -eq "Unknown"` + confirmation via `Get-AzADServicePrincipal`/`Get-AzADUser`/`Get-AzADGroup` |
| **Orphaned Scope**     | The Azure resource the assignment targets no longer exists                           | Scope-type-aware validation (management group, subscription, resource group, resource)                  |

## Report Output

Every run produces a JSON report with:

- **ReportMetadata** — timestamp, scope, counts by orphan type, detection confidence breakdown
- **OrphanedAssignments** — full details per assignment:
  - `RoleAssignmentId`, `RoleDefinitionName`, `PrincipalId`, `Scope`
  - `OrphanReasons` — `OrphanedPrincipal`, `OrphanedScope`, or both
  - `DetectionStatus` — `Confirmed` or `Suspected`
  - `CanSafelyDelete` — only `true` when detection is `Confirmed`
- **CleanupResults** — action taken per assignment (`Deleted`, `WouldDelete`, `Skipped`, `Failed`)

Reports are written to Function App logs and optionally to Azure Blob Storage.

## Safety Features

- **Dry-run by default** — no deletions occur unless explicitly enabled via app settings
- **Tri-state scope validation** — only flags `NotFound` as orphaned; permission errors and ambiguous results are not treated as orphaned
- **Principal confirmation** — secondary Entra ID lookups confirm deletion beyond the `Unknown` ObjectType signal
- **Confidence-gated deletion** — only `Confirmed` orphans are eligible for cleanup; `Suspected` items are reported but never deleted
- **Granular cleanup toggles** — principals and scopes can be enabled/disabled independently

## Required Permissions

The Function App's managed identity needs:

| Permission                                       | Purpose                                    |
| ------------------------------------------------ | ------------------------------------------ |
| `Reader` at target scope                         | Read resources for scope validation        |
| `Microsoft.Authorization/roleAssignments/read`   | Enumerate role assignments                 |
| `Microsoft.Authorization/roleAssignments/delete` | Remove orphaned assignments (cleanup only) |
| `Directory.Read.All` or equivalent Entra ID read | Confirm principal existence                |

> **Recommended role for scan-only**: `Reader` + custom role with `Microsoft.Authorization/roleAssignments/read`
> **Recommended role for cleanup**: `User Access Administrator` at the scan scope

## App Settings

| Setting                          | Default                 | Description                                      |
| -------------------------------- | ----------------------- | ------------------------------------------------ |
| `ORPHANED_ROLES_SCAN_SCOPE`      | `/`                     | Azure scope to scan                              |
| `ENABLE_ROLE_ASSIGNMENT_CLEANUP` | `false`                 | Set to `true` to enable the cleanup phase        |
| `CLEANUP_ORPHANED_PRINCIPALS`    | `false`                 | Allow deletion of orphaned-principal assignments |
| `CLEANUP_ORPHANED_SCOPES`        | `false`                 | Allow deletion of orphaned-scope assignments     |
| `REPORT_OUTPUT_BLOB_CONTAINER`   | `orphaned-role-reports` | Blob container for report output                 |

## Deployment

### Prerequisites

- Azure Function App (PowerShell 7.4, v4 runtime)
- System-assigned managed identity enabled
- Role assignments granted per the permissions table above

### Deploy

```bash
# Using Azure Functions Core Tools
func azure functionapp publish <FunctionAppName>

# Or via az CLI
az functionapp deployment source config-zip \
  --resource-group <RG> \
  --name <FunctionAppName> \
  --src <zip-file>
```

### Local Development

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

## Standalone Usage

The module can be used independently outside the Function App:

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

## Schedule

Default: daily at 6:00 AM UTC (`0 0 6 * * *`). Modify in `TimerTriggerOrphanedRoles/function.json`.

## Architecture

```
├── host.json                              # Function App host config
├── requirements.psd1                      # Az module dependencies
├── profile.ps1                            # Managed identity auth
├── local.settings.json.sample             # Template for local dev settings
├── sample-report.json                     # Example scan report (sanitized)
├── .funcignore                            # Files excluded from func publish
├── modules/
│   └── OrphanedRoleAssignments.psm1       # Core logic (reusable module)
├── scripts/
│   └── test-scan.ps1                      # Local dry-run harness
└── TimerTriggerOrphanedRoles/
    ├── function.json                      # Timer trigger binding
    └── run.ps1                            # Function entry point
```

## Contributing

Issues and PRs are welcome. When opening a PR:

- Keep the module (`modules/OrphanedRoleAssignments.psm1`) free of Function-runtime-specific code so it stays reusable as a standalone PowerShell module.
- Do not commit `local.settings.json` or any scan output containing real subscription, tenant, or principal IDs — these are already excluded via `.gitignore`.
- Run `scripts/test-scan.ps1` against a dev subscription before submitting changes that touch detection logic.

## Disclaimer

This project is provided as-is, with no warranty. Cleanup of role assignments is irreversible — always run with `ENABLE_ROLE_ASSIGNMENT_CLEANUP=false` first and review the JSON report before enabling deletion.
