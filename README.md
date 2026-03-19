# Azure Security Hands-On Lab

A hands-on lab for deploying a secure 3-tier Azure application with layered security controls. Build and protect a **Static Web App** frontend, **Azure Functions (.NET 8)** API, and **Azure SQL Database** using **NSGs**, **Private Endpoints**, and **Azure WAF with Front Door**.

## Architecture Overview

The lab is structured in three independent modules that build on each other:

```
Module 1 — Base Application
┌──────────────────┐       ┌────────────────────┐       ┌─────────────────┐
│  Azure Static    │──────>│  Azure Functions   │──────>│   Azure SQL     │
│  Web App (SWA)   │  API  │  (.NET 8 Isolated) │   MI  │   Database      │
│  Standard Tier   │       │  Consumption Plan  │       │   Basic Tier    │
└──────────────────┘       └────────────────────┘       └─────────────────┘

Module 2 — Network Security (NSG)                Module 3 — WAF (Front Door)
┌───────────────────────────────┐                ┌────────────────────────────┐
│  VNet + Subnets               │                │  Azure Front Door Premium  │
│  ├─ api-subnet (10.0.1.0/24)  │                │  ├─ WAF Policy (OWASP 2.1) │
│  └─ sql-subnet (10.0.2.0/24)  │                │  ├─ Bot Manager 1.1        │
│  NSG: Web → API (443 only)    │                │  ├─ Rate Limiting          │
│  NSG: API → SQL (1433 only)   │                │  └─ Log Analytics          │
│  SQL Private Endpoint         │                │  Routes: /* → SWA          │
│  Function App VNet Integration│                │          /api/* → Func App │
└───────────────────────────────┘                └────────────────────────────┘
```

## Lab Modules

Complete the modules in order. Module 1 is required; Modules 2 and 3 are independent of each other.

| # | Module | Guide | Script | What You'll Learn |
|---|--------|-------|--------|-------------------|
| 1 | **Deploy Application** | [docs/01-deploy-app.md](docs/01-deploy-app.md) | `./deploy.ps1` | Bicep IaC, Managed Identity, AAD-only SQL, SWA linked backend |
| 2 | **Network Security (NSG)** | [docs/02-deploy-nsg.md](docs/02-deploy-nsg.md) | `./security/network-security-group/deploy-nsg.ps1` | VNet isolation, NSG rules, Private Endpoints, zero-trust networking |
| 3 | **Web Application Firewall** | [docs/03-deploy-waf.md](docs/03-deploy-waf.md) | `./security/web-application-firewall/deploy-waf.ps1` | Azure Front Door, WAF policies, OWASP Top 10, bot protection |

## Prerequisites

| Tool | Install | Required For |
|------|---------|-------------|
| Azure CLI | https://aka.ms/installazurecli | All modules |
| .NET 8 SDK | https://dot.net | Module 1 (API build) |
| SWA CLI | `npm install -g @azure/static-web-apps-cli` | Module 1 (web deploy) |
| Node.js | https://nodejs.org | Module 1 (SWA CLI dependency) |
| Azure subscription | https://azure.microsoft.com/free | All modules |

You must be logged in to Azure CLI (`az login`) with permissions to create resources and be an AAD admin on the SQL server.

## Key Design Decisions

- **Managed Identity** — Function App authenticates to SQL via System-Assigned Managed Identity. No passwords stored anywhere.
- **AAD-only SQL** — SQL Server has `azureADOnlyAuthentication: true`. No SQL auth enabled.
- **Linked Backend** — SWA routes `/api/*` to Function App via `linkedBackends` resource. No CORS needed.
- **Parameterized queries** — All SQL queries use `@parameters` to prevent SQL injection.
- **TLS 1.2+** enforced on SQL Server, Storage Account, and Function App.
- **Prevention mode WAF** — WAF blocks (not just logs) malicious requests.

## Project Structure

```
├── infra/                            # Module 1: Base infrastructure (Bicep)
│   ├── main.bicep
│   └── modules/
│       ├── sql.bicep                 #   SQL Server (AAD-only) + Database (Basic)
│       ├── function-app.bicep        #   Storage + Consumption Plan + Function App
│       └── static-web-app.bicep      #   SWA (Standard) + Linked Backend
├── security/
│   ├── network-security-group/       # Module 2: NSG + VNet + Private Endpoint
│   │   ├── deploy-nsg.ps1
│   │   ├── main.bicep
│   │   └── modules/
│   │       ├── vnet.bicep            #   VNet with api-subnet + sql-subnet
│   │       ├── web-api-nsg.bicep     #   NSG: Allow HTTPS → API subnet
│   │       ├── api-sql-nsg.bicep     #   NSG: Allow 1433 → SQL subnet
│   │       ├── sql-private-endpoint.bicep  # SQL Private Endpoint + DNS
│   │       └── function-app-networking.bicep # VNet integration + plan upgrade
│   └── web-application-firewall/     # Module 3: WAF + Front Door
│       ├── deploy-waf.ps1
│       ├── main.bicep                #   Orchestrator + Log Analytics + diagnostics
│       └── modules/
│           ├── waf-policy.bicep      #   WAF policy (OWASP DRS 2.1 + Bot Manager)
│           └── front-door.bicep      #   Front Door Premium + routing + security
├── src/
│   ├── api/                          # Azure Functions API (.NET 8 Isolated)
│   │   ├── Functions/
│   │   │   ├── ClickFunction.cs      #   POST /api/click
│   │   │   ├── CountFunction.cs      #   GET  /api/count
│   │   │   └── HealthFunction.cs     #   GET  /api/health
│   │   ├── Models/ClickRecord.cs
│   │   ├── Services/DatabaseService.cs
│   │   └── ClickCounter.Api.csproj
│   └── web/                          # Static Web App frontend
│       ├── index.html
│       ├── staticwebapp.config.json
│       ├── css/styles.css
│       └── js/app.js
├── sql/init.sql                      # Database schema (idempotent)
├── docs/                             # Lab guides
│   ├── 01-deploy-app.md
│   ├── 02-deploy-nsg.md
│   └── 03-deploy-waf.md
├── deploy.ps1                        # Module 1 deployment script
└── README.md                         # This file
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/click` | POST | Records a click. Accepts optional `{ "ipAddress": "x.x.x.x" }` body. Returns `{ totalCount, ipCount, ipAddress }` |
| `/api/count` | GET | Returns current counts. Optional `?ip=x.x.x.x` query. Returns `{ totalCount, ipCount, ipAddress }` |
| `/api/health` | GET | Database connectivity check. Returns 200 `{ "status": "healthy" }` or 503 |

## SQL Schema

**Table: `dbo.ClickRecords`**

| Column | Type | Notes |
|--------|------|-------|
| `Id` | `INT IDENTITY(1,1)` | Primary key |
| `IpAddress` | `NVARCHAR(45)` | Supports IPv4 and IPv6 |
| `ClickedAt` | `DATETIME2(3)` | UTC timestamp, defaults to `GETUTCDATE()` |

## Cleanup

Remove all resources when done:

```powershell
az group delete --name clickapp-rg --yes --no-wait
```
