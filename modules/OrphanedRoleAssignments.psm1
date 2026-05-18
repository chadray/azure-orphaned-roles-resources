<#
.SYNOPSIS
    Finds and optionally removes orphaned Azure role assignments.

.DESCRIPTION
    Detects two types of orphaned role assignments:
    1. Orphaned Principal  - The Entra ID principal (user, group, SP, managed identity) was deleted.
    2. Orphaned Scope      - The Azure resource referenced by the assignment scope no longer exists.

    Supports dry-run (default) and live cleanup modes with granular controls.
#>

# ──────────────────────────────────────────────────────────────────────
#  SCOPE VALIDATION
# ──────────────────────────────────────────────────────────────────────

function Test-ScopeExists {
    <#
    .SYNOPSIS
        Validates whether an Azure scope (management group, subscription, resource group, or resource) exists.
    .OUTPUTS
        [string] - "Exists", "NotFound", or "Unknown"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [hashtable]$Cache = @{}
    )

    if ($Cache.ContainsKey($Scope)) { return $Cache[$Scope] }

    $result = 'Unknown'

    try {
        switch -Regex ($Scope) {
            # Root scope — always exists
            '^/$' {
                $result = 'Exists'
            }

            # Management group
            '^/providers/Microsoft\.Management/managementGroups/([^/]+)$' {
                $mgName = $Matches[1]
                try {
                    $mg = Get-AzManagementGroup -GroupName $mgName -ErrorAction Stop
                    $result = if ($mg) { 'Exists' } else { 'NotFound' }
                }
                catch {
                    if ($_.Exception.Message -match '(NotFound|404|does not exist)') {
                        $result = 'NotFound'
                    }
                    else { $result = 'Unknown' }
                }
            }

            # Subscription only
            '^/subscriptions/([0-9a-fA-F\-]{36})$' {
                $subId = $Matches[1]
                try {
                    $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                    $result = if ($sub) { 'Exists' } else { 'NotFound' }
                }
                catch {
                    if ($_.Exception.Message -match '(NotFound|404|SubscriptionNotFound|was not found)') {
                        $result = 'NotFound'
                    }
                    else { $result = 'Unknown' }
                }
            }

            # Resource group
            '^/subscriptions/([0-9a-fA-F\-]{36})/resourceGroups/([^/]+)$' {
                $subId = $Matches[1]
                $rgName = $Matches[2]
                try {
                    Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
                    $rg = Get-AzResourceGroup -Name $rgName -ErrorAction Stop
                    $result = if ($rg) { 'Exists' } else { 'NotFound' }
                }
                catch {
                    if ($_.Exception.Message -match '(NotFound|404|ResourceGroupNotFound|does not exist)') {
                        $result = 'NotFound'
                    }
                    else { $result = 'Unknown' }
                }
            }

            # Individual resource
            '^/subscriptions/([0-9a-fA-F\-]{36})/resourceGroups/([^/]+)/providers/.+' {
                $subId = $Matches[1]
                try {
                    Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
                    $res = Get-AzResource -ResourceId $Scope -ErrorAction Stop
                    $result = if ($res) { 'Exists' } else { 'NotFound' }
                }
                catch {
                    if ($_.Exception.Message -match '(NotFound|404|ResourceNotFound|does not exist)') {
                        $result = 'NotFound'
                    }
                    else { $result = 'Unknown' }
                }
            }

            default {
                $result = 'Unknown'
            }
        }
    }
    catch {
        Write-Warning "Scope validation error for '$Scope': $_"
        $result = 'Unknown'
    }

    $Cache[$Scope] = $result
    return $result
}

# ──────────────────────────────────────────────────────────────────────
#  PRINCIPAL VALIDATION
# ──────────────────────────────────────────────────────────────────────

function Test-PrincipalExists {
    <#
    .SYNOPSIS
        Confirms whether an Entra ID principal exists by attempting lookups across object types.
    .OUTPUTS
        [string] - "Exists", "NotFound", or "Unknown"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ObjectId,
        [hashtable]$Cache = @{}
    )

    if ($Cache.ContainsKey($ObjectId)) { return $Cache[$ObjectId] }

    $result = 'Unknown'
    $lookups = @(
        { Get-AzADServicePrincipal -ObjectId $ObjectId -ErrorAction Stop },
        { Get-AzADUser -ObjectId $ObjectId -ErrorAction Stop },
        { Get-AzADGroup -ObjectId $ObjectId -ErrorAction Stop }
    )

    $notFoundCount = 0
    foreach ($lookup in $lookups) {
        try {
            $obj = & $lookup
            if ($obj) {
                $result = 'Exists'
                break
            }
            else {
                $notFoundCount++
            }
        }
        catch {
            if ($_.Exception.Message -match '(does not exist|Request_ResourceNotFound|404|Not Found)') {
                $notFoundCount++
            }
            else {
                # Permission or transient error — don't assume deleted
                Write-Verbose "Principal lookup error for $ObjectId : $_"
            }
        }
    }

    if ($result -ne 'Exists' -and $notFoundCount -eq $lookups.Count) {
        $result = 'NotFound'
    }

    $Cache[$ObjectId] = $result
    return $result
}

# ──────────────────────────────────────────────────────────────────────
#  FIND ORPHANED ROLE ASSIGNMENTS
# ──────────────────────────────────────────────────────────────────────

function Find-OrphanedRoleAssignments {
    <#
    .SYNOPSIS
        Scans Azure role assignments and returns those that are orphaned.

    .PARAMETER Scope
        The Azure scope to scan. Defaults to "/" (all accessible scopes).

    .PARAMETER IncludeOrphanedPrincipals
        Detect assignments where the Entra ID principal no longer exists. Default: $true.

    .PARAMETER IncludeOrphanedScopes
        Detect assignments where the scoped resource no longer exists. Default: $true.

    .PARAMETER ConfirmPrincipalDeletion
        When true, performs secondary Entra ID lookups to confirm principal deletion beyond
        the "Unknown" ObjectType signal. Default: $true.

    .OUTPUTS
        Array of [PSCustomObject] with orphaned assignment details.
    #>
    [CmdletBinding()]
    param(
        [string]$Scope = '/',
        [bool]$IncludeOrphanedPrincipals = $true,
        [bool]$IncludeOrphanedScopes = $true,
        [bool]$ConfirmPrincipalDeletion = $true
    )

    $scopeCache = @{}
    $principalCache = @{}
    $orphaned = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Information "Fetching role assignments at scope '$Scope'..." -InformationAction Continue

    try {
        $assignments = Get-AzRoleAssignment -Scope $Scope -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to retrieve role assignments: $_"
        return @()
    }

    $totalCount = ($assignments | Measure-Object).Count
    Write-Information "Found $totalCount role assignments. Scanning for orphans..." -InformationAction Continue

    $counter = 0
    foreach ($ra in $assignments) {
        $counter++
        if ($counter % 50 -eq 0) {
            Write-Information "  Processing $counter / $totalCount..." -InformationAction Continue
        }

        $orphanReasons = [System.Collections.Generic.List[string]]::new()
        $detectionStatus = 'Confirmed'
        $validationNotes = ''

        # ── Check for orphaned principal ──
        if ($IncludeOrphanedPrincipals -and $ra.ObjectType -eq 'Unknown') {
            if ($ConfirmPrincipalDeletion) {
                $principalStatus = Test-PrincipalExists -ObjectId $ra.ObjectId -Cache $principalCache

                switch ($principalStatus) {
                    'NotFound' {
                        $orphanReasons.Add('OrphanedPrincipal')
                        $detectionStatus = 'Confirmed'
                    }
                    'Exists' {
                        # False positive — ObjectType was Unknown but principal exists (permission issue)
                        $validationNotes = 'ObjectType was Unknown but principal still exists in Entra ID'
                    }
                    'Unknown' {
                        $orphanReasons.Add('OrphanedPrincipal')
                        $detectionStatus = 'Suspected'
                        $validationNotes = 'Could not confirm principal deletion — lookup returned ambiguous result'
                    }
                }
            }
            else {
                $orphanReasons.Add('OrphanedPrincipal')
                $detectionStatus = 'Confirmed'
            }
        }

        # ── Check for orphaned scope ──
        if ($IncludeOrphanedScopes) {
            $scopeStatus = Test-ScopeExists -Scope $ra.Scope -Cache $scopeCache

            switch ($scopeStatus) {
                'NotFound' {
                    $orphanReasons.Add('OrphanedScope')
                }
                'Unknown' {
                    # Don't flag as orphaned if we can't confirm
                    if ($validationNotes) { $validationNotes += '; ' }
                    $validationNotes += "Scope validation inconclusive for '$($ra.Scope)'"
                }
            }
        }

        # ── Record if orphaned ──
        if ($orphanReasons.Count -gt 0) {
            $canSafelyDelete = ($detectionStatus -eq 'Confirmed')

            $orphaned.Add([PSCustomObject]@{
                RoleAssignmentId   = $ra.RoleAssignmentId
                RoleDefinitionName = $ra.RoleDefinitionName
                RoleDefinitionId   = $ra.RoleDefinitionId
                PrincipalId        = $ra.ObjectId
                PrincipalType      = $ra.ObjectType
                DisplayName        = $ra.DisplayName
                SignInName         = $ra.SignInName
                Scope              = $ra.Scope
                OrphanReasons      = ($orphanReasons -join ', ')
                DetectionStatus    = $detectionStatus
                CanSafelyDelete    = $canSafelyDelete
                ValidationNotes    = $validationNotes
                ScannedAt          = (Get-Date -Format 'o')
            })
        }
    }

    Write-Information "Scan complete. Found $($orphaned.Count) orphaned assignments out of $totalCount total." -InformationAction Continue
    return $orphaned
}

# ──────────────────────────────────────────────────────────────────────
#  REMOVE ORPHANED ROLE ASSIGNMENTS
# ──────────────────────────────────────────────────────────────────────

function Remove-OrphanedRoleAssignments {
    <#
    .SYNOPSIS
        Removes orphaned role assignments. Runs in DryRun mode by default.

    .PARAMETER OrphanedAssignments
        Array of orphaned assignment objects from Find-OrphanedRoleAssignments.

    .PARAMETER DryRun
        When true (default), simulates removal without making changes.

    .PARAMETER OnlyConfirmed
        When true (default), only deletes assignments with DetectionStatus = "Confirmed".

    .PARAMETER CleanupPrincipals
        Allow cleanup of orphaned-principal assignments. Default: $false.

    .PARAMETER CleanupScopes
        Allow cleanup of orphaned-scope assignments. Default: $false.

    .OUTPUTS
        Array of [PSCustomObject] with action results for each assignment.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$OrphanedAssignments,

        [bool]$DryRun = $true,
        [bool]$OnlyConfirmed = $true,
        [bool]$CleanupPrincipals = $false,
        [bool]$CleanupScopes = $false
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($oa in $OrphanedAssignments) {
        $action = 'Skipped'
        $reason = ''

        # Determine if this assignment is eligible for cleanup
        $reasons = $oa.OrphanReasons -split ',\s*'
        $eligible = $false

        if ($CleanupPrincipals -and $reasons -contains 'OrphanedPrincipal') { $eligible = $true }
        if ($CleanupScopes -and $reasons -contains 'OrphanedScope') { $eligible = $true }

        if (-not $eligible) {
            $action = 'Skipped'
            $reason = "Cleanup not enabled for reason(s): $($oa.OrphanReasons)"
        }
        elseif ($OnlyConfirmed -and $oa.DetectionStatus -ne 'Confirmed') {
            $action = 'Skipped'
            $reason = "DetectionStatus is '$($oa.DetectionStatus)', not Confirmed"
        }
        elseif (-not $oa.CanSafelyDelete) {
            $action = 'Skipped'
            $reason = 'CanSafelyDelete is false'
        }
        elseif ($DryRun) {
            $action = 'WouldDelete'
            $reason = 'DryRun mode — no changes made'
        }
        else {
            # Live deletion
            try {
                Remove-AzRoleAssignment -RoleAssignmentId $oa.RoleAssignmentId -ErrorAction Stop
                $action = 'Deleted'
                $reason = 'Successfully removed'
            }
            catch {
                $action = 'Failed'
                $reason = "Deletion failed: $_"
            }
        }

        $results.Add([PSCustomObject]@{
            RoleAssignmentId   = $oa.RoleAssignmentId
            RoleDefinitionName = $oa.RoleDefinitionName
            PrincipalId        = $oa.PrincipalId
            Scope              = $oa.Scope
            OrphanReasons      = $oa.OrphanReasons
            DetectionStatus    = $oa.DetectionStatus
            Action             = $action
            ActionReason       = $reason
            ProcessedAt        = (Get-Date -Format 'o')
        })

        $logLevel = switch ($action) {
            'Deleted'     { 'Warning' }
            'Failed'      { 'Error' }
            'WouldDelete' { 'Information' }
            default       { 'Verbose' }
        }

        $msg = "[$action] $($oa.RoleAssignmentId) | Role=$($oa.RoleDefinitionName) | Principal=$($oa.PrincipalId) | Scope=$($oa.Scope) | $reason"
        switch ($logLevel) {
            'Error'       { Write-Error $msg }
            'Warning'     { Write-Warning $msg }
            'Information' { Write-Information $msg -InformationAction Continue }
            default       { Write-Verbose $msg }
        }
    }

    return $results
}

# ──────────────────────────────────────────────────────────────────────
#  REPORT GENERATION
# ──────────────────────────────────────────────────────────────────────

function New-OrphanedRoleReport {
    <#
    .SYNOPSIS
        Generates a structured report from scan and cleanup results.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$OrphanedAssignments,
        [PSCustomObject[]]$CleanupResults = @(),
        [string]$ScanScope = '/',
        [bool]$DryRun = $true
    )

    $report = [PSCustomObject]@{
        ReportMetadata = [PSCustomObject]@{
            GeneratedAt    = (Get-Date -Format 'o')
            ScanScope      = $ScanScope
            DryRunMode     = $DryRun
            TotalOrphaned  = ($OrphanedAssignments | Measure-Object).Count
            OrphanedByType = [PSCustomObject]@{
                OrphanedPrincipal = ($OrphanedAssignments | Where-Object { $_.OrphanReasons -match 'OrphanedPrincipal' } | Measure-Object).Count
                OrphanedScope     = ($OrphanedAssignments | Where-Object { $_.OrphanReasons -match 'OrphanedScope' } | Measure-Object).Count
            }
            DetectionStatusBreakdown = [PSCustomObject]@{
                Confirmed = ($OrphanedAssignments | Where-Object { $_.DetectionStatus -eq 'Confirmed' } | Measure-Object).Count
                Suspected = ($OrphanedAssignments | Where-Object { $_.DetectionStatus -eq 'Suspected' } | Measure-Object).Count
            }
        }
        OrphanedAssignments = $OrphanedAssignments
        CleanupResults      = $CleanupResults
    }

    if ($CleanupResults.Count -gt 0) {
        $report.ReportMetadata | Add-Member -NotePropertyName 'CleanupSummary' -NotePropertyValue ([PSCustomObject]@{
            Deleted     = ($CleanupResults | Where-Object { $_.Action -eq 'Deleted' } | Measure-Object).Count
            WouldDelete = ($CleanupResults | Where-Object { $_.Action -eq 'WouldDelete' } | Measure-Object).Count
            Skipped     = ($CleanupResults | Where-Object { $_.Action -eq 'Skipped' } | Measure-Object).Count
            Failed      = ($CleanupResults | Where-Object { $_.Action -eq 'Failed' } | Measure-Object).Count
        })
    }

    return $report
}

Export-ModuleMember -Function Find-OrphanedRoleAssignments,
                              Remove-OrphanedRoleAssignments,
                              New-OrphanedRoleReport,
                              Test-ScopeExists,
                              Test-PrincipalExists
