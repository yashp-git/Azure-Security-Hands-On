# Module 1: Deploy the Application

Deploy a 3-tier Azure application: **Static Web App** (frontend) → **Azure Functions** (API) → **Azure SQL Database** (data) — all with a single script.

## What You'll Deploy

```
┌──────────────────┐       ┌────────────────────┐       ┌─────────────────┐
│  Azure Static    │──────>│  Azure Functions   │──────>│   Azure SQL     │
│  Web App (SWA)   │  API  │  (.NET 8 Isolated) │   MI  │   Database      │
│  Standard Tier   │       │  Consumption Plan  │       │   Basic Tier    │
└──────────────────┘       └────────────────────┘       └─────────────────┘
   HTML/CSS/JS               C# / ADO.NET                Managed Identity
   Linked Backend            POST /api/click             (AAD-only auth)
                             GET  /api/count             TLS 1.2+ enforced
                             GET  /api/health
```

### Resources Created

| Resource | SKU / Tier | Purpose |
|----------|-----------|---------|
| Resource Group | — | Container for all resources |
| SQL Server | — | AAD-only authentication, TLS 1.2 |
| SQL Database | Basic (5 DTU, 2 GB) | Click records storage |
| Storage Account | Standard_LRS | Function App runtime storage |
| App Service Plan | Consumption (Y1) | Serverless compute for API |
| Function App | .NET 8 Isolated | API with System-Assigned Managed Identity |
| Static Web App | Standard | Frontend hosting + linked backend routing |

### Security Built In

- **No passwords** — Function App uses Managed Identity to authenticate to SQL
- **AAD-only SQL** — SQL auth is disabled; only Azure AD authentication allowed
- **Parameterized SQL queries** — All database operations use `@parameters` (no SQL injection)
- **HTTPS only** — All resources enforce HTTPS with TLS 1.2+
- **FTPS disabled** — No FTP access to Function App
- **Blob public access disabled** — Storage Account blocks anonymous blob reads

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Azure CLI | 2.50+ | https://aka.ms/installazurecli |
| .NET SDK | 8.0+ | https://dot.net |
| Node.js | 18+ | https://nodejs.org |
| SWA CLI | latest | `npm install -g @azure/static-web-apps-cli` |

### Azure Requirements

- An Azure subscription (free trial works: https://azure.microsoft.com/free)
- Logged in to Azure CLI: `az login`
- Permissions to create resources in the subscription
- Your Azure AD account must be able to serve as SQL Server admin

### Verify Prerequisites

```powershell
# Check all tools are installed
az version          # Should show 2.50+
dotnet --version    # Should show 8.x
node --version      # Should show v18+
swa --version       # Should show a version number
az account show     # Should show your logged-in account
```

---

## Step-by-Step Deployment

### Step 1: Clone the Repository

```powershell
git clone <repository-url>
cd Azure-Security-Hands-On
```

### Step 2: Login to Azure

```powershell
az login

# If you have multiple tenants/subscriptions, specify them:
az login --tenant "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
az account set --subscription "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

### Step 3: Run the Deployment Script

**Default deployment** (prefix: `clickapp`, region: `eastus2`):

```powershell
./deploy.ps1
```

**Custom deployment:**

```powershell
./deploy.ps1 -Prefix "myapp" `
             -Location "centralus" `
             -ResourceGroupName "my-rg" `
             -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
             -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Prefix` | `clickapp` | Naming prefix for all resources |
| `-Location` | `eastus2` | Azure region |
| `-ResourceGroupName` | `{Prefix}-rg` | Resource group name |
| `-TenantId` | *(current)* | Azure AD tenant ID |
| `-SubscriptionId` | *(current)* | Azure subscription ID |

### Step 4: Wait for Deployment

The script performs these steps automatically:

1. ✅ Validates prerequisites (az, dotnet, swa)
2. ✅ Sets tenant/subscription context
3. ✅ Creates the resource group
4. ✅ Deploys infrastructure via Bicep (SQL → Function App → SWA)
5. ✅ Adds temporary SQL firewall rule for your IP
6. ✅ Initialises database schema (`dbo.ClickRecords` table + index)
7. ✅ Creates Managed Identity database user with `db_datareader` + `db_datawriter`
8. ✅ Removes temporary firewall rules
9. ✅ Builds and deploys the .NET 8 API (zip deploy)
10. ✅ Deploys the static web frontend via SWA CLI
11. ✅ Runs health checks (web HTTP 200 + API health endpoint)
12. ✅ Prints deployment summary with URLs

### Step 5: Verify the Deployment

After the script completes, you'll see a summary like:

```
============================================
  DEPLOYMENT COMPLETE
============================================

  Web App:  https://xxx.azurestaticapps.net
  API:      https://xxx.azurestaticapps.net/api/health

  Web Status:  HEALTHY
  API Status:  HEALTHY
```

**Manual verification:**

```powershell
# Check the web app loads
curl https://<your-swa-hostname>

# Check the API health endpoint
curl https://<your-swa-hostname>/api/health
# Expected: { "status": "healthy", "database": "connected", "timestamp": "..." }

# Test the click API
curl -X POST https://<your-swa-hostname>/api/click -H "Content-Type: application/json"
# Expected: { "totalCount": 1, "ipCount": 1, "ipAddress": "..." }

# Get current counts
curl https://<your-swa-hostname>/api/count
# Expected: { "totalCount": 1, "ipCount": 0, "ipAddress": "unknown" }
```

---

## How It Works

### Data Flow

1. User opens the SWA URL in their browser
2. Frontend JavaScript detects the user's public IP via `api.ipify.org`
3. User clicks the button → `POST /api/click` with IP in request body
4. SWA linked backend routes `/api/*` to the Function App
5. Function App inserts a record into SQL via Managed Identity
6. Function App returns `{ totalCount, ipCount }` as JSON
7. Frontend animates the counter update

### Infrastructure as Code (Bicep)

The deployment uses modular Bicep templates:

- **`infra/main.bicep`** — Orchestrator that chains the three modules
- **`infra/modules/sql.bicep`** — SQL Server (AAD-only) + Database + firewall rule
- **`infra/modules/function-app.bicep`** — Storage + App Service Plan + Function App with MI
- **`infra/modules/static-web-app.bicep`** — SWA + linked backend to Function App

Module dependency chain: `SQL` → `Function App` (needs SQL outputs) → `SWA` (needs Function App outputs)

---

## Troubleshooting

### "Not logged in to Azure CLI"
```powershell
az login
# If behind a corporate proxy:
az login --use-device-code
```

### "SWA CLI not found"
```powershell
npm install -g @azure/static-web-apps-cli
# Verify: swa --version
```

### "SQL schema initialisation failed"
This can happen if your corporate network rotates egress IPs. The script handles up to 5 IPs automatically. If it still fails:
```powershell
# Find your IP
curl https://api.ipify.org
# Manually add firewall rule
az sql server firewall-rule create --resource-group clickapp-rg --server <server-name> --name manual --start-ip-address <your-ip> --end-ip-address <your-ip>
# Re-run the script
./deploy.ps1
```

### "Health check FAILED"
The API may need 30–60 seconds to cold-start after deployment. Wait and retry:
```powershell
curl https://<swa-hostname>/api/health
```

### "Deployment token is empty"
This means the SWA Bicep deployment didn't return the expected output. Check the Azure Portal → Resource Group → Static Web App → Overview → Manage deployment token.

---

## Estimated Cost

| Resource | Monthly Cost (approx.) |
|----------|----------------------|
| SQL Database (Basic) | ~$5 |
| Storage Account | ~$0.05 |
| Function App (Consumption) | Free up to 1M executions |
| Static Web App (Standard) | ~$9 |
| **Total** | **~$15/month** |

> 💡 Remember to [clean up](#cleanup) resources when done to avoid charges.

---

## Cleanup

```powershell
az group delete --name clickapp-rg --yes --no-wait
```

---

## Next Steps

After the base application is working, continue with the security modules:

- **[Module 2: Network Security (NSG)](02-deploy-nsg.md)** — Isolate API and SQL with VNet, NSGs, and Private Endpoints
- **[Module 3: Web Application Firewall](03-deploy-waf.md)** — Protect against OWASP Top 10 threats with Azure Front Door + WAF
