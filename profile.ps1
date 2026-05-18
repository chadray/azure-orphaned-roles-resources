# Azure Functions profile.ps1
# Authenticate with the Function App's Managed Identity
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
}
