<#
.SYNOPSIS
    Deploys the Azure Click Counter application end-to-end.

.DESCRIPTION
    Creates all Azure resources (SQL, Functions, SWA) via Bicep,
    initialises the SQL schema, grants Managed Identity access,
    publishes the Functions API and Static Web App content,
    then validates health-check endpoints.

.PARAMETER Prefix
    Resource naming prefix. Default: clickapp

.PARAMETER Location
    Azure region. Default: eastus2

.PARAMETER ResourceGroupName
    Resource group name. Default: {Prefix}-rg

.PARAMETER TenantId
    Azure AD tenant ID. If omitted, uses the current az CLI tenant.

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current az CLI subscription.
#>

[CmdletBinding()]
param(
    [string]$Prefix = "clickapp",
    [string]$Location = "eastus2",
    [string]$ResourceGroupName = "",
    [string]$TenantId = "",
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

# Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
    exit 1
}
Write-Ok "Azure CLI found"

# .NET SDK
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Err ".NET SDK is not installed. Install from https://dot.net"
    exit 1
}
Write-Ok ".NET SDK found"

# SWA CLI
if (-not (Get-Command swa -ErrorAction SilentlyContinue)) {
    Write-Err "SWA CLI not found. Install with: npm install -g @azure/static-web-apps-cli"
    exit 1
}
Write-Ok "SWA CLI found"

# Logged in?
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Ok "Azure CLI logged in"

# Set tenant and subscription context if provided
if (-not [string]::IsNullOrEmpty($TenantId)) {
    Write-Info "Setting tenant: $TenantId"
    az login --tenant $TenantId --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to set tenant $TenantId. Verify the tenant ID and that you have access."
        exit 1
    }
    Write-Ok "Tenant set: $TenantId"
}

if (-not [string]::IsNullOrEmpty($SubscriptionId)) {
    Write-Info "Setting subscription: $SubscriptionId"
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to set subscription $SubscriptionId. Verify the subscription ID and that you have access."
        exit 1
    }
    Write-Ok "Subscription set: $SubscriptionId"
} else {
    $SubscriptionId = az account show --query id -o tsv
}

Write-Ok "Active subscription: $SubscriptionId"

# ─────────────────────────────────────────────
# 2. Get deployer identity for SQL AAD admin
# ─────────────────────────────────────────────
Write-Step "Getting deployer identity"

$signedInUser = az ad signed-in-user show --query "{objectId:id, upn:userPrincipalName}" -o json | ConvertFrom-Json
$aadAdminObjectId = $signedInUser.objectId
$aadAdminLogin = $signedInUser.upn

Write-Ok "AAD Admin: $aadAdminLogin ($aadAdminObjectId)"

# ─────────────────────────────────────────────
# 3. Create Resource Group
# ─────────────────────────────────────────────
Write-Step "Creating resource group: $ResourceGroupName"
az group create --name $ResourceGroupName --location $Location --subscription $SubscriptionId --output none
Write-Ok "Resource group ready"

# ─────────────────────────────────────────────
# 4. Deploy Bicep Infrastructure
# ─────────────────────────────────────────────
Write-Step "Deploying Bicep templates"

$deploymentJson = $null
$deploymentErr = $null
$deploymentJson = az deployment group create `
    --resource-group $ResourceGroupName `
    --subscription $SubscriptionId `
    --template-file "$scriptRoot/infra/main.bicep" `
    --parameters prefix=$Prefix location=$Location aadAdminObjectId=$aadAdminObjectId aadAdminLogin=$aadAdminLogin `
    --query "properties.outputs" `
    -o json 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Err "Bicep deployment failed."
    # Re-run to capture error output for display
    $deploymentErr = az deployment group create `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --template-file "$scriptRoot/infra/main.bicep" `
        --parameters prefix=$Prefix location=$Location aadAdminObjectId=$aadAdminObjectId aadAdminLogin=$aadAdminLogin `
        -o json 2>&1
    $deploymentErr | ForEach-Object { Write-Err $_ }
    Write-Err "Tip: If you see a region provisioning error, try a different -Location (e.g. eastus, centralus, westus2)."
    exit 1
}

$deploymentOutput = $deploymentJson | ConvertFrom-Json

$sqlServerFqdn       = $deploymentOutput.sqlServerFqdn.value
$sqlServerName       = $deploymentOutput.sqlServerName.value
$sqlDatabaseName     = $deploymentOutput.sqlDatabaseName.value
$functionAppName     = $deploymentOutput.functionAppName.value
$functionAppHostname = $deploymentOutput.functionAppHostname.value
$swaName             = $deploymentOutput.swaName.value
$swaHostname         = $deploymentOutput.swaHostname.value
$swaDeploymentToken  = $deploymentOutput.swaDeploymentToken.value

Write-Ok "SQL Server:    $sqlServerFqdn"
Write-Ok "Database:      $sqlDatabaseName"
Write-Ok "Function App:  $functionAppName ($functionAppHostname)"
Write-Ok "SWA:           $swaName (https://$swaHostname)"

# ─────────────────────────────────────────────
# 5. Configure SQL — firewall, schema, MI user
# ─────────────────────────────────────────────
Write-Step "Configuring SQL Database"

# 5a. Temporarily allow deployer IP through firewall
# Use a broad rule to handle corporate networks with multiple egress IPs
$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=text" -TimeoutSec 10).Trim()
Write-Info "Adding firewall rule for deployer IP: $myIp"
az sql server firewall-rule create `
    --resource-group $ResourceGroupName `
    --server $sqlServerName `
    --subscription $SubscriptionId `
    --name "DeployerAccess" `
    --start-ip-address $myIp `
    --end-ip-address $myIp `
    --output none

# 5b. Get AAD access token for SQL
Write-Info "Acquiring AAD token for SQL..."
$sqlToken = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv

# 5c. Run init.sql (create table)
Write-Info "Running schema init script..."
$initSql = Get-Content -Path "$scriptRoot/sql/init.sql" -Raw
# Remove GO statements for programmatic execution
$initSql = $initSql -replace '(?mi)^\s*GO\s*$', ''

# Attempt connection — corporate networks may have multiple egress IPs
$connected = $false
$firewallRules = @("DeployerAccess")
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $sqlConn = New-Object System.Data.SqlClient.SqlConnection
        $sqlConn.ConnectionString = "Server=tcp:$sqlServerFqdn,1433;Database=$sqlDatabaseName;Encrypt=True;TrustServerCertificate=False;"
        $sqlConn.AccessToken = $sqlToken
        $sqlConn.Open()
        $connected = $true
        break
    } catch {
        $errMsg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        if ($errMsg -match "Client with IP address '([\d\.]+)'") {
            $blockedIp = $Matches[1]
            $ruleName = "DeployerAccess-$attempt"
            Write-Info "Attempt $attempt — adding firewall rule for egress IP: $blockedIp"
            az sql server firewall-rule create `
                --resource-group $ResourceGroupName `
                --server $sqlServerName `
                --subscription $SubscriptionId `
                --name $ruleName `
                --start-ip-address $blockedIp `
                --end-ip-address $blockedIp `
                --output none
            $firewallRules += $ruleName
            Write-Info "Waiting for firewall rule to propagate..."
            Start-Sleep -Seconds 15
            $sqlConn.Dispose()
        } else {
            throw
        }
    }
}

if (-not $connected) {
    Write-Err "Failed to connect to SQL after 5 attempts. Your network may have too many rotating egress IPs."
    Write-Err "Try running from a network with a stable public IP, or temporarily allow a broader IP range on the SQL server."
    exit 1
}

$cmd = $sqlConn.CreateCommand()
$cmd.CommandText = $initSql
$cmd.ExecuteNonQuery() | Out-Null
Write-Ok "Schema initialised"

# 5d. Create external user for Function App managed identity
Write-Info "Granting Managed Identity access to SQL..."
$miSql = @"
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$functionAppName')
BEGIN
    CREATE USER [$functionAppName] FROM EXTERNAL PROVIDER;
END
ALTER ROLE db_datareader ADD MEMBER [$functionAppName];
ALTER ROLE db_datawriter ADD MEMBER [$functionAppName];
"@

$cmd.CommandText = $miSql
$cmd.ExecuteNonQuery() | Out-Null
Write-Ok "Managed Identity user created and granted db_datareader + db_datawriter"

$sqlConn.Close()
$sqlConn.Dispose()

# 5e. Remove deployer firewall rules
Write-Info "Removing deployer firewall rules..."
foreach ($rule in $firewallRules) {
    az sql server firewall-rule delete `
        --resource-group $ResourceGroupName `
        --server $sqlServerName `
        --subscription $SubscriptionId `
        --name $rule `
        --output none 2>$null
}
Write-Ok "Deployer firewall rules removed"

# ─────────────────────────────────────────────
# 6. Build & Deploy Azure Functions
# ─────────────────────────────────────────────
Write-Step "Building Azure Functions API"

$apiProjectPath = "$scriptRoot/src/api"
$publishPath = "$scriptRoot/publish/api"

dotnet publish $apiProjectPath -c Release -o $publishPath --nologo
if ($LASTEXITCODE -ne 0) {
    Write-Err "dotnet publish failed"
    exit 1
}
Write-Ok "API built successfully"

Write-Step "Deploying Azure Functions"

# Create zip package
$zipPath = "$scriptRoot/publish/api.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$publishPath/*" -DestinationPath $zipPath -Force

az functionapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $functionAppName `
    --subscription $SubscriptionId `
    --src $zipPath `
    --output none

Write-Ok "Functions deployed to $functionAppName"

# ─────────────────────────────────────────────
# 7. Deploy Static Web App Content
# ─────────────────────────────────────────────
Write-Step "Deploying Static Web App content"

$webPath = "$scriptRoot/src/web"

$env:SWA_CLI_DEPLOYMENT_TOKEN = $swaDeploymentToken

# Use swa deploy in production mode
swa deploy $webPath --deployment-token $swaDeploymentToken --env production 2>&1 | ForEach-Object { Write-Info $_ }

if ($LASTEXITCODE -ne 0) {
    Write-Err "SWA deployment failed"
    exit 1
}
Write-Ok "Static Web App deployed"

# ─────────────────────────────────────────────
# 8. Post-Deployment Health Checks
# ─────────────────────────────────────────────
Write-Step "Running post-deployment health checks"

$swaBaseUrl = "https://$swaHostname"
$maxRetries = 6
$retryDelay = 15

# 8a. Web Health Check
Write-Info "Waiting for services to stabilise..."
Start-Sleep -Seconds 20

$webHealthy = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $webResponse = Invoke-WebRequest -Uri $swaBaseUrl -UseBasicParsing -TimeoutSec 15
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
    Write-Ok "Web Health Check PASSED — $swaBaseUrl returned 200"
} else {
    Write-Err "Web Health Check FAILED — $swaBaseUrl did not respond with 200"
}

# 8b. API Health Check
$apiHealthy = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $healthResponse = Invoke-RestMethod -Uri "$swaBaseUrl/api/health" -TimeoutSec 15
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
    Write-Ok "API Health Check PASSED — /api/health returned 'healthy'"
    Write-Ok "  Database: $($healthResponse.database)"
    Write-Ok "  Timestamp: $($healthResponse.timestamp)"
} else {
    Write-Err "API Health Check FAILED — /api/health did not return 'healthy'"
}

# ─────────────────────────────────────────────
# 9. Summary
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Subscription:     $SubscriptionId"
Write-Host "  Resource Group:   $ResourceGroupName"
Write-Host "  Region:           $Location"
Write-Host ""
Write-Host "  Web App URL:      https://$swaHostname" -ForegroundColor Yellow
Write-Host "  API Health:       https://$swaHostname/api/health" -ForegroundColor Yellow
Write-Host "  Function App:     $functionAppName" -ForegroundColor Yellow
Write-Host "  SQL Server:       $sqlServerFqdn"
Write-Host "  SQL Database:     $sqlDatabaseName"
Write-Host ""
Write-Host "  Web Status:       $(if ($webHealthy) { 'HEALTHY' } else { 'UNHEALTHY' })" -ForegroundColor $(if ($webHealthy) { 'Green' } else { 'Red' })
Write-Host "  API Status:       $(if ($apiHealthy) { 'HEALTHY' } else { 'UNHEALTHY' })" -ForegroundColor $(if ($apiHealthy) { 'Green' } else { 'Red' })
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
