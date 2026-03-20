@description('Azure region for all resources')
param location string

@description('Resource naming prefix')
param prefix string

@description('Existing SQL Server resource ID')
param sqlServerResourceId string

@description('Subnet ID for the SQL private endpoint')
param sqlSubnetId string

@description('VNet ID to link the private DNS zone')
param vnetId string

var privateEndpointName = '${prefix}-sql-pe'
var privateDnsZoneName = 'privatelink${environment().suffixes.sqlServerHostname}'

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: sqlSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: {
          privateLinkServiceId: sqlServerResourceId
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: '${prefix}-vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: privateEndpoint
  name: 'sqlDnsZoneGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sqlDnsConfig'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output privateEndpointName string = privateEndpoint.name
output privateDnsZoneName string = privateDnsZone.name
