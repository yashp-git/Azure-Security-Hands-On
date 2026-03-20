@description('Azure region for all resources')
param location string

@description('Existing Function App name')
param functionAppName string

@description('Existing App Service Plan name')
param appServicePlanName string

@description('Existing Storage Account name used by the Function App')
param storageAccountName string

@description('API subnet resource ID for VNet integration')
param apiSubnetId string

@description('SQL Server FQDN (private endpoint)')
param sqlServerFqdn string

@description('SQL Database name')
param sqlDatabaseName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource appServicePlanUpgrade 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    family: 'EP'
    size: 'EP1'
  }
  properties: {
    reserved: false
    maximumElasticWorkerCount: 20
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: functionAppName
}

resource networkConfig 'Microsoft.Web/sites/networkConfig@2023-12-01' = {
  parent: functionApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: apiSubnetId
    swiftSupported: true
  }
  dependsOn: [
    appServicePlanUpgrade
  ]
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'

resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    AzureWebJobsStorage: storageConnectionString
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnectionString
    WEBSITE_CONTENTSHARE: toLower(functionAppName)
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: 'dotnet-isolated'
    WEBSITE_VNET_ROUTE_ALL: '1'
    WEBSITE_DNS_SERVER: '168.63.129.16'
    SqlConnectionString: 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
  }
  dependsOn: [
    networkConfig
  ]
}

output vnetIntegrationConfigured bool = true
