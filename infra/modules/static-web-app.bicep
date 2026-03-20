@description('Azure region for all resources')
param location string

@description('Resource naming prefix')
param prefix string

@description('Unique suffix for globally unique names')
param uniqueSuffix string

@description('Function App resource ID for linked backend')
param functionAppResourceId string

@description('Function App region')
param functionAppLocation string

var swaName = '${prefix}-swa-${uniqueSuffix}'

resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: swaName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
  }
}

resource linkedBackend 'Microsoft.Web/staticSites/linkedBackends@2023-12-01' = {
  parent: staticWebApp
  name: 'backend'
  properties: {
    backendResourceId: functionAppResourceId
    region: functionAppLocation
  }
}

output swaName string = staticWebApp.name
output swaHostname string = staticWebApp.properties.defaultHostname
output swaDeploymentToken string = staticWebApp.listSecrets().properties.apiKey
