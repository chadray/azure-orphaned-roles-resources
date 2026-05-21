// ──────────────────────────────────────────────────────────────────────
//  Orphaned Role Assignment Scanner — Azure Infrastructure
// ──────────────────────────────────────────────────────────────────────
//  Deploys: Function App, Storage, Log Analytics, DCE, DCR, Workbook
//  Usage:
//    az deployment group create -g <rg> -f infra/main.bicep \
//      -p scanScope=/subscriptions/<sub-id>
// ──────────────────────────────────────────────────────────────────────

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────────────

@description('Base name for all resources. Keep short — suffixes are appended.')
@minLength(3)
@maxLength(16)
param baseName string = 'orphroles'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Azure scope to scan for orphaned role assignments.')
param scanScope string = '/'

@description('Enable automatic cleanup of orphaned assignments.')
param enableCleanup bool = false

@description('Allow cleanup of orphaned-principal assignments.')
param cleanupPrincipals bool = false

@description('Allow cleanup of orphaned-scope assignments.')
param cleanupScopes bool = false

@description('Blob container name for report output.')
param reportBlobContainer string = 'orphaned-role-reports'

@description('App Service Plan SKU (use B1 if Consumption/Y1 quota is unavailable).')
@allowed(['Y1', 'B1', 'B2', 'S1'])
param appServicePlanSku string = 'B1'

@description('Deploy the Azure Monitor Workbook.')
param deployWorkbook bool = true

// ── Variables ───────────────────────────────────────────────────────

var suffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${take(baseName, 11)}${take(suffix, 13)}')
var functionAppName = '${baseName}-func-${take(suffix, 6)}'
var appServicePlanName = '${baseName}-plan-${take(suffix, 6)}'
var logAnalyticsName = '${baseName}-law-${take(suffix, 6)}'
var dceName = '${baseName}-dce-${take(suffix, 6)}'
var dcrName = '${baseName}-dcr-${take(suffix, 6)}'
var appInsightsName = '${baseName}-ai-${take(suffix, 6)}'

var assignmentsTableName = 'OrphanedRoleAssignments_CL'
var summaryTableName = 'OrphanedRoleScanSummary_CL'
var assignmentsStreamName = 'Custom-${assignmentsTableName}'
var summaryStreamName = 'Custom-${summaryTableName}'

// ── Storage Account ─────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource reportContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: reportBlobContainer
}

// ── Log Analytics Workspace ─────────────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// Custom table: OrphanedRoleAssignments_CL
resource assignmentsTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalytics
  name: assignmentsTableName
  properties: {
    schema: {
      name: assignmentsTableName
      columns: [
        { name: 'TimeGenerated', type: 'dateTime', description: 'Ingestion timestamp' }
        { name: 'ScanId', type: 'string', description: 'Unique scan run identifier' }
        { name: 'ScanScope', type: 'string', description: 'Azure scope that was scanned' }
        { name: 'RoleAssignmentId', type: 'string', description: 'Full ARM resource ID of the role assignment' }
        { name: 'RoleDefinitionName', type: 'string', description: 'Name of the assigned role (e.g. Reader, Contributor)' }
        { name: 'RoleDefinitionId', type: 'string', description: 'GUID of the role definition' }
        { name: 'PrincipalId', type: 'string', description: 'Object ID of the assigned principal' }
        { name: 'PrincipalType', type: 'string', description: 'Type of principal (Unknown, ServicePrincipal, User, Group)' }
        { name: 'DisplayName', type: 'string', description: 'Display name of the principal (if available)' }
        { name: 'SignInName', type: 'string', description: 'Sign-in name / UPN (if available)' }
        { name: 'Scope', type: 'string', description: 'Azure scope of the assignment' }
        { name: 'OrphanReasons', type: 'string', description: 'Reason(s) for orphan detection' }
        { name: 'DetectionStatus', type: 'string', description: 'Confirmed or Suspected' }
        { name: 'CanSafelyDelete', type: 'boolean', description: 'Whether the assignment can be safely removed' }
        { name: 'ValidationNotes', type: 'string', description: 'Additional validation context' }
        { name: 'ScannedAt', type: 'string', description: 'ISO 8601 timestamp of the scan' }
      ]
    }
    retentionInDays: 30
    plan: 'Analytics'
  }
}

// Custom table: OrphanedRoleScanSummary_CL
resource summaryTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalytics
  name: summaryTableName
  properties: {
    schema: {
      name: summaryTableName
      columns: [
        { name: 'TimeGenerated', type: 'dateTime', description: 'Ingestion timestamp' }
        { name: 'ScanId', type: 'string', description: 'Unique scan run identifier' }
        { name: 'ScanScope', type: 'string', description: 'Azure scope that was scanned' }
        { name: 'DryRunMode', type: 'boolean', description: 'Whether the scan was a dry run' }
        { name: 'TotalOrphaned', type: 'long', description: 'Total orphaned assignments found' }
        { name: 'OrphanedPrincipalCount', type: 'long', description: 'Count of orphaned-principal assignments' }
        { name: 'OrphanedScopeCount', type: 'long', description: 'Count of orphaned-scope assignments' }
        { name: 'ConfirmedCount', type: 'long', description: 'Count of confirmed orphans' }
        { name: 'SuspectedCount', type: 'long', description: 'Count of suspected orphans' }
      ]
    }
    retentionInDays: 30
    plan: 'Analytics'
  }
}

// ── Application Insights ────────────────────────────────────────────

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ── Data Collection Endpoint ────────────────────────────────────────

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ── Data Collection Rule ────────────────────────────────────────────

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${assignmentsStreamName}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'ScanId', type: 'string' }
          { name: 'ScanScope', type: 'string' }
          { name: 'RoleAssignmentId', type: 'string' }
          { name: 'RoleDefinitionName', type: 'string' }
          { name: 'RoleDefinitionId', type: 'string' }
          { name: 'PrincipalId', type: 'string' }
          { name: 'PrincipalType', type: 'string' }
          { name: 'DisplayName', type: 'string' }
          { name: 'SignInName', type: 'string' }
          { name: 'Scope', type: 'string' }
          { name: 'OrphanReasons', type: 'string' }
          { name: 'DetectionStatus', type: 'string' }
          { name: 'CanSafelyDelete', type: 'boolean' }
          { name: 'ValidationNotes', type: 'string' }
          { name: 'ScannedAt', type: 'string' }
        ]
      }
      '${summaryStreamName}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'ScanId', type: 'string' }
          { name: 'ScanScope', type: 'string' }
          { name: 'DryRunMode', type: 'boolean' }
          { name: 'TotalOrphaned', type: 'long' }
          { name: 'OrphanedPrincipalCount', type: 'long' }
          { name: 'OrphanedScopeCount', type: 'long' }
          { name: 'ConfirmedCount', type: 'long' }
          { name: 'SuspectedCount', type: 'long' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalytics.id
          name: 'law-destination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ assignmentsStreamName ]
        destinations: [ 'law-destination' ]
        transformKql: 'source'
        outputStream: assignmentsStreamName
      }
      {
        streams: [ summaryStreamName ]
        destinations: [ 'law-destination' ]
        transformKql: 'source'
        outputStream: summaryStreamName
      }
    ]
  }
  dependsOn: [ assignmentsTable, summaryTable ]
}

// ── App Service Plan (Consumption) ──────────────────────────────────

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSku
    tier: appServicePlanSku == 'Y1' ? 'Dynamic' : (startsWith(appServicePlanSku, 'S') ? 'Standard' : 'Basic')
  }
  properties: {
    reserved: false
  }
}

// ── Function App ────────────────────────────────────────────────────

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.4' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // Scanner settings
        { name: 'ORPHANED_ROLES_SCAN_SCOPE', value: scanScope }
        { name: 'ENABLE_ROLE_ASSIGNMENT_CLEANUP', value: enableCleanup ? 'true' : 'false' }
        { name: 'CLEANUP_ORPHANED_PRINCIPALS', value: cleanupPrincipals ? 'true' : 'false' }
        { name: 'CLEANUP_ORPHANED_SCOPES', value: cleanupScopes ? 'true' : 'false' }
        { name: 'REPORT_OUTPUT_BLOB_CONTAINER', value: reportBlobContainer }
        // Log Analytics ingestion
        { name: 'LOG_INGESTION_DCE_URI', value: dce.properties.logsIngestion.endpoint }
        { name: 'LOG_INGESTION_DCR_IMMUTABLE_ID', value: dcr.properties.immutableId }
        { name: 'LOG_INGESTION_STREAM_NAME', value: assignmentsStreamName }
        { name: 'LOG_INGESTION_SUMMARY_STREAM_NAME', value: summaryStreamName }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
}

// ── Role Assignments ────────────────────────────────────────────────

// Monitoring Metrics Publisher on DCR (required for Logs Ingestion API)
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, functionApp.id, monitoringMetricsPublisher)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Workbook ────────────────────────────────────────────────────────
// NOTE: The workbook JSON exceeds Bicep's loadTextContent() limit (131KB).
// It is deployed separately via the deploy.sh script using Azure CLI.

// ── Outputs ─────────────────────────────────────────────────────────

@description('Function App name (use with func azure functionapp publish)')
output functionAppName string = functionApp.name

@description('Function App managed identity principal ID')
output functionAppPrincipalId string = functionApp.identity.principalId

@description('Log Analytics Workspace ID')
output logAnalyticsWorkspaceId string = logAnalytics.properties.customerId

@description('Data Collection Endpoint URI')
output dceUri string = dce.properties.logsIngestion.endpoint

@description('Data Collection Rule immutable ID')
output dcrImmutableId string = dcr.properties.immutableId

@description('Workbook resource ID')
output workbookId string = 'deployed-via-cli'

@description('Storage Account name')
output storageAccountName string = storageAccount.name
