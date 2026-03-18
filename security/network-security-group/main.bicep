targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Resource naming prefix')
param prefix string = 'clickapp'

@description('Existing SQL Server name')
param sqlServerName string

@description('Existing SQL Database name')
param sqlDatabaseName string

@description('Existing Function App name')
param functionAppName string

@description('Existing App Service Plan name')
param appServicePlanName string

@description('Location of the existing App Service Plan (may differ from VNet location)')
param appServicePlanLocation string

@description('Existing Storage Account name used by the Function App')
param storageAccountName string

// ──────────────────────────────────────────────────
// NSG 1: API-SQL — only allow API subnet to reach SQL on 1433
// ──────────────────────────────────────────────────
module apiSqlNsg 'modules/api-sql-nsg.bicep' = {
  name: 'api-sql-nsg-deployment'
  params: {
    location: location
    prefix: prefix
  }
}

// ──────────────────────────────────────────────────
// NSG 2: Web-API — allow HTTPS from internet, deny all else
// ──────────────────────────────────────────────────
module webApiNsg 'modules/web-api-nsg.bicep' = {
  name: 'web-api-nsg-deployment'
  params: {
    location: location
    prefix: prefix
  }
}

// ──────────────────────────────────────────────────
// VNet with subnets (depends on NSGs for association)
// ──────────────────────────────────────────────────
module vnet 'modules/vnet.bicep' = {
  name: 'vnet-deployment'
  params: {
    location: location
    prefix: prefix
    webApiNsgId: webApiNsg.outputs.nsgId
    apiSqlNsgId: apiSqlNsg.outputs.nsgId
  }
}

// ──────────────────────────────────────────────────
// SQL Private Endpoint (depends on VNet for subnet)
// ──────────────────────────────────────────────────
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' existing = {
  name: sqlServerName
}

module sqlPrivateEndpoint 'modules/sql-private-endpoint.bicep' = {
  name: 'sql-private-endpoint-deployment'
  params: {
    location: location
    prefix: prefix
    sqlServerResourceId: sqlServer.id
    sqlSubnetId: vnet.outputs.sqlSubnetId
    vnetId: vnet.outputs.vnetId
  }
}

// ──────────────────────────────────────────────────
// Function App networking (depends on VNet + PE)
// ──────────────────────────────────────────────────
module functionAppNetworking 'modules/function-app-networking.bicep' = {
  name: 'function-app-networking-deployment'
  params: {
    location: appServicePlanLocation
    functionAppName: functionAppName
    appServicePlanName: appServicePlanName
    storageAccountName: storageAccountName
    apiSubnetId: vnet.outputs.apiSubnetId
    sqlServerFqdn: '${sqlServerName}${environment().suffixes.sqlServerHostname}'
    sqlDatabaseName: sqlDatabaseName
  }
  dependsOn: [
    sqlPrivateEndpoint
  ]
}

// ──────────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────────
output vnetName string = vnet.outputs.vnetName
output apiSqlNsgName string = apiSqlNsg.outputs.nsgName
output webApiNsgName string = webApiNsg.outputs.nsgName
output sqlPrivateEndpointName string = sqlPrivateEndpoint.outputs.privateEndpointName
output functionAppVnetIntegrated bool = functionAppNetworking.outputs.vnetIntegrationConfigured
