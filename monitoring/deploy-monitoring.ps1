<#
.SYNOPSIS
    Deploys Module 4 - Application Insights and diagnostic settings for the Click Counter demo.

.DESCRIPTION
    Configures observability across all deployed resources by:
    - Creating a workspace-based Application Insights resource linked to the existing
      Log Analytics workspace (created by Module 3)
    - Injecting Application Insights SDK settings into the Function App
    - Enabling SQL Server audit logging to Azure Monitor
    - Attaching "Log-Send-To-Workspace" diagnostic settings to every resource:
        Required:  Function App, Storage Account (+ Blob Service), App Service Plan,
                   Static Web App, SQL Database
        Optional:  VNet, NSGs (Module 2), Front Door (Module 3)
    - Re-deploying the SWA frontend with the App Insights browser SDK enabled

    Prerequisites:
    - Module 1 (base application) must be deployed
    - Module 3 (WAF) must be deployed - provides the shared Log Analytics workspace
    - Module 2 (NSG/VNet) is optional and auto-detected

.PARAMETER Prefix
    Resource naming prefix. Default: clickapp

.PARAMETER ResourceGroupName
    Resource group name. Default: {Prefix}-rg

.PARAMETER Location
    Azure region. Auto-detected from the existing Function App if omitted.

.PARAMETER SubscriptionId
    Azure subscription ID. Uses the current az CLI context if omitted.
#>

[CmdletBinding()]
param(
    [string]$Prefix = "clickapp",
    [string]$ResourceGroupName = "",
    [string]$Location = "",
    [string]$SubscriptionId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ([string]::IsNullOrEmpty($ResourceGroupName)) {
    $ResourceGroupName = "$Prefix-rg"
}

# ---------------------------------------------------------------------------
# Helper functions - output formatting (matches deploy.ps1 / deploy-nsg.ps1 / deploy-waf.ps1)
# ---------------------------------------------------------------------------
function Write-Step { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Err  { param([string]$msg) Write-Host "   [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param([string]$msg) Write-Host "   $msg" -ForegroundColor Gray }

# Run a native command without letting az CLI stderr warnings trigger ErrorActionPreference=Stop
function Invoke-Az {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $result = & az @args 2>&1
    $ec = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [PSCustomObject]@{ Output = $result; ExitCode = $ec }
}

# ---------------------------------------------------------------------------
# Step 1 - Prerequisites
# ---------------------------------------------------------------------------
Write-Step "Step 1: Checking prerequisites"

$azVersion = az version -o tsv 2>$null
if (-not $azVersion) {
    Write-Err "Azure CLI (az) not found. Install from https://aka.ms/install-azure-cli"
    exit 1
}
Write-Ok "Azure CLI $azVersion"

$swaCliVersion = npx @azure/static-web-apps-cli --version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Err "SWA CLI not found. Run: npm install -g @azure/static-web-apps-cli"
    exit 1
}
Write-Ok "SWA CLI available"

# ---------------------------------------------------------------------------
# Step 2 - Azure context
# ---------------------------------------------------------------------------
Write-Step "Step 2: Verifying Azure context"

$currentAccount = az account show --query "{name:name,id:id,tenantId:tenantId}" -o json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Err "Not logged in. Run: az login"
    exit 1
}

if (-not [string]::IsNullOrEmpty($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to set subscription $SubscriptionId"
        exit 1
    }
    $currentAccount = az account show --query "{name:name,id:id}" -o json | ConvertFrom-Json
}

$SubscriptionId = $currentAccount.id
Write-Ok "Subscription: $($currentAccount.name) ($SubscriptionId)"

# Verify resource group exists
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -ne "true") {
    Write-Err "Resource group '$ResourceGroupName' not found. Deploy Module 1 first."
    exit 1
}
Write-Ok "Resource group: $ResourceGroupName"

# ---------------------------------------------------------------------------
# Step 3 - Discover existing resources
# ---------------------------------------------------------------------------
Write-Step "Step 3: Discovering existing deployed resources"

# Function App (required)
Write-Info "Looking for Function App..."
$functionAppJson = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Web/sites" --query "[?kind=='functionapp']" -o json
$functionApps = $functionAppJson | ConvertFrom-Json
if ($functionApps.Count -eq 0) {
    Write-Err "No Function App found in '$ResourceGroupName'. Deploy Module 1 first."
    exit 1
}
$functionAppName = $functionApps[0].name
$functionAppResourceId = $functionApps[0].id
Write-Ok "Function App: $functionAppName"

# Auto-detect location from Function App
if ([string]::IsNullOrEmpty($Location)) {
    $Location = az resource show --ids $functionAppResourceId --query location -o tsv
    Write-Ok "Auto-detected region: $Location"
} else {
    Write-Ok "Region: $Location"
}

# App Service Plan (required)
Write-Info "Looking for App Service Plan..."
$appServicePlanName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Web/serverfarms" --query "[0].name" -o tsv
if ([string]::IsNullOrEmpty($appServicePlanName)) {
    Write-Err "No App Service Plan found in '$ResourceGroupName'."
    exit 1
}
Write-Ok "App Service Plan: $appServicePlanName"

# SQL Server (required)
Write-Info "Looking for SQL Server..."
$sqlServerName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Sql/servers" --query "[0].name" -o tsv
if ([string]::IsNullOrEmpty($sqlServerName)) {
    Write-Err "No SQL Server found in '$ResourceGroupName'. Deploy Module 1 first."
    exit 1
}
$sqlServerFqdn = az sql server show --name $sqlServerName --resource-group $ResourceGroupName --query fullyQualifiedDomainName -o tsv
Write-Ok "SQL Server: $sqlServerName ($sqlServerFqdn)"

# SQL Database (required)
Write-Info "Looking for SQL Database..."
$sqlDatabaseName = az sql db list --server $sqlServerName --resource-group $ResourceGroupName --query "[?name!='master'].name" -o tsv | Select-Object -First 1
if ([string]::IsNullOrEmpty($sqlDatabaseName)) {
    Write-Err "No SQL Database found on server '$sqlServerName'."
    exit 1
}
Write-Ok "SQL Database: $sqlDatabaseName"

# Storage Account (required)
Write-Info "Looking for Storage Account..."
$storageAccountName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Storage/storageAccounts" --query "[0].name" -o tsv
if ([string]::IsNullOrEmpty($storageAccountName)) {
    Write-Err "No Storage Account found in '$ResourceGroupName'."
    exit 1
}
Write-Ok "Storage Account: $storageAccountName"

# Static Web App (required)
Write-Info "Looking for Static Web App..."
$swaName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Web/staticSites" --query "[0].name" -o tsv
if ([string]::IsNullOrEmpty($swaName)) {
    Write-Err "No Static Web App found in '$ResourceGroupName'. Deploy Module 1 first."
    exit 1
}
$swaHostname = az staticwebapp show --name $swaName --resource-group $ResourceGroupName --query defaultHostname -o tsv
Write-Ok "Static Web App: $swaName ($swaHostname)"

# Log Analytics Workspace (required - from Module 3)
Write-Info "Looking for Log Analytics workspace (Module 3)..."
$logAnalyticsName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.OperationalInsights/workspaces" --query "[0].name" -o tsv
if ([string]::IsNullOrEmpty($logAnalyticsName)) {
    Write-Err "No Log Analytics workspace found in '$ResourceGroupName'."
    Write-Err "Deploy Module 3 (WAF) first - it creates the shared workspace."
    exit 1
}
Write-Ok "Log Analytics workspace: $logAnalyticsName"

# ---------------------------------------------------------------------------
# Step 4 - Auto-detect optional Module 2 resources (VNet / NSGs)
# ---------------------------------------------------------------------------
Write-Step "Step 4: Detecting optional Module 2 resources (VNet / NSGs)"

$vnetName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Network/virtualNetworks" --query "[0].name" -o tsv 2>$null
$webApiNsgName = ""
$apiSqlNsgName = ""
$vnetIntegrated = "false"

if (-not [string]::IsNullOrEmpty($vnetName)) {
    Write-Ok "VNet detected: $vnetName (Module 2 deployed)"
    $vnetIntegrated = "true"

    $nsgNames = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Network/networkSecurityGroups" --query "[].name" -o tsv
    foreach ($nsg in $nsgNames) {
        if ($nsg -like "*web-api*") { $webApiNsgName = $nsg }
        if ($nsg -like "*api-sql*") { $apiSqlNsgName = $nsg }
    }
    if (-not [string]::IsNullOrEmpty($webApiNsgName)) { Write-Ok "Web-API NSG: $webApiNsgName" }
    if (-not [string]::IsNullOrEmpty($apiSqlNsgName)) { Write-Ok "API-SQL NSG: $apiSqlNsgName" }
} else {
    Write-Info "No VNet found - Module 2 not deployed (will skip VNet/NSG diagnostics)"
    $vnetName = ""
}

# ---------------------------------------------------------------------------
# Step 5 - Auto-detect optional Module 3 resources (Front Door)
# ---------------------------------------------------------------------------
Write-Step "Step 5: Detecting optional Module 3 resources (Front Door)"

$frontDoorName = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Cdn/profiles" --query "[0].name" -o tsv 2>$null
if (-not [string]::IsNullOrEmpty($frontDoorName)) {
    Write-Ok "Front Door detected: $frontDoorName (Module 3 deployed)"

    # Remove old Module 3 ad-hoc diagnostic setting before Bicep creates the standardised one
    $oldDiagName = "$Prefix-afd-diagnostics"
    $frontDoorResourceId = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Cdn/profiles" --query "[0].id" -o tsv
    Write-Info "Removing old Front Door diagnostic setting '$oldDiagName'..."

    $errFile = [System.IO.Path]::GetTempFileName()
    az monitor diagnostic-settings delete `
        --name $oldDiagName `
        --resource $frontDoorResourceId `
        2>$errFile | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Removed old diagnostic setting '$oldDiagName'"
    } else {
        Write-Info "Old setting '$oldDiagName' not found (already removed or never existed - OK)"
    }
    Remove-Item $errFile -ErrorAction SilentlyContinue
} else {
    Write-Info "No Front Door found - Module 3 not deployed (will skip Front Door diagnostics)"
    $frontDoorName = ""
}

# ---------------------------------------------------------------------------
# Step 6 - Deploy Bicep infrastructure
# ---------------------------------------------------------------------------
Write-Step "Step 6: Deploying Application Insights and diagnostic settings"

$bicepFile = Join-Path $scriptRoot "main.bicep"
if (-not (Test-Path $bicepFile)) {
    Write-Err "Bicep template not found: $bicepFile"
    exit 1
}

$deploymentName = "monitoring-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
$errFile = [System.IO.Path]::GetTempFileName()

Write-Info "Deploying monitoring infrastructure (this may take 2-3 minutes)..."

$deployArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroupName,
    "--name", $deploymentName,
    "--template-file", $bicepFile,
    "--parameters",
        "prefix=$Prefix",
        "location=$Location",
        "logAnalyticsWorkspaceName=$logAnalyticsName",
        "functionAppName=$functionAppName",
        "storageAccountName=$storageAccountName",
        "sqlServerName=$sqlServerName",
        "sqlDatabaseName=$sqlDatabaseName",
        "sqlServerFqdn=$sqlServerFqdn",
        "swaName=$swaName",
        "appServicePlanName=$appServicePlanName",
        "vnetIntegrated=$vnetIntegrated",
        "vnetName=$vnetName",
        "webApiNsgName=$webApiNsgName",
        "apiSqlNsgName=$apiSqlNsgName",
        "frontDoorName=$frontDoorName",
    "--output", "json"
)

$deploymentJson = az @deployArgs 2>$errFile
if ($LASTEXITCODE -ne 0) {
    Write-Err "Bicep deployment failed."
    Get-Content $errFile | ForEach-Object { Write-Err "ERROR: $_" }
    Remove-Item $errFile -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item $errFile -ErrorAction SilentlyContinue

$deploymentOutput = $deploymentJson | ConvertFrom-Json
$appInsightsName           = $deploymentOutput.properties.outputs.appInsightsName.value
$appInsightsConnString     = $deploymentOutput.properties.outputs.appInsightsConnectionString.value
$appInsightsIKey           = $deploymentOutput.properties.outputs.appInsightsInstrumentationKey.value

Write-Ok "Application Insights: $appInsightsName"
Write-Ok "SQL audit logging enabled"
Write-Ok "Diagnostic settings deployed: Log-Send-To-Workspace"

# ---------------------------------------------------------------------------
# Step 7 - Configure SWA app settings with App Insights connection string
# ---------------------------------------------------------------------------
Write-Step "Step 7: Configuring Static Web App with Application Insights"

Write-Info "Setting APPLICATIONINSIGHTS_CONNECTION_STRING on SWA..."

# Use Invoke-Az to suppress NativeCommandError from az CLI's "settings redacted" warning.
# The connection string is passed as a single key=value argument; az CLI splits on the
# first '=' only, so additional '=' in the value are safe.
$azResult = Invoke-Az staticwebapp appsettings set `
    --name $swaName `
    --resource-group $ResourceGroupName `
    --setting-names "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConnString"

$errText = ($azResult.Output | Out-String)
if ($azResult.ExitCode -ne 0 -and $errText -notmatch 'WARNING.*redacted') {
    Write-Err "Failed to set SWA app settings."
    Write-Err $errText
    exit 1
}
Write-Ok "SWA app setting configured"

# ---------------------------------------------------------------------------
# Step 8 - Re-deploy SWA frontend with App Insights connection string injected
# ---------------------------------------------------------------------------
Write-Step "Step 8: Re-deploying Static Web App frontend with Application Insights SDK"

$webSrcDir  = Join-Path (Split-Path -Parent $scriptRoot) "src\web"
$tempWebDir = Join-Path $env:TEMP "clickapp-web-monitoring-$(Get-Random)"

Write-Info "Creating temp working directory for SWA build..."
Copy-Item -Path $webSrcDir -Destination $tempWebDir -Recurse -Force

# Substitute the placeholder in the copied index.html with the real connection string
$tempIndexHtml = Join-Path $tempWebDir "index.html"
(Get-Content $tempIndexHtml -Raw) `
    -replace '__APPINSIGHTS_CONNECTION_STRING__', $appInsightsConnString |
    Set-Content $tempIndexHtml -NoNewline

Write-Info "App Insights connection string injected into index.html"

# Get SWA deployment token
$tokenResult = Invoke-Az staticwebapp secrets list `
    --name $swaName `
    --resource-group $ResourceGroupName `
    --query "properties.apiKey" -o tsv

if ($tokenResult.ExitCode -ne 0 -or [string]::IsNullOrEmpty($tokenResult.Output)) {
    Write-Err "Failed to retrieve SWA deployment token."
    Remove-Item $tempWebDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
$swaDeployToken = ($tokenResult.Output | Out-String).Trim()

Write-Info "Deploying frontend..."
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"

npx @azure/static-web-apps-cli deploy $tempWebDir `
    --deployment-token $swaDeployToken `
    --env production 2>&1 | Tee-Object -Variable swaDeployOutput | Out-Null

$swaDeployExit = $LASTEXITCODE
$ErrorActionPreference = $prev

Remove-Item $tempWebDir -Recurse -Force -ErrorAction SilentlyContinue

if ($swaDeployExit -ne 0) {
    Write-Err "SWA frontend deployment failed."
    $swaDeployOutput | ForEach-Object { Write-Err "  $_" }
    exit 1
}
Write-Ok "SWA frontend re-deployed with Application Insights SDK"

# ---------------------------------------------------------------------------
# Step 9 - Verify deployment
# ---------------------------------------------------------------------------
Write-Step "Step 9: Verifying monitoring deployment"

# Verify App Insights exists
Write-Info "Verifying Application Insights..."
$appInsightsCheck = az resource show `
    --resource-group $ResourceGroupName `
    --name $appInsightsName `
    --resource-type "Microsoft.Insights/components" `
    --query "properties.provisioningState" -o tsv 2>$null

if ($appInsightsCheck -eq "Succeeded") {
    Write-Ok "Application Insights: Provisioned"
} else {
    Write-Err "Application Insights provisioning state: $appInsightsCheck"
}

# Verify diagnostic settings on Function App
Write-Info "Verifying diagnostic settings on Function App..."
$funcDiagCheck = az monitor diagnostic-settings list `
    --resource $functionAppResourceId `
    --query "[?name=='Log-Send-To-Workspace'].name" -o tsv 2>$null
if ($funcDiagCheck -eq "Log-Send-To-Workspace") {
    Write-Ok "Function App: Log-Send-To-Workspace configured"
} else {
    Write-Info "Function App diagnostic settings (verify in portal)"
}

# Verify SQL audit policy
Write-Info "Verifying SQL Server audit policy..."
$sqlAuditState = az sql server audit-policy show `
    --name $sqlServerName `
    --resource-group $ResourceGroupName `
    --query "state" -o tsv 2>$null
if ($sqlAuditState -eq "Enabled") {
    Write-Ok "SQL Server audit logging: Enabled (Azure Monitor target)"
} else {
    Write-Info "SQL audit state: $sqlAuditState (verify in portal)"
}

# Health check - confirm app is still responding
Write-Info "Running health check..."
$healthUrl = "https://$swaHostname/api/health"
$attempts = 0
$maxAttempts = 6
$healthy = $false

while ($attempts -lt $maxAttempts -and -not $healthy) {
    $attempts++
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -Method GET -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            $healthy = $true
            Write-Ok "API health check: Healthy ($healthUrl)"
        }
    } catch {
        if ($attempts -lt $maxAttempts) {
            Write-Info "Health check attempt $attempts/$maxAttempts - waiting 15 seconds..."
            Start-Sleep -Seconds 15
        }
    }
}

if (-not $healthy) {
    Write-Info "Health check did not return 200 - app may need a moment to restart after settings update"
}

# ---------------------------------------------------------------------------
# Step 10 - Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  MODULE 4 - MONITORING DEPLOYMENT COMPLETE" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Subscription:        $SubscriptionId" -ForegroundColor White
Write-Host "  Resource Group:      $ResourceGroupName" -ForegroundColor White
Write-Host "  Region:              $Location" -ForegroundColor White
Write-Host ""
Write-Host "  -- Observability Resources -----------------" -ForegroundColor DarkCyan
Write-Host "  Log Analytics:       $logAnalyticsName" -ForegroundColor White
Write-Host "  Application Insights:$appInsightsName" -ForegroundColor White
Write-Host ""
Write-Host "  -- Diagnostic Settings (Log-Send-To-Workspace) --" -ForegroundColor DarkCyan
Write-Host "  Function App:        $functionAppName" -ForegroundColor White
Write-Host "  Storage Account:     $storageAccountName (account + blob)" -ForegroundColor White
Write-Host "  App Service Plan:    $appServicePlanName" -ForegroundColor White
Write-Host "  Static Web App:      $swaName" -ForegroundColor White
Write-Host "  SQL Database:        $sqlServerName / $sqlDatabaseName" -ForegroundColor White
Write-Host "  SQL Audit Logging:   Enabled -> Azure Monitor" -ForegroundColor White

if (-not [string]::IsNullOrEmpty($vnetName)) {
    Write-Host "  VNet:                $vnetName" -ForegroundColor White
    Write-Host "  NSG (Web-API):       $webApiNsgName" -ForegroundColor White
    Write-Host "  NSG (API-SQL):       $apiSqlNsgName" -ForegroundColor White
}

if (-not [string]::IsNullOrEmpty($frontDoorName)) {
    Write-Host "  Front Door:          $frontDoorName (replaced old diagnostic setting)" -ForegroundColor White
}

Write-Host ""
Write-Host "  -- Application URLs ----------------------------" -ForegroundColor DarkCyan
Write-Host "  Web App:             https://$swaHostname" -ForegroundColor White
Write-Host "  API Health:          https://$swaHostname/api/health" -ForegroundColor White
Write-Host ""
Write-Host "  -- View Telemetry ------------------------------" -ForegroundColor DarkCyan
Write-Host "  Portal:              https://portal.azure.com" -ForegroundColor White
  Write-Host "  Navigate to:         $ResourceGroupName -> $appInsightsName -> Logs" -ForegroundColor Gray
Write-Host ""
Write-Host "  Web Status:         " -NoNewline -ForegroundColor White
if ($healthy) {
    Write-Host "HEALTHY" -ForegroundColor Green
} else {
    Write-Host "CHECK MANUALLY" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
