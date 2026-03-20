<#
.SYNOPSIS
    Deploys Azure WAF with Front Door for the Click Counter application.

.DESCRIPTION
    Creates an Azure Front Door Premium profile with a shared WAF policy
    protecting both the Static Web App (web) and Function App (API).

    - Shared WAF policy with OWASP DRS 2.1 + Bot Manager 1.1
    - Rate limiting rule (1000 req/min per IP)
    - Front Door with separate origin groups for Web and API
    - Path-based routing: /api/* → Function App, /* → SWA
    - WAF security policy applied to all traffic

.PARAMETER Prefix
    Resource naming prefix. Default: clickapp

.PARAMETER ResourceGroupName
    Resource group name. Default: {Prefix}-rg

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current az CLI subscription.
#>

[CmdletBinding()]
param(
    [string]$Prefix = "clickapp",
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

$rgExists = az group exists --name $ResourceGroupName --subscription $SubscriptionId
if ($rgExists -ne "true") {
    Write-Err "Resource group '$ResourceGroupName' does not exist. Deploy the application first using deploy.ps1."
    exit 1
}
Write-Ok "Resource group exists"

# Find Static Web App
$swaName = az resource list --resource-group $ResourceGroupName --subscription $SubscriptionId --resource-type "Microsoft.Web/staticSites" --query "[0].name" -o tsv

if ([string]::IsNullOrEmpty($swaName)) {
    Write-Err "No Static Web App found in resource group '$ResourceGroupName'."
    exit 1
}

$swaHostname = az staticwebapp show --name $swaName --resource-group $ResourceGroupName --subscription $SubscriptionId --query "defaultHostname" -o tsv
Write-Ok "Static Web App: $swaName ($swaHostname)"

# Find Function App
$functionAppName = az resource list --resource-group $ResourceGroupName --subscription $SubscriptionId --resource-type "Microsoft.Web/sites" --query "[0].name" -o tsv

if ([string]::IsNullOrEmpty($functionAppName)) {
    Write-Err "No Function App found in resource group '$ResourceGroupName'."
    exit 1
}

$functionAppHostname = az functionapp show --name $functionAppName --resource-group $ResourceGroupName --subscription $SubscriptionId --query "defaultHostName" -o tsv
Write-Ok "Function App: $functionAppName ($functionAppHostname)"

# Detect resource group location for Log Analytics workspace
$rgLocation = az group show --name $ResourceGroupName --subscription $SubscriptionId --query location -o tsv
if ([string]::IsNullOrEmpty($rgLocation)) { $rgLocation = "eastus2" }
Write-Ok "Resource group region: $rgLocation"

# If Log Analytics Workspace already exists, use its location to avoid conflict
$existingLawLocation = az monitor log-analytics workspace show `
    --resource-group $ResourceGroupName `
    --workspace-name "$Prefix-waf-law" `
    --subscription $SubscriptionId `
    --query location -o tsv 2>$null
if (-not [string]::IsNullOrEmpty($existingLawLocation)) {
    $rgLocation = $existingLawLocation
    Write-Ok "Using existing Log Analytics Workspace location: $rgLocation"
}

# ─────────────────────────────────────────────
# 3. Deploy WAF + Front Door
# ─────────────────────────────────────────────
Write-Step "Deploying Azure WAF with Front Door"
Write-Info "This may take several minutes as Front Door provisioning can be slow..."

$errFile = [System.IO.Path]::GetTempFileName()
$deploymentJson = az deployment group create `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --template-file "$scriptRoot/main.bicep" `
    --parameters `
        prefix=$Prefix `
        location=$rgLocation `
        swaHostname=$swaHostname `
        functionAppHostname=$functionAppHostname `
    --query "properties.outputs" `
    -o json 2>$errFile

if ($LASTEXITCODE -ne 0) {
    Write-Err "WAF Bicep deployment failed."
    Get-Content $errFile | ForEach-Object { Write-Err "ERROR: $_" }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item $errFile -Force -ErrorAction SilentlyContinue

$outputs = $deploymentJson | ConvertFrom-Json

$wafPolicyName = $outputs.wafPolicyName.value
$frontDoorName = $outputs.frontDoorName.value
$frontDoorEndpoint = $outputs.frontDoorEndpoint.value
$logAnalyticsName = $outputs.logAnalyticsWorkspaceName.value

Write-Ok "WAF Policy:     $wafPolicyName"
Write-Ok "Front Door:     $frontDoorName"
Write-Ok "Endpoint:       https://$frontDoorEndpoint"
Write-Ok "Log Analytics:  $logAnalyticsName"

# ─────────────────────────────────────────────
# 4. Verify WAF deployment
# ─────────────────────────────────────────────
Write-Step "Verifying WAF deployment"

# Check WAF policy — use Front Door Standard/Premium commands
$wafCheck = $null
try {
    $wafCheck = az afd profile show --resource-group $ResourceGroupName --profile-name $frontDoorName --subscription $SubscriptionId --query "sku.name" -o tsv 2>$null
} catch { }
if (-not [string]::IsNullOrEmpty($wafCheck)) {
    Write-Ok "Front Door profile deployed: $wafCheck"
} else {
    Write-Err "Could not verify Front Door profile"
}

# Check Front Door endpoint
$endpointState = az afd endpoint show --resource-group $ResourceGroupName --profile-name $frontDoorName --endpoint-name "$Prefix-web-ep" --subscription $SubscriptionId --query "enabledState" -o tsv 2>$null
if ($endpointState -eq "Enabled") {
    Write-Ok "Front Door endpoint is enabled"
} else {
    Write-Info "Endpoint state: $endpointState"
}

# Check origin groups
$originGroups = az afd origin-group list --resource-group $ResourceGroupName --profile-name $frontDoorName --subscription $SubscriptionId --query "length(@)" -o tsv 2>$null
Write-Ok "Origin groups configured: $originGroups"

# Check security policies
$secPolicies = az afd security-policy list --resource-group $ResourceGroupName --profile-name $frontDoorName --subscription $SubscriptionId --query "length(@)" -o tsv 2>$null
Write-Ok "Security policies (WAF): $secPolicies"

# ─────────────────────────────────────────────
# 5. Health Check via Front Door
# ─────────────────────────────────────────────
Write-Step "Running health checks via Front Door endpoint"

$frontDoorUrl = "https://$frontDoorEndpoint"
$maxRetries = 10
$retryDelay = 20

Write-Info "Waiting for Front Door to propagate (this can take a few minutes)..."
Start-Sleep -Seconds 30

# Web health check
$webHealthy = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $webResponse = Invoke-WebRequest -Uri $frontDoorUrl -UseBasicParsing -TimeoutSec 15
        if ($webResponse.StatusCode -eq 200) {
            $webHealthy = $true
            break
        }
    } catch {
        Write-Info "Web check attempt $i/$maxRetries — retrying in ${retryDelay}s..."
        Start-Sleep -Seconds $retryDelay
    }
}

if ($webHealthy) {
    Write-Ok "Web via Front Door: PASSED ($frontDoorUrl)"
} else {
    Write-Err "Web via Front Door: FAILED — may need more propagation time"
}

# API health check
$apiHealthy = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $healthResponse = Invoke-RestMethod -Uri "$frontDoorUrl/api/health" -TimeoutSec 15
        if ($healthResponse.status -eq "healthy") {
            $apiHealthy = $true
            break
        }
    } catch {
        Write-Info "API health check attempt $i/$maxRetries — retrying in ${retryDelay}s..."
        Start-Sleep -Seconds $retryDelay
    }
}

if ($apiHealthy) {
    Write-Ok "API via Front Door: PASSED ($frontDoorUrl/api/health)"
    Write-Ok "  Database: $($healthResponse.database)"
    Write-Ok "  Timestamp: $($healthResponse.timestamp)"
} else {
    Write-Err "API via Front Door: FAILED — may need more propagation time"
    Write-Info "Front Door can take up to 10 minutes to fully propagate. Try: curl https://$frontDoorEndpoint/api/health"
}

# ─────────────────────────────────────────────
# 6. Summary
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  WAF SECURITY DEPLOYMENT COMPLETE" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Subscription:        $SubscriptionId"
Write-Host "  Resource Group:      $ResourceGroupName"
Write-Host ""
Write-Host "  Front Door:          $frontDoorName (Premium)" -ForegroundColor Yellow
Write-Host "  Endpoint URL:        https://$frontDoorEndpoint" -ForegroundColor Yellow
Write-Host ""
Write-Host "  WAF Policy:          $wafPolicyName" -ForegroundColor Yellow
Write-Host "    Mode:              Prevention"
Write-Host "    Managed Rules:     OWASP DRS 2.1 + Bot Manager 1.1"
Write-Host "    Rate Limiting:     1000 req/min per IP"
Write-Host ""
Write-Host "  Log Analytics:       $logAnalyticsName" -ForegroundColor Yellow
Write-Host "    WAF Logs:          FrontDoorWebApplicationFirewallLog"
Write-Host "    Access Logs:       FrontDoorAccessLog"
Write-Host ""
Write-Host "  Routes:" -ForegroundColor Yellow
Write-Host "    /*       -> Static Web App ($swaHostname)"
Write-Host "    /api/*   -> Function App ($functionAppHostname)"
Write-Host ""
Write-Host "  Web Status:     $(if ($webHealthy) { 'HEALTHY' } else { 'PENDING' })" -ForegroundColor $(if ($webHealthy) { 'Green' } else { 'Yellow' })
Write-Host "  API Status:     $(if ($apiHealthy) { 'HEALTHY' } else { 'PENDING' })" -ForegroundColor $(if ($apiHealthy) { 'Green' } else { 'Yellow' })
Write-Host ""
Write-Host "  Access your app via: https://$frontDoorEndpoint" -ForegroundColor Green
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
