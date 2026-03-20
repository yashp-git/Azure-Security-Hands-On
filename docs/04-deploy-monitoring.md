# Module 4: Monitoring & Observability

Configure **Application Insights** and comprehensive **diagnostic settings** across every deployed resource in the demo. All telemetry flows to the single shared **Log Analytics workspace** created by Module 3, using a standardised diagnostic setting named `Log-Send-To-Workspace`.

## Prerequisites

- ✅ **Module 1 completed** — Base application deployed and healthy (see [01-deploy-app.md](01-deploy-app.md)).
- ✅ **Module 3 completed** — WAF deployment creates the shared Log Analytics workspace that all resources send logs to.
- ✅ Azure CLI logged in (`az login`)
- ✅ SWA CLI available (`npm install -g @azure/static-web-apps-cli`)
- Module 2 (NSG/VNet) is **optional** — auto-detected and configured if deployed.

---

## What You'll Deploy

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Observability Plane                                                  │
  │                                                                       │
  │  ┌─────────────────────────────────────────────────────────────────┐ │
  │  │  Log Analytics Workspace  (${prefix}-waf-law — from Module 3)  │ │
  │  │                                                                 │ │
  │  │  ┌──────────────────────┐  telemetry   ┌────────────────────┐  │ │
  │  │  │  Application Insights│ ◄──────────  │  Function App SDK  │  │ │
  │  │  │  (${prefix}-appi)    │              │  .NET 8 Isolated   │  │ │
  │  │  │                      │ ◄──────────  │  Browser JS SDK    │  │ │
  │  │  └──────────────────────┘              └────────────────────┘  │ │
  │  │                                                                 │ │
  │  │  Diagnostic Settings ("Log-Send-To-Workspace") ─────────────── │ │
  │  │  ├─ Function App          (logs + metrics)                      │ │
  │  │  ├─ Storage Account       (metrics)                             │ │
  │  │  ├─ Storage Blob Service  (read/write/delete logs + metrics)    │ │
  │  │  ├─ App Service Plan      (metrics)                             │ │
  │  │  ├─ Static Web App        (logs + metrics)                      │ │
  │  │  ├─ SQL Database          (all logs + metrics)                  │ │
  │  │  ├─ SQL Server audit      (auth, batch events → Azure Monitor)  │ │
  │  │  ├─ VNet                  (optional — Module 2)                 │ │
  │  │  ├─ NSG web-api           (optional — Module 2)                 │ │
  │  │  ├─ NSG api-sql           (optional — Module 2)                 │ │
  │  │  └─ Front Door            (optional — Module 3, renamed)        │ │
  │  └─────────────────────────────────────────────────────────────────┘ │
  └──────────────────────────────────────────────────────────────────────┘
```

### Resources Created

| Resource | Purpose |
|----------|---------|
| **Application Insights** (`${prefix}-appi`) | Workspace-based telemetry (server + browser) |
| **Diagnostic: Function App** | Execution logs, exceptions, metrics |
| **Diagnostic: Storage Account** | Capacity + transaction metrics |
| **Diagnostic: Blob Service** | StorageRead / StorageWrite / StorageDelete logs |
| **Diagnostic: App Service Plan** | CPU, memory, disk, instance count metrics |
| **Diagnostic: Static Web App** | Deployment and configuration audit logs |
| **Diagnostic: SQL Database** | Query logs, errors, deadlocks, timeouts |
| **SQL Server audit policy** | Auth events + query batches → Azure Monitor |
| **Diagnostic: VNet** *(optional)* | Peer connections, DNS, DDoS events |
| **Diagnostic: NSG web-api** *(optional)* | Inbound/outbound rule match events |
| **Diagnostic: NSG api-sql** *(optional)* | Inbound/outbound rule match events |
| **Diagnostic: Front Door** | Replaces ad-hoc Module 3 setting with standard name |

---

## Security Built In

| Security Control | Implementation |
|---|---|
| **Centralised logs** | One Log Analytics workspace; no logs siloed per resource |
| **Tamper-evident naming** | Every diagnostic setting named `Log-Send-To-Workspace` — consistent, auditable |
| **SQL Audit trail** | `SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP`, `FAILED_DATABASE_AUTHENTICATION_GROUP`, `BATCH_COMPLETED_GROUP` |
| **No new credentials** | App Insights connection string delivered via SWA app setting; browser SDK reads from `window` object at runtime |
| **Log retention** | Controlled centrally in Log Analytics (30 days, configurable) |
| **Continuous telemetry** | Function App SDK captures exceptions, dependencies, custom events automatically |

---

## Step-by-Step Deployment

### Step 1 — Verify your base deployment

Confirm Module 1 and Module 3 are healthy:

```powershell
# Check Module 1 — should return {"status":"healthy",...}
az staticwebapp show --name clickapp-swa-<suffix> --resource-group clickapp-rg --query defaultHostname -o tsv

# Check Module 3 — Log Analytics workspace must exist
az monitor log-analytics workspace list --resource-group clickapp-rg --query "[].name" -o tsv
```

Both must succeed before continuing.

### Step 2 — Run the monitoring deployment script

```powershell
cd monitoring
./deploy-monitoring.ps1
```

With custom parameters:

```powershell
./deploy-monitoring.ps1 -Prefix "clickapp" -ResourceGroupName "clickapp-rg"
```

#### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Prefix` | `clickapp` | Resource naming prefix (must match Modules 1–3) |
| `ResourceGroupName` | `{Prefix}-rg` | Azure resource group |
| `Location` | Auto-detected | Azure region (auto-detected from Function App) |
| `SubscriptionId` | Current context | Azure subscription ID |

### Step 3 — What the script does

The script performs these steps automatically:

| Step | Action |
|------|--------|
| 1 | Checks prerequisites (az CLI, SWA CLI) |
| 2 | Validates Azure login and resource group |
| 3 | Discovers all existing resources via `az resource list` |
| 4 | Auto-detects Module 2 resources (VNet, NSGs) |
| 5 | Auto-detects Module 3 resources (Front Door) |
| 6 | Deletes old Front Door diagnostic setting (`${Prefix}-afd-diagnostics`) if present |
| 7 | Deploys Bicep — creates App Insights, diagnostic settings, SQL audit policy |
| 8 | Sets `APPLICATIONINSIGHTS_CONNECTION_STRING` as a SWA app setting |
| 9 | Re-deploys SWA frontend with App Insights browser SDK connection string injected |
| 10 | Verifies App Insights provisioning, diagnostic settings, SQL audit state |

> **Note — App settings replacement:** ARM requires the complete `appsettings` object when updating a Function App. The Bicep template re-declares all existing settings (Module 1 base settings, Module 2 VNet settings if applicable) plus the new Application Insights settings — nothing is lost.

> **Note — Front Door diagnostic setting:** Module 3 creates a diagnostic setting named `${prefix}-afd-diagnostics`. This script deletes that and re-creates it with the standard name `Log-Send-To-Workspace` so all resources use consistent naming.

### Step 4 — Verify the deployment

After the script completes, verify each resource:

```powershell
$rg = "clickapp-rg"

# Application Insights
az resource show --resource-group $rg --name clickapp-appi --resource-type "Microsoft.Insights/components" --query "properties.provisioningState" -o tsv
# Expected: Succeeded

# Diagnostic settings — Function App
$funcId = az resource list --resource-group $rg --resource-type "Microsoft.Web/sites" --query "[?kind=='functionapp'].id" -o tsv
az monitor diagnostic-settings list --resource $funcId --query "[].name" -o tsv
# Expected: Log-Send-To-Workspace

# Diagnostic settings — SQL Database
$sqlServerId = az sql server show --name clickapp-sql-<suffix> --resource-group $rg --query id -o tsv
$dbId = az sql db show --server clickapp-sql-<suffix> --resource-group $rg --name clickapp-db --query id -o tsv
az monitor diagnostic-settings list --resource $dbId --query "[].name" -o tsv
# Expected: Log-Send-To-Workspace

# SQL Server audit policy
az sql server audit-policy show --name clickapp-sql-<suffix> --resource-group $rg --query "{state:state,azureMonitor:isAzureMonitorTargetEnabled}" -o table
# Expected: state=Enabled, azureMonitor=true

# App Insights connection string on SWA
az staticwebapp appsettings list --name clickapp-swa-<suffix> --resource-group $rg --query "properties" -o json
# Expected: APPLICATIONINSIGHTS_CONNECTION_STRING present
```

### Step 5 — View telemetry in Log Analytics

Open the Azure Portal and navigate to: **Resource Group → `clickapp-waf-law` → Logs**

#### Application telemetry — page views and button clicks

```kusto
customEvents
| where timestamp > ago(1h)
| project timestamp, name, customDimensions
| order by timestamp desc
```

#### Function App exceptions

```kusto
exceptions
| where timestamp > ago(1h)
| project timestamp, outerMessage, type, innermostMessage
| order by timestamp desc
```

#### Function App requests with duration

```kusto
requests
| where timestamp > ago(1h)
| project timestamp, name, url, resultCode, duration
| order by timestamp desc
```

#### SQL Database errors

```kusto
AzureDiagnostics
| where ResourceType == "DATABASES"
| where Category == "Errors"
| project TimeGenerated, Resource, error_number_d, error_severity_d, error_message_s
| order by TimeGenerated desc
```

#### SQL audit — failed login attempts

```kusto
AzureDiagnostics
| where Category == "SQLSecurityAuditEvents"
| where action_name_s == "FAILED_DATABASE_AUTHENTICATION_GROUP"
| project TimeGenerated, server_instance_name_s, client_ip_s, statement_s
| order by TimeGenerated desc
```

#### NSG rule matches (Module 2 — if deployed)

```kusto
AzureDiagnostics
| where Category == "NetworkSecurityGroupRuleCounter"
| project TimeGenerated, Resource, direction_s, ruleName_s, matchedConnections_d
| order by TimeGenerated desc
```

#### Front Door WAF blocked requests (Module 3 — if deployed)

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorWebApplicationFirewallLog"
| where action_s == "Block"
| project TimeGenerated, clientIp_s, requestUri_s, ruleName_s, details_message_s
| order by TimeGenerated desc
```

---

## Troubleshooting

**App Insights connection string not appearing in browser telemetry**
- Confirm the SWA re-deployment succeeded (Step 8 of the script)
- Check that `window.__APPINSIGHTS_CONNECTION_STRING__` is not the literal placeholder string — view the deployed `index.html` source from the browser
- Verify the SWA app setting using: `az staticwebapp appsettings list --name <swa-name> --resource-group <rg>`

**Function App stopped responding after appsettings update**
- The full `appsettings` replacement causes a brief Function App restart (~30–60 seconds)
- Wait for the health check URL to return 200 before assuming failure
- If the app does not recover, check `FUNCTIONS_WORKER_RUNTIME` is set to `dotnet-isolated` in the portal → Function App → Configuration

**SQL audit events not appearing in Log Analytics**
- Audit events have a latency of up to 5 minutes before appearing in `AzureDiagnostics`
- Confirm `isAzureMonitorTargetEnabled = true`: `az sql server audit-policy show --name <server> --resource-group <rg>`
- The SQL Database must also have `Log-Send-To-Workspace` diagnostic settings — confirmed during verification step

**Diagnostic settings missing on a resource**
- Re-run the script — it is idempotent; existing settings with the same name are updated in place
- For Module 2/3 resources, verify the resource was auto-detected (look at Step 4/5 output)

**Old Front Door diagnostic setting still present**
- The script deletes `${prefix}-afd-diagnostics` before deploying Bicep
- If it persists, delete it manually: `az monitor diagnostic-settings delete --name clickapp-afd-diagnostics --resource <frontdoor-id>`

---

## Estimated Cost

| Resource | Pricing Model | Estimated Monthly Cost |
|----------|--------------|------------------------|
| **Application Insights** | First 5 GB/month free; $2.30/GB after | ~$0–5/month (low traffic demo) |
| **Log Analytics** | First 5 GB/month free; $2.30/GB after | Shared workspace (no additional cost) |
| **SQL Audit logs** | Written to Log Analytics (included above) | $0 additional |
| **Diagnostic settings** | No charge for the settings themselves | $0 |

> **Total Module 4 addition:** ~$0–5/month for a low-traffic demo environment. Log data is the only billable component.

---

## Cleanup

To remove Module 4 resources (Application Insights only — diagnostic settings are configurations, not billed resources):

```powershell
az resource delete `
    --resource-group clickapp-rg `
    --name clickapp-appi `
    --resource-type "Microsoft.Insights/components"
```

To remove everything:

```powershell
az group delete --name clickapp-rg --yes --no-wait
```

---

## Next Steps

You have now completed the full Azure Security Hands-On demo:

| Module | Security Layer | Status |
|--------|---------------|--------|
| **Module 1** — Base App | Application security (MI, TLS, parameterized queries) | ✅ |
| **Module 2** — NSG/VNet | Network isolation (VNet, NSGs, Private Endpoint) | ✅ |
| **Module 3** — WAF | Web layer protection (OWASP DRS 2.1, Bot Manager, rate limiting) | ✅ |
| **Module 4** — Monitoring | Observability (App Insights, audit logs, diagnostic settings) | ✅ |

**Suggested further exploration:**
- Set up [Azure Monitor Alert Rules](https://docs.microsoft.com/azure/azure-monitor/alerts/alerts-overview) for failed SQL logins or WAF blocks
- Configure [Azure Policy](https://docs.microsoft.com/azure/governance/policy/overview) to enforce diagnostic settings on all future resources
- Enable [Azure DDoS Protection Standard](https://docs.microsoft.com/azure/ddos-protection/ddos-protection-overview) for the VNet (if Module 2 deployed)
