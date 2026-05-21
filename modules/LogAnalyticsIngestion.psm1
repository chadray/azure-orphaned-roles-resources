<#
.SYNOPSIS
    Sends orphaned role assignment scan results to Azure Monitor via the Logs Ingestion API.

.DESCRIPTION
    Uses the Data Collection Rule (DCR) / Data Collection Endpoint (DCE) based Logs Ingestion API
    with managed identity authentication. No shared keys required.

    Ingests two record types:
    - Scan summary (one per run, including zero-result runs)
    - Orphaned assignment details (one per orphaned assignment)
#>

function Send-OrphanedRolesToLogAnalytics {
    <#
    .SYNOPSIS
        Sends orphaned role assignment data to a Log Analytics custom table via Logs Ingestion API.

    .PARAMETER DceUri
        The Data Collection Endpoint ingestion URI (e.g., https://<dce-name>.<region>.ingest.monitor.azure.com).

    .PARAMETER DcrImmutableId
        The immutable ID of the Data Collection Rule (e.g., dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx).

    .PARAMETER StreamName
        The stream name defined in the DCR (e.g., Custom-OrphanedRoleAssignments_CL).

    .PARAMETER Assignments
        Array of orphaned assignment objects from Find-OrphanedRoleAssignments.

    .PARAMETER ScanScope
        The scope that was scanned.

    .PARAMETER DryRun
        Whether the scan was a dry-run.

    .PARAMETER ScanId
        Unique identifier for this scan run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DceUri,
        [Parameter(Mandatory)][string]$DcrImmutableId,
        [Parameter(Mandatory)][string]$StreamName,
        [Parameter(Mandatory)][string]$SummaryStreamName,
        [PSCustomObject[]]$Assignments = @(),
        [string]$ScanScope = '/',
        [bool]$DryRun = $true,
        [string]$ScanId = [guid]::NewGuid().ToString()
    )

    $token = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com' -ErrorAction Stop).Token

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $baseUri = $DceUri.TrimEnd('/')
    $apiVersion = '2023-01-01'
    $timestamp = Get-Date -Format 'o'

    # ── Ingest scan summary (every run, even zero results) ──
    $summary = @(
        @{
            TimeGenerated  = $timestamp
            ScanId         = $ScanId
            ScanScope      = $ScanScope
            DryRunMode     = $DryRun
            TotalOrphaned  = ($Assignments | Measure-Object).Count
            OrphanedPrincipalCount = ($Assignments | Where-Object { $_.OrphanReasons -match 'OrphanedPrincipal' } | Measure-Object).Count
            OrphanedScopeCount     = ($Assignments | Where-Object { $_.OrphanReasons -match 'OrphanedScope' } | Measure-Object).Count
            ConfirmedCount = ($Assignments | Where-Object { $_.DetectionStatus -eq 'Confirmed' } | Measure-Object).Count
            SuspectedCount = ($Assignments | Where-Object { $_.DetectionStatus -eq 'Suspected' } | Measure-Object).Count
        }
    )

    $summaryUri = "$baseUri/dataCollectionRules/$DcrImmutableId/streams/${SummaryStreamName}?api-version=$apiVersion"
    $summaryBody = $summary | ConvertTo-Json -AsArray -Depth 5

    try {
        Invoke-RestMethod -Uri $summaryUri -Method Post -Headers $headers -Body $summaryBody -ErrorAction Stop | Out-Null
        Write-Information "Ingested scan summary (ScanId=$ScanId, Total=$($summary[0].TotalOrphaned))" -InformationAction Continue
    }
    catch {
        Write-Warning "Failed to ingest scan summary: $_"
    }

    # ── Ingest assignment details (only when there are results) ──
    if ($Assignments.Count -eq 0) {
        Write-Information "No orphaned assignments to ingest." -InformationAction Continue
        return
    }

    $records = foreach ($a in $Assignments) {
        @{
            TimeGenerated      = $timestamp
            ScanId             = $ScanId
            ScanScope          = $ScanScope
            RoleAssignmentId   = $a.RoleAssignmentId
            RoleDefinitionName = $a.RoleDefinitionName
            RoleDefinitionId   = $a.RoleDefinitionId
            PrincipalId        = $a.PrincipalId
            PrincipalType      = $a.PrincipalType
            DisplayName        = $a.DisplayName
            SignInName         = $a.SignInName
            Scope              = $a.Scope
            OrphanReasons      = $a.OrphanReasons
            DetectionStatus    = $a.DetectionStatus
            CanSafelyDelete    = $a.CanSafelyDelete
            ValidationNotes    = $a.ValidationNotes
            ScannedAt          = $a.ScannedAt
        }
    }

    $detailUri = "$baseUri/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=$apiVersion"

    # Batch in chunks of 500 to avoid payload limits
    $batchSize = 500
    for ($i = 0; $i -lt $records.Count; $i += $batchSize) {
        $batch = @($records[$i..([Math]::Min($i + $batchSize - 1, $records.Count - 1))])
        $body = $batch | ConvertTo-Json -AsArray -Depth 5

        try {
            Invoke-RestMethod -Uri $detailUri -Method Post -Headers $headers -Body $body -ErrorAction Stop | Out-Null
            Write-Information "Ingested batch $([Math]::Floor($i / $batchSize) + 1): $($batch.Count) records" -InformationAction Continue
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $retryAfter = 30
                Write-Warning "Throttled. Retrying after ${retryAfter}s..."
                Start-Sleep -Seconds $retryAfter
                try {
                    Invoke-RestMethod -Uri $detailUri -Method Post -Headers $headers -Body $body -ErrorAction Stop | Out-Null
                    Write-Information "Retry succeeded for batch $([Math]::Floor($i / $batchSize) + 1)" -InformationAction Continue
                }
                catch {
                    Write-Warning "Retry failed for batch $([Math]::Floor($i / $batchSize) + 1): $_"
                }
            }
            else {
                Write-Warning "Failed to ingest batch $([Math]::Floor($i / $batchSize) + 1): $_"
            }
        }
    }

    Write-Information "Log Analytics ingestion complete (ScanId=$ScanId)" -InformationAction Continue
}

Export-ModuleMember -Function Send-OrphanedRolesToLogAnalytics
