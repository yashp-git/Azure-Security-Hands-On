@description('Resource naming prefix')
param prefix string

@description('WAF policy resource ID to associate with security policy')
param wafPolicyId string

@description('Static Web App default hostname (e.g. xxx.azurestaticapps.net)')
param swaHostname string

var frontDoorName = '${prefix}-afd'
var webOriginGroupName = 'web-origin-group'
var webOriginName = 'swa-origin'
var webRouteName = 'web-route'
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
// Endpoint — single endpoint for web + API
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
// Origin Group: Static Web App
// The SWA has a linked backend to the Function App, so
// /api/* requests are automatically proxied to the Function
// App with correct EasyAuth tokens.
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
// Route: All traffic (/* including /api/*) → SWA
// SWA serves static content for web requests and proxies
// /api/* to the Function App via its linked backend.
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
  ]
}

output frontDoorId string = frontDoor.id
output frontDoorName string = frontDoor.name
output endpointHostname string = endpoint.properties.hostName
output endpointName string = endpoint.name
