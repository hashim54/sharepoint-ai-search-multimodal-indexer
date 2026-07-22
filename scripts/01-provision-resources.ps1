# ============================================================
# 01-provision-resources.ps1
#
# Deploys iac/main.bicep to the existing resource group and captures the
# deployment outputs into .env.derived for later scripts.
#
# WHY THE C:\Temp DANCE:
#   The repo lives under "OneDrive - Microsoft" (a path with spaces AND a
#   dash). Azure CLI's --template-file has a long-standing quoting bug on
#   Windows with such paths, producing "content already consumed" / file-not-
#   found style errors. The reliable workaround is to compile the Bicep to
#   ARM JSON and deploy from a short, space-free path (C:\Temp). We deploy the
#   compiled JSON via --template-file pointing at C:\Temp\main.json.
# ============================================================

[CmdletBinding()]
param(
    # Skip model deployments (useful if TPU quota is temporarily unavailable).
    [switch] $SkipDeployments
)

. "$PSScriptRoot\_common.ps1"
Initialize-Env

Assert-EnvVar -Names @(
    'AZ_SUBSCRIPTION_ID', 'AZ_RG', 'RESOURCE_LOCATION',
    'EXISTING_SEARCH_NAME', 'EXISTING_FOUNDRY_NAME', 'VISION_NAME',
    'EMBED_DEPLOYMENT', 'EMBED_MODEL', 'EMBED_SKU', 'EMBED_CAPACITY',
    'CU_MODEL_DEPLOYMENT', 'CU_MODEL_NAME', 'GPT_SKU', 'GPT_CAPACITY'
)

# Auto-detect the deploying user's object ID so Bicep can grant them
# Search Index Data Reader (needed for token-based queries / query.py).
$queryPrincipalId = az ad signed-in-user show --query id -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($queryPrincipalId)) { $queryPrincipalId = '' }

Write-Host "==> Selecting subscription $env:AZ_SUBSCRIPTION_ID" -ForegroundColor Cyan
az account set --subscription $env:AZ_SUBSCRIPTION_ID
Assert-LastExit 'az account set'

# ---- 0) Ensure the dedicated resource group exists ----
# Everything is provisioned into this single RG so the whole project can be
# torn down later with:  az group delete --name $env:AZ_RG --yes
Write-Host "==> Ensuring resource group '$env:AZ_RG' in $env:RESOURCE_LOCATION" -ForegroundColor Cyan
az group create --name $env:AZ_RG --location $env:RESOURCE_LOCATION --output none
Assert-LastExit 'az group create'

# ---- 1) Compile Bicep -> ARM JSON into a space-free path ----
$bicepPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'iac\main.bicep'
if (-not (Test-Path $bicepPath)) { throw "Bicep template not found: $bicepPath" }

$tempDir = 'C:\Temp'
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }
$tempJson = Join-Path $tempDir 'main.json'

Write-Host "==> Compiling Bicep -> $tempJson" -ForegroundColor Cyan
# Build to the repo first (bicep build needs the source dir), then copy the
# artifact to C:\Temp so the deploy command never touches the spaced path.
az bicep build --file $bicepPath --outfile $tempJson
Assert-LastExit 'az bicep build'
if (-not (Test-Path $tempJson)) { throw "Compiled ARM JSON missing: $tempJson" }

# ---- 2) Deploy the compiled JSON ----
$createDeployments = if ($SkipDeployments) { 'false' } else { 'true' }
$deploymentName = "spmm-rag-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Splat the args so each value is passed as a distinct token (avoids further
# quoting pitfalls with spaces inside values).
$deployArgs = @(
    'deployment', 'group', 'create',
    '--name', $deploymentName,
    '--resource-group', $env:AZ_RG,
    '--template-file', $tempJson,
    '--parameters',
    "location=$env:RESOURCE_LOCATION",
    "searchName=$env:EXISTING_SEARCH_NAME",
    "foundryName=$env:EXISTING_FOUNDRY_NAME",
    "visionName=$env:VISION_NAME",
    "queryPrincipalId=$queryPrincipalId",
    "createDeployments=$createDeployments",
    "embedDeployment=$env:EMBED_DEPLOYMENT",
    "embedModel=$env:EMBED_MODEL",
    "embedSku=$env:EMBED_SKU",
    "embedCapacity=$env:EMBED_CAPACITY",
    "cuModelDeployment=$env:CU_MODEL_DEPLOYMENT",
    "cuModelName=$env:CU_MODEL_NAME",
    "gptSku=$env:GPT_SKU",
    "gptCapacity=$env:GPT_CAPACITY",
    '--output', 'json'
)

Write-Host "==> Deploying '$deploymentName' to RG '$env:AZ_RG'..." -ForegroundColor Cyan
$deployJson = az @deployArgs
Assert-LastExit 'az deployment group create'

$deploy = $deployJson | ConvertFrom-Json
$out = $deploy.properties.outputs

# ---- 3) Capture outputs into .env.derived ----
Write-Host "==> Capturing outputs into .env.derived" -ForegroundColor Cyan
Set-DerivedVar -Name 'SEARCH_ENDPOINT'      -Value $out.searchEndpoint.value
Set-DerivedVar -Name 'FOUNDRY_ENDPOINT'     -Value $out.foundryEndpoint.value
Set-DerivedVar -Name 'VISION_ENDPOINT'      -Value $out.visionEndpoint.value
Set-DerivedVar -Name 'SEARCH_PRINCIPAL_ID'  -Value $out.searchPrincipalId.value

Write-Host ""
Write-Host "Provisioning complete." -ForegroundColor Green
Write-Host "  Search  : $($out.searchEndpoint.value)"
Write-Host "  Foundry : $($out.foundryEndpoint.value)"
Write-Host ""
Write-Host "Next: .\scripts\03-deploy-search.ps1" -ForegroundColor Yellow
