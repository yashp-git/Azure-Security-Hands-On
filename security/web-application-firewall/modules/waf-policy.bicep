@description('Azure region — WAF policies are global for Front Door')
param location string = 'global'

@description('Resource naming prefix')
param prefix string

var wafPolicyName = replace('${prefix}WafPolicy', '-', '')

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: location
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: 'Enabled'
      customBlockResponseStatusCode: 403
      customBlockResponseBody: base64('{"error":"Request blocked by WAF policy"}')
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
        }
      ]
    }
    customRules: {
      rules: [
        {
          name: 'RateLimitRule'
          priority: 100
          enabledState: 'Enabled'
          ruleType: 'RateLimitRule'
          rateLimitThreshold: 1000
          rateLimitDurationInMinutes: 1
          action: 'Block'
          matchConditions: [
            {
              matchVariable: 'RemoteAddr'
              operator: 'IPMatch'
              negateCondition: true
              matchValue: [
                '10.0.0.0/8'
              ]
            }
          ]
        }
      ]
    }
  }
}

output wafPolicyId string = wafPolicy.id
output wafPolicyName string = wafPolicy.name
