@description('VNet name (from Module 2)')
param vnetName string

@description('Web-API NSG name (from Module 2)')
param webApiNsgName string

@description('API-SQL NSG name (from Module 2)')
param apiSqlNsgName string

@description('Log Analytics workspace resource ID for diagnostic settings')
param logAnalyticsWorkspaceId string

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
}

resource webApiNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = {
  name: webApiNsgName
}

resource apiSqlNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = {
  name: apiSqlNsgName
}

// VNet — peer connection logs, DDoS events, metrics
resource vnetDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Log-Send-To-Workspace'
  scope: vnet
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
}

// Web-API NSG — inbound/outbound rule match events
resource webApiNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Log-Send-To-Workspace'
  scope: webApiNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// API-SQL NSG — inbound/outbound rule match events
resource apiSqlNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Log-Send-To-Workspace'
  scope: apiSqlNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output module2DiagnosticsDeployed bool = true
