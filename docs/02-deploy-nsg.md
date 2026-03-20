# Module 2: Network Security (NSG)

Isolate the API and SQL tiers using a **Virtual Network**, **Network Security Groups**, **SQL Private Endpoint**, and **Function App VNet Integration** — so that only the Web tier can talk to the API, and only the API can talk to SQL. All other traffic is denied by default.

## Prerequisites

- ✅ **Module 1 completed** — The base application must be deployed and healthy. Run `./deploy.ps1` first (see [01-deploy-app.md](01-deploy-app.md)).
- ✅ Azure CLI logged in (`az login`)

> ⚠️ **Cost Warning**: This module upgrades the Function App's App Service Plan from **Consumption (Y1)** to **Elastic Premium (EP1)** because VNet integration requires a premium-tier plan. This increases the Function App cost to approximately **$150/month**. Remember to clean up when done.

---

## What You'll Deploy

```
                                    ┌─────────────────────────────────────────┐
                                    │  VNet: clickapp-vnet (10.0.0.0/16)      │
                                    │                                         │
                                    │  ┌───────────────────────────┐          │
  ┌──────────────┐                  │  │ api-subnet (10.0.1.0/24)  │          │
  │ Azure Static │   HTTPS/443      │  │                           │          │
  │ Web App      │─────────────────>│  │ Function App              │          │
  │ (Internet)   │  via Linked      │  │ (VNet Integrated)         │          │
  └──────────────┘  Backend         │  └───────────┬───────────────┘          │
                                    │              │ TCP/1433                 │
                                    │              ▼                          │
  ┌──────────────┐                  │  ┌───────────────────────────┐          │
  │ Internet     │───── X ─────────>│  │ sql-subnet (10.0.2.0/24)  │          │
  │ (Blocked)    │  Denied!         │  │                           │          │
  └──────────────┘                  │  │ SQL Private Endpoint      │          │
                                    │  │ (No public access)        │          │
                                    │  └───────────────────────────┘          │
                                    └─────────────────────────────────────────┘
```

### Resources Created

| Resource | Purpose |
|----------|---------|
| **VNet** (`clickapp-vnet`) | 10.0.0.0/16 — Isolates API and SQL from public internet |
| **api-subnet** (10.0.1.0/24) | Houses the Function App via VNet integration |
| **sql-subnet** (10.0.2.0/24) | Houses the SQL Server private endpoint |
| **NSG: web-api-nsg** | Controls traffic into api-subnet |
| **NSG: api-sql-nsg** | Controls traffic into sql-subnet |
| **SQL Private Endpoint** | Private IP for SQL Server (no public access) |
| **Private DNS Zone** | Resolves `*.database.windows.net` to private IP inside VNet |
| **App Service Plan upgrade** | Y1 → EP1 (required for VNet integration) |

---

## NSG Rules

### NSG 1: Web → API (`web-api-nsg`, attached to `api-subnet`)

| Priority | Name | Direction | Source | Destination | Port | Protocol | Action |
|----------|------|-----------|--------|-------------|------|----------|--------|
| 100 | AllowHttpsInbound | Inbound | Internet (*) | api-subnet | 443 | TCP | **Allow** |
| 110 | AllowVNetInbound | Inbound | VirtualNetwork | VirtualNetwork | * | * | **Allow** |
| 4096 | DenyAllInbound | Inbound | * | * | * | * | **Deny** |

> **Why allow internet HTTPS?** SWA linked backend routes through Azure's internal infrastructure. The Function App needs to accept HTTPS from Azure's network. When Module 3 (WAF) is deployed, Front Door provides the edge protection layer.

### NSG 2: API → SQL (`api-sql-nsg`, attached to `sql-subnet`)

| Priority | Name | Direction | Source | Destination | Port | Protocol | Action |
|----------|------|-----------|--------|-------------|------|----------|--------|
| 100 | AllowSqlFromApiSubnet | Inbound | 10.0.1.0/24 | sql-subnet | 1433 | TCP | **Allow** |
| 4096 | DenyAllInbound | Inbound | * | * | * | * | **Deny** |

> **Key point:** Only the api-subnet (10.0.1.0/24) can reach SQL on port 1433. All other traffic — including direct internet access — is denied.

### Security Model Summary

```
Internet ──HTTPS──> api-subnet (Function App)  ✅ Allowed
Internet ──────────> sql-subnet (SQL)           ❌ Denied
api-subnet ──1433──> sql-subnet (SQL)           ✅ Allowed
sql-subnet ────────> api-subnet                 ❌ Denied
Any other traffic                               ❌ Denied
```

---

## Step-by-Step Deployment

### Step 1: Verify Base Deployment

Confirm Module 1 resources exist:

```powershell
# Check resource group exists
az group exists --name clickapp-rg
# Should return: true

# Check resources are deployed
az resource list --resource-group clickapp-rg --output table
# Should show: SQL Server, SQL Database, Function App, App Service Plan, Storage Account, Static Web App
```

### Step 2: Run the NSG Deployment Script

```powershell
./security/network-security-group/deploy-nsg.ps1
```

**Custom parameters:**

```powershell
./security/network-security-group/deploy-nsg.ps1 `
    -Prefix "myapp" `
    -ResourceGroupName "my-rg" `
    -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Prefix` | `clickapp` | Must match the prefix used in Module 1 |
| `-Location` | `eastus2` | Auto-detected from existing Function App location |
| `-ResourceGroupName` | `{Prefix}-rg` | Must match Module 1 resource group |
| `-SubscriptionId` | *(current)* | Azure subscription ID |

### Step 3: What the Script Does

The script automatically:

1. ✅ Discovers existing resources (SQL Server, Function App, App Service Plan, Storage Account)
2. ✅ Auto-detects the region from the existing Function App
3. ✅ Deploys VNet, subnets, NSGs, SQL Private Endpoint, and Private DNS
4. ✅ Upgrades App Service Plan from Consumption → Elastic Premium (EP1)
5. ✅ Configures Function App VNet integration to api-subnet
6. ✅ Updates Function App connection string to use the private SQL FQDN
7. ✅ **Removes the `AllowAzureServices` SQL firewall rule** (replaced by Private Endpoint)
8. ✅ Verifies NSG rules, VNet integration, and runs health check

### Step 4: Verify the Deployment

After the script completes, you'll see:

```
============================================
  NSG SECURITY DEPLOYMENT COMPLETE
============================================

  VNet:                clickapp-vnet (10.0.0.0/16)
    api-subnet:        10.0.1.0/24
    sql-subnet:        10.0.2.0/24

  NSG (API-SQL):       clickapp-api-sql-nsg
    Allow TCP 1433 from api-subnet only
    Deny all other inbound

  NSG (Web-API):       clickapp-web-api-nsg
    Allow HTTPS 443 from internet (*)
    Allow VirtualNetwork inbound
    Deny all other inbound

  SQL Private Endpoint: clickapp-sql-pe
  Function App VNet:   Integrated (EP1 plan)
============================================
```

**Manual verification:**

```powershell
# 1. Check NSG rules
az network nsg rule list --resource-group clickapp-rg --nsg-name clickapp-api-sql-nsg --output table
az network nsg rule list --resource-group clickapp-rg --nsg-name clickapp-web-api-nsg --output table

# 2. Check VNet integration
az functionapp vnet-integration list --resource-group clickapp-rg --name <function-app-name> --output table

# 3. Check SQL private endpoint
az network private-endpoint list --resource-group clickapp-rg --output table

# 4. Verify SQL is no longer publicly accessible
az sql server firewall-rule list --resource-group clickapp-rg --server <sql-server-name> --output table
# Should show NO rules (AllowAzureServices was removed)

# 5. Test the application still works through the SWA
curl https://<swa-hostname>/api/health
# Expected: { "status": "healthy", "database": "connected" }
```

---

## How It Works

### Private Endpoint

The SQL Private Endpoint creates a network interface inside `sql-subnet` with a private IP address (e.g., `10.0.2.4`). A Private DNS Zone (`privatelink.database.windows.net`) ensures that when the Function App resolves the SQL Server FQDN (e.g., `clickapp-sql-xxx.database.windows.net`), it gets the private IP instead of the public IP.

This means:
- SQL Server is **only accessible from within the VNet**
- No public IP exposure for SQL
- The `AllowAzureServices` firewall rule is removed (no longer needed)

### VNet Integration

The Function App is integrated into `api-subnet`, which means all **outbound** traffic from the Function App goes through the VNet. This allows it to reach the SQL Private Endpoint on the internal network.

> **Note:** VNet integration requires an Elastic Premium (EP1) or higher App Service Plan. The script automatically upgrades the plan from Consumption (Y1) to EP1.

### NSG Enforcement

NSGs act as virtual firewalls at the subnet level:
- **api-subnet NSG**: Allows inbound HTTPS (443) and VNet traffic; denies everything else
- **sql-subnet NSG**: Allows inbound SQL (1433) only from api-subnet (10.0.1.0/24); denies everything else

---

## Troubleshooting

### "API health check FAILED after NSG deployment"

The Function App may need a few minutes to restart after VNet integration. Wait 2–3 minutes and retry:

```powershell
# Restart the Function App
az functionapp restart --resource-group clickapp-rg --name <function-app-name>

# Wait 30 seconds, then test
Start-Sleep -Seconds 30
curl https://<swa-hostname>/api/health
```

### "SQL connection timeout"

If the Function App can't reach SQL after VNet integration:

1. Verify the Private DNS Zone is linked to the VNet:
   ```powershell
   az network private-dns zone list --resource-group clickapp-rg --output table
   az network private-dns link vnet list --resource-group clickapp-rg --zone-name privatelink.database.windows.net --output table
   ```

2. Verify the private endpoint has a private IP:
   ```powershell
   az network private-endpoint show --resource-group clickapp-rg --name clickapp-sql-pe --query "customDnsConfigs" --output table
   ```

### "App Service Plan upgrade failed"

The plan upgrade from Y1 to EP1 requires the region to support Elastic Premium. Most regions do. If it fails, try a different region:

```powershell
./security/network-security-group/deploy-nsg.ps1 -Location "eastus"
```

---

## Estimated Additional Cost

| Resource Change | Monthly Cost (approx.) |
|----------------|----------------------|
| App Service Plan: Y1 → EP1 | +$150 |
| VNet | Free |
| NSGs | Free |
| Private Endpoint | ~$7.50 |
| Private DNS Zone | ~$0.50 |
| **Additional Total** | **~$158/month** |

> ⚠️ The EP1 plan is the largest cost driver. Remember to clean up when done.

---

## Cleanup

To remove **only** the NSG resources while keeping the base application:

> **Note:** Fully reverting NSG changes is complex (requires downgrading the plan, removing VNet integration, re-adding SQL firewall rules). The simplest approach is to delete the entire resource group:

```powershell
az group delete --name clickapp-rg --yes --no-wait
```

Then redeploy Module 1 if needed.

---

## Next Steps

- **[Module 3: Web Application Firewall](03-deploy-waf.md)** — Add Azure Front Door + WAF to protect against OWASP Top 10 threats (SQL injection, XSS, bots, DDoS)
