targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Resource naming prefix')
param prefix string = 'clickapp'

@description('AAD admin object ID for SQL Server')
param aadAdminObjectId string

@description('AAD admin login (UPN) for SQL Server')
param aadAdminLogin string

var uniqueSuffix = uniqueString(resourceGroup().id)

module sql 'modules/sql.bicep' = {
  name: 'sql-deployment'
  params: {
    location: location
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    aadAdminObjectId: aadAdminObjectId
    aadAdminLogin: aadAdminLogin
  }
}

module functionApp 'modules/function-app.bicep' = {
  name: 'function-app-deployment'
  params: {
    location: location
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sql.outputs.databaseName
  }
}

module staticWebApp 'modules/static-web-app.bicep' = {
  name: 'static-web-app-deployment'
  params: {
    location: location
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    functionAppResourceId: functionApp.outputs.functionAppResourceId
    functionAppLocation: location
  }
}

output sqlServerFqdn string = sql.outputs.serverFqdn
output sqlServerName string = sql.outputs.serverName
output sqlDatabaseName string = sql.outputs.databaseName
output functionAppName string = functionApp.outputs.functionAppName
output functionAppHostname string = functionApp.outputs.functionAppHostname
output functionAppPrincipalId string = functionApp.outputs.principalId
output swaName string = staticWebApp.outputs.swaName
output swaHostname string = staticWebApp.outputs.swaHostname
output swaDeploymentToken string = staticWebApp.outputs.swaDeploymentToken
