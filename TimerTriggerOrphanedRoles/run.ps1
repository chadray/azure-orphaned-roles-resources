<#
.SYNOPSIS
    Timer-triggered Azure Function that scans for orphaned role assignments.

.DESCRIPTION
    Runs on a schedule (default: daily at 6 AM UTC).
    Controlled via app settings:
      - ORPHANED_ROLES_SCAN_SCOPE        : Azure scope to scan (default "/")
      - ENABLE_ROLE_ASSIGNMENT_CLEANUP    : "true" to enable live deletion (default "false")
      - CLEANUP_ORPHANED_PRINCIPALS       : "true" to allow deleting orphaned-principal assignments
      - CLEANUP_ORPHANED_SCOPES           : "true" to allow deleting orphaned-scope assignments
      - REPORT_OUTPUT_BLOB_CONTAINER      : Blob container name for report output (optional)
#>

param($Timer)

Import-Module "$PSScriptRoot/../modules/OrphanedRoleAssignments.psm1" -Force
Import-Module "$PSScriptRoot/../modules/LogAnalyticsIngestion.psm1" -Force

# ── Read configuration from app settings ──
$scanScope          = if ($env:ORPHANED_ROLES_SCAN_SCOPE)     { $env:ORPHANED_ROLES_SCAN_SCOPE }     else { '/' }
$enableCleanup      = $env:ENABLE_ROLE_ASSIGNMENT_CLEANUP   -eq 'true'
$cleanupPrincipals  = $env:CLEANUP_ORPHANED_PRINCIPALS      -eq 'true'
$cleanupScopes      = $env:CLEANUP_ORPHANED_SCOPES          -eq 'true'
$dryRun             = -not $enableCleanup
$scanId             = [guid]::NewGuid().ToString()

# Log Analytics ingestion settings (optional — enables workbook dashboard)
$dceUri             = $env:LOG_INGESTION_DCE_URI
$dcrImmutableId     = $env:LOG_INGESTION_DCR_IMMUTABLE_ID
$streamName         = if ($env:LOG_INGESTION_STREAM_NAME)         { $env:LOG_INGESTION_STREAM_NAME }         else { 'Custom-OrphanedRoleAssignments_CL' }
$summaryStreamName  = if ($env:LOG_INGESTION_SUMMARY_STREAM_NAME) { $env:LOG_INGESTION_SUMMARY_STREAM_NAME } else { 'Custom-OrphanedRoleScanSummary_CL' }
$logAnalyticsEnabled = $dceUri -and $dcrImmutableId

Write-Information "=== Orphaned Role Assignment Scanner ===" -InformationAction Continue
Write-Information "Scan scope       : $scanScope" -InformationAction Continue
Write-Information "Cleanup enabled  : $enableCleanup" -InformationAction Continue
Write-Information "Cleanup principals: $cleanupPrincipals" -InformationAction Continue
Write-Information "Cleanup scopes   : $cleanupScopes" -InformationAction Continue
Write-Information "Dry-run mode     : $dryRun" -InformationAction Continue
Write-Information "Log Analytics    : $logAnalyticsEnabled" -InformationAction Continue
Write-Information "========================================" -InformationAction Continue

# ── Phase 1: Scan ──
$orphaned = Find-OrphanedRoleAssignments -Scope $scanScope

if ($orphaned.Count -eq 0) {
    Write-Information "No orphaned role assignments found." -InformationAction Continue

    # Still send summary to Log Analytics so the dashboard shows the latest scan
    if ($logAnalyticsEnabled) {
        try {
            Send-OrphanedRolesToLogAnalytics `
                -DceUri $dceUri `
                -DcrImmutableId $dcrImmutableId `
                -StreamName $streamName `
                -SummaryStreamName $summaryStreamName `
                -Assignments @() `
                -ScanScope $scanScope `
                -DryRun $dryRun `
                -ScanId $scanId
        }
        catch {
            Write-Warning "Log Analytics ingestion failed: $_"
        }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = '{"message":"No orphaned role assignments found."}' }) -ErrorAction SilentlyContinue
    return
}

# ── Phase 2: Cleanup (if enabled) ──
$cleanupResults = @()

if ($enableCleanup -and ($cleanupPrincipals -or $cleanupScopes)) {
    Write-Information "Running cleanup (DryRun=$dryRun)..." -InformationAction Continue

    $cleanupResults = Remove-OrphanedRoleAssignments `
        -OrphanedAssignments $orphaned `
        -DryRun $dryRun `
        -CleanupPrincipals $cleanupPrincipals `
        -CleanupScopes $cleanupScopes
}
else {
    Write-Information "Cleanup not enabled. Report-only mode." -InformationAction Continue
}

# ── Phase 3: Generate report ──
$report = New-OrphanedRoleReport `
    -OrphanedAssignments $orphaned `
    -CleanupResults $cleanupResults `
    -ScanScope $scanScope `
    -DryRun $dryRun

$reportJson = $report | ConvertTo-Json -Depth 10

# Log the full report
Write-Information "=== ORPHANED ROLE ASSIGNMENT REPORT ===" -InformationAction Continue
Write-Information $reportJson -InformationAction Continue

# Output summary to structured logs
$summary = $report.ReportMetadata
Write-Information ("SUMMARY: Total orphaned={0} | Principals={1} | Scopes={2} | Confirmed={3} | Suspected={4}" -f `
    $summary.TotalOrphaned,
    $summary.OrphanedByType.OrphanedPrincipal,
    $summary.OrphanedByType.OrphanedScope,
    $summary.DetectionStatusBreakdown.Confirmed,
    $summary.DetectionStatusBreakdown.Suspected
) -InformationAction Continue

# ── Optional: Write report to blob storage ──
$blobContainer = $env:REPORT_OUTPUT_BLOB_CONTAINER
$storageAccountName = $env:AzureWebJobsStorage__accountName
$storageConnStr = $env:AzureWebJobsStorage

if ($blobContainer) {
    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $blobName = "orphaned-roles-report_$timestamp.json"

        # Use managed identity if available, fall back to connection string
        if ($storageAccountName) {
            $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        }
        elseif ($storageConnStr -and $storageConnStr -ne 'UseDevelopmentStorage=true') {
            $ctx = New-AzStorageContext -ConnectionString $storageConnStr
        }
        else {
            $ctx = $null
        }

        if ($ctx) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            $reportJson | Out-File -FilePath $tempFile -Encoding UTF8

            Set-AzStorageBlobContent `
                -Container $blobContainer `
                -File $tempFile `
                -Blob $blobName `
                -Context $ctx `
                -Force | Out-Null

            Remove-Item $tempFile -Force
            Write-Information "Report written to blob: $blobContainer/$blobName" -InformationAction Continue
        }
    }
    catch {
        Write-Warning "Failed to write report to blob storage: $_"
    }
}

Write-Information "=== Scan complete ===" -InformationAction Continue

# ── Phase 4: Ingest to Log Analytics (if configured) ──
if ($logAnalyticsEnabled) {
    Write-Information "Sending results to Log Analytics..." -InformationAction Continue
    try {
        Send-OrphanedRolesToLogAnalytics `
            -DceUri $dceUri `
            -DcrImmutableId $dcrImmutableId `
            -StreamName $streamName `
            -SummaryStreamName $summaryStreamName `
            -Assignments $orphaned `
            -ScanScope $scanScope `
            -DryRun $dryRun `
            -ScanId $scanId
    }
    catch {
        Write-Warning "Log Analytics ingestion failed (scan results are still available in logs/blob): $_"
    }
}
