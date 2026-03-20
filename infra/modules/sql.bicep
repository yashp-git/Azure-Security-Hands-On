@description('Azure region for all resources')
param location string

@description('Resource naming prefix')
param prefix string

@description('Unique suffix for globally unique names')
param uniqueSuffix string

@description('AAD admin object ID (deployer)')
param aadAdminObjectId string

@description('AAD admin login (deployer UPN)')
param aadAdminLogin string

var serverName = '${prefix}-sql-${uniqueSuffix}'
var databaseName = '${prefix}-db'

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: aadAdminLogin
      sid: aadAdminObjectId
      tenantId: subscription().tenantId
      principalType: 'User'
    }
    minimalTlsVersion: '1.2'
  }
}

resource firewallAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
  }
}

output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output serverName string = sqlServer.name
output databaseName string = sqlDatabase.name
