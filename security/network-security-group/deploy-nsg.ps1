<#
.SYNOPSIS
    Deploys NSG security infrastructure for the Click Counter application.

.DESCRIPTION
    Creates VNet, subnets, NSGs, SQL private endpoint, and configures
    Function App VNet integration. This is a standalone security deployment
    that layers on top of the existing application infrastructure.

    - NSG 1 (api-sql-nsg): Isolates SQL — only API subnet on port 1433
    - NSG 2 (web-api-nsg): Protects API — allows HTTPS from internet, denies all else
    - VNet with api-subnet and sql-subnet
    - SQL Server private endpoint with Private DNS
    - Function App VNet integration (upgrades plan to EP1)

.PARAMETER Prefix
    Resource naming prefix. Default: clickapp

.PARAMETER Location
    Azure region. Default: eastus2

.PARAMETER ResourceGroupName
    Resource group name. Default: {Prefix}-rg

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current az CLI subscription.
#>

[CmdletBinding()]
param(
    [string]$Prefix = "clickapp",
    [string]$Location = "eastus2",
    [string]$ResourceGroupName = "",
    [string]$SubscriptionId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ([string]::IsNullOrEmpty($ResourceGroupName)) {
    $ResourceGroupName = "$Prefix-rg"
}

# ─────────────────────────────────────────────
# Helper: Write coloured status messages
# ─────────────────────────────────────────────
function Write-Step { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Err  { param([string]$msg) Write-Host "   [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param([string]$msg) Write-Host "   $msg" -ForegroundColor Gray }

# ─────────────────────────────────────────────
# 1. Prerequisites
# ─────────────────────────────────────────────
Write-Step "Checking prerequisites"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
    exit 1
}
Write-Ok "Azure CLI found"

$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Ok "Azure CLI logged in"

if (-not [string]::IsNullOrEmpty($SubscriptionId)) {
    Write-Info "Setting subscription: $SubscriptionId"
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to set subscription $SubscriptionId."
        exit 1
    }
    Write-Ok "Subscription set: $SubscriptionId"
} else {
    $SubscriptionId = az account show --query id -o tsv
}

Write-Ok "Active subscription: $SubscriptionId"

# ─────────────────────────────────────────────
# 2. Discover existing resources
# ─────────────────────────────────────────────
Write-Step "Discovering existing resources in $ResourceGroupName"

# Verify resource group exists
$rgExists = az group exists --name $ResourceGroupName --subscription $SubscriptionId
if ($rgExists -ne "true") {
    Write-Err "Resource group '$ResourceGroupName' does not exist. Deploy the application first using deploy.ps1."
    exit 1
}
Write-Ok "Resource group exists"

# Auto-detect location from existing resources — VNet integration requires
# the VNet to be in the same region as the App Service Plan / Function App
$funcLocation = az resource list `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --resource-type "Microsoft.Web/sites" `
    --query "[0].location" -o tsv 2>$null

if (-not [string]::IsNullOrEmpty($funcLocation)) {
    $Location = $funcLocation
    Write-Ok "Using Function App location: $Location"
} else {
    Write-Info "Using default location: $Location"
}

# Find SQL Server
$sqlServerName = az resource list `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --resource-type "Microsoft.Sql/servers" `
    --query "[0].name" -o tsv

if ([string]::IsNullOrEmpty($sqlServerName)) {
    Write-Err "No SQL Server found in resource group '$ResourceGroupName'."
    exit 1
}
Write-Ok "SQL Server: $sqlServerName"

# Find SQL Database
$sqlDatabaseName = az sql db list `
    --resource-group $ResourceGroupName `
    --server $sqlServerName `
    --subscription $SubscriptionId `
    --query "[?name != 'master'].name | [0]" -o tsv

if ([string]::IsNullOrEmpty($sqlDatabaseName)) {
    Write-Err "No SQL Database found on server '$sqlServerName'."
    exit 1
}
Write-Ok "SQL Database: $sqlDatabaseName"

# Find Function App
$functionAppName = az resource list `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --resource-type "Microsoft.Web/sites" `
    --query "[0].name" -o tsv

if ([string]::IsNullOrEmpty($functionAppName)) {
    Write-Err "No Function App found in resource group '$ResourceGroupName'."
    exit 1
}
Write-Ok "Function App: $functionAppName"

# Find App Service Plan
$appServicePlanName = az resource list `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --resource-type "Microsoft.Web/serverfarms" `
    --query "[0].name" -o tsv

if ([string]::IsNullOrEmpty($appServicePlanName)) {
    Write-Err "No App Service Plan found in resource group '$ResourceGroupName'."
    exit 1
}
Write-Ok "App Service Plan: $appServicePlanName"

# Detect App Service Plan location (may differ from resource group / VNet location)
$appServicePlanLocation = az resource show `
    --resource-group $ResourceGroupName `
    --name $appServicePlanName `
    --resource-type "Microsoft.Web/serverfarms" `
    --subscription $SubscriptionId `
    --query location -o tsv

if ([string]::IsNullOrEmpty($appServicePlanLocation)) {
    $appServicePlanLocation = $Location
    Write-Info "Could not detect plan location, using: $appServicePlanLocation"
} else {
    Write-Ok "App Service Plan location: $appServicePlanLocation"
}

# Find Storage Account
$storageAccountName = az resource list `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --resource-type "Microsoft.Storage/storageAccounts" `
    --query "[0].name" -o tsv

if ([string]::IsNullOrEmpty($storageAccountName)) {
    Write-Err "No Storage Account found in resource group '$ResourceGroupName'."
    exit 1
}
Write-Ok "Storage Account: $storageAccountName"

# Find SWA hostname for health check
$swaHostname = az resource list `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --resource-type "Microsoft.Web/staticSites" `
    --query "[0].name" -o tsv

if (-not [string]::IsNullOrEmpty($swaHostname)) {
    $swaHostname = az staticwebapp show `
        --name $swaHostname `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --query "defaultHostname" -o tsv
    Write-Ok "SWA Hostname: $swaHostname"
} else {
    Write-Info "No Static Web App found — health check will be skipped."
}

# ─────────────────────────────────────────────
# 3. Deploy NSG Security Infrastructure
# ─────────────────────────────────────────────
Write-Step "Deploying NSG security infrastructure"

$errFile = [System.IO.Path]::GetTempFileName()
$deploymentJson = az deployment group create `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --template-file "$scriptRoot/main.bicep" `
    --parameters `
        prefix=$Prefix `
        location=$Location `
        sqlServerName=$sqlServerName `
        sqlDatabaseName=$sqlDatabaseName `
        functionAppName=$functionAppName `
        appServicePlanName=$appServicePlanName `
        appServicePlanLocation=$appServicePlanLocation `
        storageAccountName=$storageAccountName `
    --query "properties.outputs" `
    -o json 2>$errFile

if ($LASTEXITCODE -ne 0) {
    Write-Err "NSG Bicep deployment failed."
    Get-Content $errFile | ForEach-Object { Write-Err "ERROR: $_" }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item $errFile -Force -ErrorAction SilentlyContinue

$outputs = $deploymentJson | ConvertFrom-Json

Write-Ok "VNet:                $($outputs.vnetName.value)"
Write-Ok "API-SQL NSG:         $($outputs.apiSqlNsgName.value)"
Write-Ok "Web-API NSG:         $($outputs.webApiNsgName.value)"
Write-Ok "SQL Private Endpoint: $($outputs.sqlPrivateEndpointName.value)"
Write-Ok "Function App VNet:   $($outputs.functionAppVnetIntegrated.value)"

# ─────────────────────────────────────────────
# 4. Remove AllowAzureServices SQL firewall rule
# ─────────────────────────────────────────────
Write-Step "Removing AllowAzureServices SQL firewall rule (replaced by private endpoint)"

az sql server firewall-rule delete `
    --resource-group $ResourceGroupName `
    --server $sqlServerName `
    --subscription $SubscriptionId `
    --name "AllowAzureServices" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Ok "AllowAzureServices firewall rule removed"
} else {
    Write-Info "AllowAzureServices rule not found or already removed"
}

# ─────────────────────────────────────────────
# 5. Verify NSG deployment
# ─────────────────────────────────────────────
Write-Step "Verifying NSG deployment"

# Check API-SQL NSG
$apiSqlRules = az network nsg rule list --resource-group $ResourceGroupName --nsg-name "$Prefix-api-sql-nsg" --subscription $SubscriptionId --query "length(@)" -o tsv

if ($apiSqlRules -ge 2) {
    Write-Ok "API-SQL NSG: $apiSqlRules rules configured"
} else {
    Write-Err "API-SQL NSG: Expected at least 2 rules, found $apiSqlRules"
}

# Check Web-API NSG
$webApiRules = az network nsg rule list --resource-group $ResourceGroupName --nsg-name "$Prefix-web-api-nsg" --subscription $SubscriptionId --query "length(@)" -o tsv

if ($webApiRules -ge 3) {
    Write-Ok "Web-API NSG: $webApiRules rules configured"
} else {
    Write-Err "Web-API NSG: Expected at least 3 rules, found $webApiRules"
}

# Check VNet integration
$vnetIntegration = az functionapp vnet-integration list --resource-group $ResourceGroupName --name $functionAppName --subscription $SubscriptionId --query "length(@)" -o tsv

if ($vnetIntegration -ge 1) {
    Write-Ok "Function App VNet integration active"
} else {
    Write-Err "Function App VNet integration not detected"
}

# ─────────────────────────────────────────────
# 6. Health Check
# ─────────────────────────────────────────────
if (-not [string]::IsNullOrEmpty($swaHostname)) {
    Write-Step "Running post-deployment health check"

    $swaBaseUrl = "https://$swaHostname"
    $maxRetries = 8
    $retryDelay = 20

    Write-Info "Waiting for VNet integration to stabilise..."
    Start-Sleep -Seconds 30

    $apiHealthy = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $healthResponse = Invoke-RestMethod -Uri "$swaBaseUrl/api/health" -TimeoutSec 15
            if ($healthResponse.status -eq "healthy") {
                $apiHealthy = $true
                break
            }
        } catch {
            Write-Info "Health check attempt $i/$maxRetries — retrying in ${retryDelay}s..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    if ($apiHealthy) {
        Write-Ok "API Health Check PASSED — /api/health returned 'healthy'"
        Write-Ok "  Database: $($healthResponse.database)"
        Write-Ok "  Timestamp: $($healthResponse.timestamp)"
    } else {
        Write-Err "API Health Check FAILED — /api/health did not return 'healthy'"
        Write-Err "The API may need more time to stabilise after VNet integration. Try again in a few minutes."
    }
} else {
    Write-Info "Skipping health check — no SWA hostname found."
}

# ─────────────────────────────────────────────
# 7. Summary
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  NSG SECURITY DEPLOYMENT COMPLETE" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Subscription:        $SubscriptionId"
Write-Host "  Resource Group:      $ResourceGroupName"
Write-Host "  Region:              $Location"
Write-Host ""
Write-Host "  VNet:                $Prefix-vnet (10.0.0.0/16)"
Write-Host "    api-subnet:        10.0.1.0/24" -ForegroundColor Yellow
Write-Host "    sql-subnet:        10.0.2.0/24" -ForegroundColor Yellow
Write-Host ""
Write-Host "  NSG (API-SQL):       $Prefix-api-sql-nsg" -ForegroundColor Yellow
Write-Host "    Allow TCP 1433 from api-subnet only"
Write-Host "    Deny all other inbound"
Write-Host ""
Write-Host "  NSG (Web-API):       $Prefix-web-api-nsg" -ForegroundColor Yellow
Write-Host "    Allow HTTPS 443 from internet (*)"
Write-Host "    Allow VirtualNetwork inbound"
Write-Host "    Deny all other inbound"
Write-Host ""
Write-Host "  SQL Private Endpoint: $Prefix-sql-pe" -ForegroundColor Yellow
Write-Host "  Function App VNet:   Integrated (EP1 plan)" -ForegroundColor Yellow
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
