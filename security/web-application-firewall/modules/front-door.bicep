@description('Resource naming prefix')
param prefix string

@description('WAF policy resource ID to associate with security policy')
param wafPolicyId string

@description('Static Web App default hostname (e.g. xxx.azurestaticapps.net)')
param swaHostname string

@description('Function App default hostname (e.g. xxx.azurewebsites.net)')
param functionAppHostname string

var frontDoorName = '${prefix}-afd'
var webOriginGroupName = 'web-origin-group'
var apiOriginGroupName = 'api-origin-group'
var webOriginName = 'swa-origin'
var apiOriginName = 'func-origin'
var webRouteName = 'web-route'
var apiRouteName = 'api-route'
var webEndpointName = '${prefix}-web-ep'
var securityPolicyName = 'waf-security-policy'

resource frontDoor 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: frontDoorName
  location: 'global'
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

// ──────────────────────────────────────────────────
// Endpoint — single endpoint for both web and API
// ──────────────────────────────────────────────────
resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: frontDoor
  name: webEndpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

// ──────────────────────────────────────────────────
// Origin Group: Web (Static Web App)
// ──────────────────────────────────────────────────
resource webOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: frontDoor
  name: webOriginGroupName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
    }
    sessionAffinityState: 'Disabled'
  }
}

resource webOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: webOriginGroup
  name: webOriginName
  properties: {
    hostName: swaHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: swaHostname
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

// ──────────────────────────────────────────────────
// Origin Group: API (Function App)
// ──────────────────────────────────────────────────
resource apiOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: frontDoor
  name: apiOriginGroupName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/api/health'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
    }
    sessionAffinityState: 'Disabled'
  }
}

resource apiOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: apiOriginGroup
  name: apiOriginName
  properties: {
    hostName: functionAppHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: functionAppHostname
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

// ──────────────────────────────────────────────────
// Route: Web — handles /* (default)
// ──────────────────────────────────────────────────
resource webRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: webRouteName
  properties: {
    originGroup: {
      id: webOriginGroup.id
    }
    patternsToMatch: [
      '/*'
    ]
    supportedProtocols: [
      'Http'
      'Https'
    ]
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    webOrigin
  ]
}

// ──────────────────────────────────────────────────
// Route: API — handles /api/*
// ──────────────────────────────────────────────────
resource apiRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: apiRouteName
  properties: {
    originGroup: {
      id: apiOriginGroup.id
    }
    patternsToMatch: [
      '/api/*'
    ]
    supportedProtocols: [
      'Http'
      'Https'
    ]
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    apiOrigin
    webRoute
  ]
}

// ──────────────────────────────────────────────────
// Security Policy — attaches WAF to the endpoint
// ──────────────────────────────────────────────────
resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  parent: frontDoor
  name: securityPolicyName
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: wafPolicyId
      }
      associations: [
        {
          domains: [
            {
              id: endpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
  dependsOn: [
    webRoute
    apiRoute
  ]
}

output frontDoorId string = frontDoor.id
output frontDoorName string = frontDoor.name
output endpointHostname string = endpoint.properties.hostName
output endpointName string = endpoint.name
