# Azure Click Counter

A minimal end-to-end Azure application: **Static Web App** frontend, **Azure Functions (.NET 8)** API, and **Azure SQL Database** — deployed entirely with **Bicep** and a single PowerShell script.

Each visitor sees their public IP address and a click button. Clicks are recorded per-IP in SQL and the total count is shown in near real-time.

## Architecture

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

**Key design decisions:**

- **Managed Identity** — Function App authenticates to SQL via System-Assigned Managed Identity (`Authentication=Active Directory Default`). No passwords stored anywhere.
- **AAD-only SQL** — SQL Server has `azureADOnlyAuthentication: true`. No SQL auth enabled.
- **Linked Backend** — SWA routes `/api/*` to Function App via `linkedBackends` resource. No CORS configuration needed.
- **Client IP detection** — Frontend detects the visitor's public IP via `api.ipify.org` and passes it to the API. Backend accepts it via body/query parameter and validates via proxy headers as fallback.
- **TLS 1.2+** enforced on SQL Server, Storage Account, and Function App.

## Prerequisites

| Tool | Install |
|------|---------|
| Azure CLI | https://aka.ms/installazurecli |
| .NET 8 SDK | https://dot.net |
| SWA CLI | `npm install -g @azure/static-web-apps-cli` |
| Node.js | https://nodejs.org (required for SWA CLI) |

You must be logged in to Azure CLI (`az login`) with permissions to create resources and be an AAD admin on the SQL server.

## Quick Start

```powershell
# Deploy everything with defaults (prefix=clickapp, region=eastus2)
./deploy.ps1

# Specify tenant and subscription explicitly
./deploy.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
             -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

# Full customisation
./deploy.ps1 -Prefix "myapp" -Location "centralus" -ResourceGroupName "my-rg" `
             -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
             -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Prefix` | `clickapp` | Resource naming prefix |
| `-Location` | `eastus2` | Azure region |
| `-ResourceGroupName` | `{Prefix}-rg` | Resource group name |
| `-TenantId` | *(current CLI tenant)* | Azure AD tenant ID |
| `-SubscriptionId` | *(current CLI subscription)* | Azure subscription ID |

### What the script does

1. Validates prerequisites (`az`, `dotnet`, `swa` CLI)
2. Sets tenant and subscription context (if provided)
3. Creates the resource group
4. Deploys all Azure resources via Bicep (SQL → Functions → SWA)
5. Adds temporary firewall rules for deployer IP (handles corporate multi-IP egress)
6. Initialises SQL schema (`dbo.ClickRecords` table)
7. Creates Managed Identity database user with `db_datareader` + `db_datawriter` roles
8. Removes deployer firewall rules
9. Builds and deploys the Azure Functions API (zip deploy)
10. Deploys Static Web App content via SWA CLI
11. Runs post-deployment health checks (web HTTP 200 + API `/api/health` returns healthy)
12. Prints deployment summary with all URLs

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/click` | POST | Records a click. Accepts optional `{ "ipAddress": "x.x.x.x" }` in body. Returns `{ totalCount, ipCount, ipAddress }` |
| `/api/count` | GET | Returns current counts. Accepts optional `?ip=x.x.x.x` query parameter. Returns `{ totalCount, ipCount, ipAddress }` |
| `/api/health` | GET | Database connectivity check. Returns 200 `{ "status": "healthy", "database": "connected" }` or 503 if unavailable |

## Project Structure

```
├── infra/
│   ├── main.bicep                    # Bicep orchestrator
│   └── modules/
│       ├── sql.bicep                 # SQL Server (AAD-only) + Database (Basic)
│       ├── function-app.bicep        # Storage + Consumption Plan + Function App + MI
│       └── static-web-app.bicep      # SWA (Standard) + Linked Backend
├── src/
│   ├── api/                          # Azure Functions (.NET 8 Isolated)
│   │   ├── Functions/
│   │   │   ├── ClickFunction.cs      # POST /api/click
│   │   │   ├── CountFunction.cs      # GET  /api/count
│   │   │   └── HealthFunction.cs     # GET  /api/health
│   │   ├── Models/
│   │   │   └── ClickRecord.cs        # Data model
│   │   ├── Services/
│   │   │   └── DatabaseService.cs    # ADO.NET data access (parameterized queries)
│   │   ├── ClickCounter.Api.csproj
│   │   ├── Program.cs
│   │   └── host.json
│   └── web/                          # Static Web App frontend
│       ├── index.html
│       ├── staticwebapp.config.json  # SWA routing config
│       ├── css/styles.css
│       └── js/app.js
├── sql/
│   └── init.sql                      # Database schema (idempotent)
├── deploy.ps1                        # Deployment automation
├── .gitignore
└── README.md
```

## SQL Schema

**Table: `dbo.ClickRecords`**

| Column | Type | Notes |
|--------|------|-------|
| `Id` | `INT IDENTITY(1,1)` | Primary key |
| `IpAddress` | `NVARCHAR(45)` | Supports IPv4 and IPv6 |
| `ClickedAt` | `DATETIME2(3)` | UTC timestamp, defaults to `GETUTCDATE()` |

Nonclustered index on `IpAddress` (includes `ClickedAt`) for efficient count queries.

## Cleanup

```powershell
az group delete --name clickapp-rg --yes --no-wait
```
