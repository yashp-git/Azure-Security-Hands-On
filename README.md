# Azure Click Counter

A minimal end-to-end Azure application: **Static Web App** frontend, **Azure Functions (.NET 8)** API, and **Azure SQL Database** — deployed entirely with **Bicep** and a single PowerShell script.

## Architecture

```
┌──────────────────┐     ┌────────────────────┐     ┌─────────────────┐
│  Azure Static    │────▶│  Azure Functions    │────▶│   Azure SQL     │
│  Web App (SWA)   │ API │  (.NET 8 Isolated)  │ MI  │   Database      │
│  Free Tier       │     │  Consumption Plan   │     │   Basic Tier    │
└──────────────────┘     └────────────────────┘     └─────────────────┘
   HTML/CSS/JS              C# / ADO.NET              Managed Identity
   Linked Backend           POST /api/click           (AAD-only auth)
                            GET  /api/count
                            GET  /api/health
```

## Prerequisites

| Tool | Install |
|------|---------|
| Azure CLI | https://aka.ms/installazurecli |
| .NET 8 SDK | https://dot.net |
| SWA CLI | `npm install -g @azure/static-web-apps-cli` |

You must be logged in to Azure CLI (`az login`) with permissions to create resources and be an AAD admin on the SQL server.

## Quick Start

```powershell
# Deploy everything with defaults (prefix=clickapp, region=eastus2)
./deploy.ps1

# Specify tenant and subscription explicitly
./deploy.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
             -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

# Full customisation
./deploy.ps1 -Prefix "myapp" -Location "westus2" -ResourceGroupName "my-rg" `
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

The script will:
1. Create all Azure resources via Bicep
2. Initialise the SQL schema
3. Grant the Function App's Managed Identity access to SQL
4. Build and deploy the Functions API
5. Deploy the Static Web App content
6. Run health checks to validate the deployment

## Project Structure

```
├── infra/
│   ├── main.bicep                 # Bicep orchestrator
│   └── modules/
│       ├── sql.bicep              # SQL Server + Database
│       ├── function-app.bicep     # Functions + Storage + Plan
│       └── static-web-app.bicep   # SWA + Linked Backend
├── src/
│   ├── api/                       # Azure Functions (.NET 8)
│   │   ├── Functions/             # HTTP trigger functions
│   │   ├── Models/                # Data models
│   │   └── Services/              # Database service
│   └── web/                       # Static Web App frontend
│       ├── index.html
│       ├── css/styles.css
│       └── js/app.js
├── sql/
│   └── init.sql                   # Database schema
├── deploy.ps1                     # Deployment automation
└── README.md
```

## Cleanup

```powershell
az group delete --name clickapp-rg --yes --no-wait
```
