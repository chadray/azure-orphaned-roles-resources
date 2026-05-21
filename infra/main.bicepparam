using './main.bicep'

// Required — set to your target subscription scope
param scanScope = '/subscriptions/<your-subscription-id>'

// Optional overrides (defaults are fine for most deployments)
// param baseName = 'orphroles'
// param location = '<region>'            // defaults to resource group location
// param enableCleanup = false
// param cleanupPrincipals = false
// param cleanupScopes = false
// param reportBlobContainer = 'orphaned-role-reports'
// param deployWorkbook = true
