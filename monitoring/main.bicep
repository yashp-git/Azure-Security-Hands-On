targetScope = 'resourceGroup'

@description('Resource naming prefix')
param prefix string = 'clickapp'

@description('Azure region for Application Insights')
param location string = 'eastus2'

@description('Existing Log Analytics workspace name (created by Module 3)')
param logAnalyticsWorkspaceName string

@description('Existing Function App name')
param functionAppName string

@description('Existing Storage Account name used by the Function App')
param storageAccountName string

@description('Existing SQL Server name')
param sqlServerName string

@description('Existing SQL Database name')
param sqlDatabaseName string

@description('Existing SQL Server FQDN')
param sqlServerFqdn string

@description('Existing Static Web App name')
param swaName string

@description('Existing App Service Plan name')
param appServicePlanName string

@description('Whether Function App has VNet integration (Module 2 deployed)')
param vnetIntegrated bool = false

@description('VNet name from Module 2 — leave empty if Module 2 not deployed')
param vnetName string = ''

@description('Web-API NSG name from Module 2 — leave empty if Module 2 not deployed')
param webApiNsgName string = ''

@description('API-SQL NSG name from Module 2 — leave empty if Module 2 not deployed')
param apiSqlNsgName string = ''

@description('Front Door profile name from Module 3 — leave empty if Module 3 not deployed')
param frontDoorName string = ''

// Reference the shared Log Analytics workspace created by Module 3
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

// 1. Application Insights — workspace-based, shared by Function App and SWA frontend
module appInsights 'modules/app-insights.bicep' = {
  name: 'app-insights-deployment'
  params: {
    prefix: prefix
    location: location
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// 2. Function App — inject App Insights settings + diagnostic settings
module functionAppMonitoring 'modules/function-app-monitoring.bicep' = {
  name: 'function-app-monitoring-deployment'
  params: {
    functionAppName: functionAppName
    storageAccountName: storageAccountName
    sqlServerFqdn: sqlServerFqdn
    sqlDatabaseName: sqlDatabaseName
    appInsightsConnectionString: appInsights.outputs.connectionString
    appInsightsInstrumentationKey: appInsights.outputs.instrumentationKey
    logAnalyticsWorkspaceId: logAnalytics.id
    vnetIntegrated: vnetIntegrated
  }
}

// 3. SQL Server audit logging + SQL Database diagnostic settings
module sqlAuditing 'modules/sql-auditing.bicep' = {
  name: 'sql-auditing-deployment'
  params: {
    sqlServerName: sqlServerName
    sqlDatabaseName: sqlDatabaseName
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// 4. Remaining required resources: Storage Account, App Service Plan, Static Web App
module resourceDiagnostics 'modules/resource-diagnostics.bicep' = {
  name: 'resource-diagnostics-deployment'
  params: {
    storageAccountName: storageAccountName
    appServicePlanName: appServicePlanName
    swaName: swaName
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// 5. Module 2 optional — VNet + NSG diagnostic settings (only when Module 2 is deployed)
module module2Diagnostics 'modules/module2-diagnostics.bicep' = if (!empty(vnetName)) {
  name: 'module2-diagnostics-deployment'
  params: {
    vnetName: vnetName
    webApiNsgName: webApiNsgName
    apiSqlNsgName: apiSqlNsgName
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// 6. Module 3 optional — replace Front Door's ad-hoc diagnostic setting with standardised name
module frontDoorDiagnostics 'modules/frontdoor-diagnostics.bicep' = if (!empty(frontDoorName)) {
  name: 'frontdoor-diagnostics-deployment'
  params: {
    frontDoorName: frontDoorName
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// Outputs
output appInsightsName string = appInsights.outputs.appInsightsName
output appInsightsConnectionString string = appInsights.outputs.connectionString
output appInsightsInstrumentationKey string = appInsights.outputs.instrumentationKey
output logAnalyticsWorkspaceName string = logAnalytics.name
