targetScope = 'resourceGroup'

@description('Resource naming prefix')
param prefix string = 'clickapp'

@description('Azure region for Log Analytics workspace')
param location string = 'eastus2'

@description('Static Web App default hostname')
param swaHostname string

@description('Function App default hostname')
param functionAppHostname string

// ──────────────────────────────────────────────────
// Log Analytics Workspace — captures WAF and Front Door logs
// ──────────────────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-waf-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ──────────────────────────────────────────────────
// WAF Policy — shared protection for both Web and API
// ──────────────────────────────────────────────────
module wafPolicy 'modules/waf-policy.bicep' = {
  name: 'waf-policy-deployment'
  params: {
    prefix: prefix
  }
}

// ──────────────────────────────────────────────────
// Front Door — routes traffic through WAF to backends
// ──────────────────────────────────────────────────
module frontDoor 'modules/front-door.bicep' = {
  name: 'front-door-deployment'
  params: {
    prefix: prefix
    wafPolicyId: wafPolicy.outputs.wafPolicyId
    swaHostname: swaHostname
  }
}

// ──────────────────────────────────────────────────
// Diagnostic Settings — send WAF & Front Door logs to Log Analytics
// ──────────────────────────────────────────────────
resource frontDoorRef 'Microsoft.Cdn/profiles@2024-02-01' existing = {
  name: '${prefix}-afd'
  dependsOn: [
    frontDoor
  ]
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${prefix}-afd-diagnostics'
  scope: frontDoorRef
  properties: {
    workspaceId: logAnalytics.id
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

// ──────────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────────
output wafPolicyName string = wafPolicy.outputs.wafPolicyName
output frontDoorName string = frontDoor.outputs.frontDoorName
output frontDoorEndpoint string = frontDoor.outputs.endpointHostname
output logAnalyticsWorkspaceName string = logAnalytics.name
