# Module 3: Web Application Firewall (WAF)

Deploy **Azure Front Door Premium** with a **Web Application Firewall** policy to protect the web and API tiers against OWASP Top 10 threats — including SQL injection, cross-site scripting (XSS), command injection, bot attacks, and DDoS.

## Prerequisites

- ✅ **Module 1 completed** — The base application must be deployed and healthy. Run `./deploy.ps1` first (see [01-deploy-app.md](01-deploy-app.md)).
- ✅ Azure CLI logged in (`az login`)
- Module 2 (NSG) is **optional** — WAF works independently of network security.

---

## What You'll Deploy

```
                    ┌──────────────────────────────────────────────┐
                    │  Azure Front Door Premium                    │
                    │                                              │
   User Request     │  ┌────────────────────────────────────────┐  │
──────────────────> │  │  WAF Policy (Prevention Mode)          │  │
   HTTPS            │  │                                        │  │
                    │  │  ✓ OWASP DRS 2.1 (SQL injection, XSS)  │  │
                    │  │  ✓ Bot Manager 1.1                     │  │
                    │  │  ✓ Rate Limiting (1000 req/min/IP)     │  │
                    │  └───────────┬────────────────────────────┘  │
                    │              │                               │
                    │    Route Decision (URL path)                 │
                    │    ├─ /api/*  → Function App (origin)        │
                    │    └─ /*     → Static Web App (origin)       │
                    │                                              │
                    └──────────────────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
          ┌─────────────────┐          ┌──────────────────┐
          │ Static Web App  │          │  Function App    │
          │ (Web frontend)  │          │  (API backend)   │
          └─────────────────┘          └──────────────────┘
```

### Resources Created

| Resource | Purpose |
|----------|---------|
| **Front Door Profile** (Premium) | Global CDN + reverse proxy |
| **Front Door Endpoint** | Single public URL for all traffic |
| **Web Origin Group** | Health probes + load balancing for SWA |
| **API Origin Group** | Health probes + load balancing for Function App |
| **Web Route** (`/*`) | Routes general traffic to SWA |
| **API Route** (`/api/*`) | Routes API traffic to Function App |
| **WAF Policy** | OWASP DRS 2.1 + Bot Manager in Prevention mode |
| **Security Policy** | Binds WAF to the Front Door endpoint |
| **Log Analytics Workspace** | Stores WAF logs, access logs, and metrics |
| **Diagnostic Settings** | Streams all Front Door telemetry to Log Analytics |

---

## OWASP Top 10 Coverage

The WAF policy uses **Microsoft Default Rule Set (DRS) 2.1**, which covers:

| OWASP Top 10 (2021) | WAF Coverage | How |
|----------------------|-------------|-----|
| **A01** Broken Access Control | ✅ Partial | Blocks path traversal, directory listing exploits |
| **A02** Cryptographic Failures | ✅ | HTTPS enforced; HTTP → HTTPS redirect |
| **A03** Injection | ✅ | SQL injection, command injection, LDAP injection rules |
| **A04** Insecure Design | — | Application-level concern (not WAF scope) |
| **A05** Security Misconfiguration | ✅ | Blocks common exploit patterns, information leakage |
| **A06** Vulnerable Components | ✅ Partial | Azure-managed rule updates; known CVE patterns |
| **A07** Auth Failures | ✅ Partial | Brute-force mitigation via rate limiting |
| **A08** Data Integrity Failures | ✅ | Request body inspection enabled |
| **A09** Logging Failures | ✅ | WAF logs + access logs → Log Analytics |
| **A10** SSRF | ✅ | Server-side request forgery rules in DRS 2.1 |

### Additional Protections

| Protection | Detail |
|-----------|--------|
| **Bot Manager 1.1** | Detects and blocks malicious bots, scrapers, crawlers |
| **Rate Limiting** | 1000 requests/minute per IP (exempts private networks 10.0.0.0/8) |
| **Request Body Inspection** | Inspects POST/PUT payloads for malicious content |
| **Custom Block Response** | Returns HTTP 403 with JSON body for blocked requests |

---

## Step-by-Step Deployment

### Step 1: Verify Base Deployment

```powershell
# Confirm the SWA and Function App exist
az resource list --resource-group clickapp-rg --resource-type "Microsoft.Web/staticSites" --output table
az resource list --resource-group clickapp-rg --resource-type "Microsoft.Web/sites" --output table
```

### Step 2: Run the WAF Deployment Script

```powershell
./security/web-application-firewall/deploy-waf.ps1
```

**Custom parameters:**

```powershell
./security/web-application-firewall/deploy-waf.ps1 `
    -Prefix "myapp" `
    -ResourceGroupName "my-rg" `
    -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Prefix` | `clickapp` | Must match the prefix used in Module 1 |
| `-ResourceGroupName` | `{Prefix}-rg` | Must match Module 1 resource group |
| `-SubscriptionId` | *(current)* | Azure subscription ID |

### Step 3: What the Script Does

1. ✅ Discovers existing SWA and Function App hostnames
2. ✅ Detects resource group region for Log Analytics
3. ✅ Deploys WAF Policy (OWASP DRS 2.1 + Bot Manager 1.1 + rate limiting)
4. ✅ Deploys Front Door Premium with origin groups and routes
5. ✅ Creates Log Analytics Workspace with diagnostic settings
6. ✅ Attaches WAF security policy to the Front Door endpoint
7. ✅ Verifies Front Door profile, origin groups, and security policies
8. ✅ Runs health checks via the Front Door endpoint

### Step 4: Wait for Propagation

> ⚠️ **Front Door can take 5–10 minutes to fully propagate.** The script retries health checks automatically (10 attempts, 20-second intervals). If health checks show "PENDING", wait and test manually.

### Step 5: Verify the Deployment

```
============================================
  WAF SECURITY DEPLOYMENT COMPLETE
============================================

  Front Door:          clickapp-afd (Premium)
  Endpoint URL:        https://clickapp-web-ep-xxxxxxxxx.z01.azurefd.net

  WAF Policy:          clickappWafPolicy
    Mode:              Prevention
    Managed Rules:     OWASP DRS 2.1 + Bot Manager 1.1
    Rate Limiting:     1000 req/min per IP

  Log Analytics:       clickapp-waf-law
    WAF Logs:          FrontDoorWebApplicationFirewallLog
    Access Logs:       FrontDoorAccessLog

  Routes:
    /*       -> Static Web App
    /api/*   -> Function App
============================================
```

**Access your application via the Front Door URL** (not the direct SWA URL) to benefit from WAF protection.

---

## Testing WAF Protection

After deployment, test that the WAF blocks malicious requests.

### Test 1: SQL Injection (should be blocked)

```powershell
# Attempt SQL injection in URL — should return 403
curl -s -o /dev/null -w "%{http_code}" "https://<front-door-endpoint>/api/count?ip=1' OR '1'='1"
# Expected: 403

# Attempt SQL injection in body — should return 403
curl -s -o /dev/null -w "%{http_code}" -X POST "https://<front-door-endpoint>/api/click" `
    -H "Content-Type: application/json" `
    -d '{"ipAddress": "1; DROP TABLE ClickRecords;--"}'
# Expected: 403
```

### Test 2: Cross-Site Scripting / XSS (should be blocked)

```powershell
# Attempt XSS in User-Agent header — should return 403
curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: <script>alert('xss')</script>" "https://<front-door-endpoint>/"
# Expected: 403

# Attempt XSS in query parameter — should return 403
curl -s -o /dev/null -w "%{http_code}" "https://<front-door-endpoint>/api/count?ip=<img src=x onerror=alert(1)>"
# Expected: 403
```

### Test 3: Command Injection (should be blocked)

```powershell
# Attempt command injection — should return 403
curl -s -o /dev/null -w "%{http_code}" "https://<front-door-endpoint>/api/count?ip=;cat /etc/passwd"
# Expected: 403
```

### Test 4: Legitimate Request (should pass)

```powershell
# Normal web page — should return 200
curl -s -o /dev/null -w "%{http_code}" "https://<front-door-endpoint>/"
# Expected: 200

# Normal API call — should return 200
curl -s -o /dev/null -w "%{http_code}" "https://<front-door-endpoint>/api/health"
# Expected: 200

# Normal click — should return 200
curl -s -o /dev/null -w "%{http_code}" -X POST "https://<front-door-endpoint>/api/click" `
    -H "Content-Type: application/json" `
    -d '{"ipAddress": "203.0.113.50"}'
# Expected: 200
```

---

## Viewing WAF Logs

The deployment creates a Log Analytics Workspace with all Front Door and WAF logs. Use these Kusto queries in the Azure Portal.

### Navigate to Log Analytics

1. Go to **Azure Portal** → **Resource Group** → `clickapp-waf-law`
2. Click **Logs** in the left menu

### Query: Blocked Requests (WAF Blocks)

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorWebApplicationFirewallLog"
| where action_s == "Block"
| project TimeGenerated, clientIP_s, requestUri_s, ruleName_s, action_s, details_msg_s
| order by TimeGenerated desc
| take 50
```

### Query: All WAF Events (Blocks + Logs)

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorWebApplicationFirewallLog"
| summarize Count=count() by action_s, ruleName_s
| order by Count desc
```

### Query: Top Blocked IPs

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorWebApplicationFirewallLog"
| where action_s == "Block"
| summarize BlockCount=count() by clientIP_s
| order by BlockCount desc
| take 20
```

### Query: Access Logs (All Traffic)

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorAccessLog"
| project TimeGenerated, clientIp_s, httpMethod_s, requestUri_s, httpStatusCode_d, timeTaken_d
| order by TimeGenerated desc
| take 100
```

> 💡 **Tip:** WAF logs may take 5–10 minutes to appear in Log Analytics after a request is processed.

---

## WAF Policy Details

### Mode: Prevention

The WAF operates in **Prevention** mode — malicious requests are **blocked** (HTTP 403), not just logged. This is the recommended mode for production protection.

### Managed Rules

| Rule Set | Version | Description |
|----------|---------|-------------|
| Microsoft_DefaultRuleSet (OWASP DRS) | 2.1 | Covers SQL injection, XSS, command injection, SSRF, LFI/RFI, Java/PHP attacks |
| Microsoft_BotManagerRuleSet | 1.1 | Detects malicious bots, scrapers, vulnerability scanners |

### Custom Rules

| Rule | Type | Threshold | Action | Scope |
|------|------|-----------|--------|-------|
| RateLimitRule | Rate Limit | 1000 req/min per IP | Block | All non-private IPs |

### Routing

| Pattern | Origin | Health Probe |
|---------|--------|-------------|
| `/api/*` | Function App | `GET /api/health` every 30s |
| `/*` (default) | Static Web App | `HEAD /` every 30s |

---

## Troubleshooting

### "Front Door health check PENDING"

Front Door needs time to propagate globally. Wait 5–10 minutes and test:

```powershell
curl https://<front-door-endpoint>/
curl https://<front-door-endpoint>/api/health
```

### "Origin not healthy"

If Front Door reports origins as unhealthy:

1. Verify the SWA and Function App are accessible directly:
   ```powershell
   curl https://<swa-hostname>/
   curl https://<function-app-hostname>/api/health
   ```

2. Check the health probe configuration:
   ```powershell
   az afd origin-group list --resource-group clickapp-rg --profile-name clickapp-afd --output table
   ```

### "WAF blocking legitimate requests (false positives)"

If WAF blocks requests that should be allowed:

1. Check which rule triggered the block using the WAF logs (see [Viewing WAF Logs](#viewing-waf-logs))
2. Identify the specific rule name from the logs
3. You can temporarily set WAF to **Detection** mode to log without blocking:
   - Azure Portal → WAF Policy → Settings → Switch mode to "Detection"
   - Investigate and tune, then switch back to "Prevention"

### "No logs appearing in Log Analytics"

- Logs can take **5–10 minutes** to appear after the first request
- Verify diagnostic settings exist:
  ```powershell
  az monitor diagnostic-settings list --resource <front-door-resource-id> --output table
  ```

---

## Estimated Additional Cost

| Resource | Monthly Cost (approx.) |
|----------|----------------------|
| Front Door Premium | ~$35 (base) + per-request charges |
| WAF Policy (Premium) | Included with Front Door Premium |
| Log Analytics Workspace | ~$2–5 (depends on log volume) |
| **Additional Total** | **~$40–50/month** |

---

## Cleanup

To remove **only** the WAF resources:

```powershell
# Remove Front Door, WAF Policy, and Log Analytics
az afd profile delete --resource-group clickapp-rg --profile-name clickapp-afd --yes
az network front-door waf-policy delete --resource-group clickapp-rg --name clickappWafPolicy
az monitor log-analytics workspace delete --resource-group clickapp-rg --workspace-name clickapp-waf-law --yes
```

To remove **everything** (all modules):

```powershell
az group delete --name clickapp-rg --yes --no-wait
```

---

## Next Steps

With all three modules deployed, your application now has:

- ✅ **Module 1**: Secure application with Managed Identity and AAD-only SQL
- ✅ **Module 2**: Network isolation with VNet, NSGs, and Private Endpoints
- ✅ **Module 3**: WAF protection against OWASP Top 10 + bot detection + rate limiting

**Explore further:**
- Review WAF logs in Log Analytics to understand traffic patterns
- Test the WAF with additional attack vectors from the [OWASP Testing Guide](https://owasp.org/www-project-web-security-testing-guide/)
- Try modifying the rate limit threshold in `security/web-application-firewall/modules/waf-policy.bicep`
- Add custom WAF rules for geo-blocking or IP reputation filtering
