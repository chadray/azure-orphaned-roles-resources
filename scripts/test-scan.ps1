#requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Local test harness: dry-run scan of the current Az subscription.
.PARAMETER Scope
    Override the scan scope. Defaults to the current subscription.
#>
param(
    [string]$Scope
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules/OrphanedRoleAssignments.psm1') -Force

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }

if (-not $Scope) {
    $Scope = "/subscriptions/$($ctx.Subscription.Id)"
}

Write-Host "Account : $($ctx.Account.Id)" -ForegroundColor Cyan
Write-Host "Tenant  : $($ctx.Tenant.Id)"  -ForegroundColor Cyan
Write-Host "Scope   : $Scope"             -ForegroundColor Cyan
Write-Host ''

$orphaned = Find-OrphanedRoleAssignments -Scope $Scope -InformationAction Continue

Write-Host ''
Write-Host '=== ORPHANED ASSIGNMENTS ===' -ForegroundColor Yellow
if ($orphaned.Count -gt 0) {
    $orphaned |
    Select-Object RoleDefinitionName, PrincipalId, OrphanReasons, DetectionStatus, CanSafelyDelete, Scope |
    Format-Table -AutoSize -Wrap
}
else {
    Write-Host '(none found)' -ForegroundColor Green
}

$report = New-OrphanedRoleReport `
    -OrphanedAssignments $orphaned `
    -CleanupResults @() `
    -ScanScope $Scope `
    -DryRun $true

Write-Host ''
Write-Host '=== REPORT METADATA ===' -ForegroundColor Yellow
$report.ReportMetadata | Format-List

$outFile = Join-Path $root 'last-scan-report.json'
$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $outFile -Encoding UTF8
Write-Host "Full report written to: $outFile" -ForegroundColor Green
