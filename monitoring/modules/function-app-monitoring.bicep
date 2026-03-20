@description('Existing Function App name')
param functionAppName string

@description('Existing Storage Account name used by the Function App')
param storageAccountName string

@description('SQL Server FQDN for the connection string')
param sqlServerFqdn string

@description('SQL Database name')
param sqlDatabaseName string

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('Application Insights instrumentation key')
param appInsightsInstrumentationKey string

@description('Log Analytics workspace resource ID for diagnostic settings')
param logAnalyticsWorkspaceId string

@description('Whether Function App has VNet integration (Module 2 deployed)')
param vnetIntegrated bool = false

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: functionAppName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'

// Base app settings — all Module 1 settings plus Application Insights
var baseSettings = {
  AzureWebJobsStorage: storageConnectionString
  WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnectionString
  WEBSITE_CONTENTSHARE: toLower(functionAppName)
  FUNCTIONS_EXTENSION_VERSION: '~4'
  FUNCTIONS_WORKER_RUNTIME: 'dotnet-isolated'
  SqlConnectionString: 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
  APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
  APPINSIGHTS_INSTRUMENTATIONKEY: appInsightsInstrumentationKey
  ApplicationInsightsAgent_EXTENSION_VERSION: '~3'
}

// Additional settings required when VNet integration (Module 2) is deployed
var vnetSettings = {
  WEBSITE_VNET_ROUTE_ALL: '1'
  WEBSITE_DNS_SERVER: '168.63.129.16'
}

// Replace all app settings — ARM requires the full set to avoid losing existing values
resource appSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: vnetIntegrated ? union(baseSettings, vnetSettings) : baseSettings
}

// Diagnostic settings — send Function App logs and metrics to Log Analytics
resource functionAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Log-Send-To-Workspace'
  scope: functionApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
  dependsOn: [
    appSettings
  ]
}

output appSettingsDeployed bool = true
