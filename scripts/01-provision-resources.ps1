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
    'AZ_SUBSCRIPTION_ID', 'AZ_RG', 'RESOURCE_LOCATION'
)

# Resolve the deploying user's object ID so Bicep can grant them Search Index
# Data Reader (needed for token-based queries / the query notebook). Try, in
# order: an explicit env override, Microsoft Graph, then the oid claim inside
# an access token (works even when Graph is blocked by a CAE/Conditional-Access
# challenge, which previously caused the role to be silently skipped).
$queryPrincipalId = $env:QUERY_PRINCIPAL_ID
if ([string]::IsNullOrWhiteSpace($queryPrincipalId)) {
    $queryPrincipalId = az ad signed-in-user show --query id -o tsv 2>$null
}
if ([string]::IsNullOrWhiteSpace($queryPrincipalId)) {
    try {
        $accessToken = az account get-access-token --query accessToken -o tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($accessToken)) {
            $payload = $accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
            switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
            $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            $queryPrincipalId = $claims.oid
        }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($queryPrincipalId)) {
    $queryPrincipalId = ''
    Write-Warning "Could not resolve your object ID (Graph blocked and no token oid)."
    Write-Warning "The 'Search Index Data Reader' role will be SKIPPED. Token-based queries will 403 until you grant it manually:"
    Write-Warning "  az role assignment create --assignee <your-object-id> --role 'Search Index Data Reader' --scope <search-resource-id>"
} else {
    Write-Host "==> Query principal (Search Index Data Reader): $queryPrincipalId" -ForegroundColor Cyan
}

Write-Host "==> Selecting subscription $env:AZ_SUBSCRIPTION_ID" -ForegroundColor Cyan
az account set --subscription $env:AZ_SUBSCRIPTION_ID
Assert-LastExit 'az account set'

# ---- 0) Ensure the dedicated resource group exists ----
# Everything is provisioned into this single RG so the whole project can be
# torn down later with:  az group delete --name $env:AZ_RG --yes
Write-Host "==> Ensuring resource group '$env:AZ_RG' in $env:RESOURCE_LOCATION" -ForegroundColor Cyan
az group create --name $env:AZ_RG --location $env:RESOURCE_LOCATION --output none
Assert-LastExit 'az group create'

# ---- Resolve globally-unique resource names ----
# Priority: an explicit name (from .env, or a prior run's .env.derived) wins.
# Otherwise generate "<prefix>-<role>-<suffix>" once and persist it to
# .env.derived, so re-runs reuse the same names (idempotent) while a fresh
# teardown (which removes .env.derived) yields brand-new unique names. Set
# RESOURCE_PREFIX in .env to control the base; it defaults to 'spmmrag'.
$prefix = if ([string]::IsNullOrWhiteSpace($env:RESOURCE_PREFIX)) { 'spmmrag' }
         else { ($env:RESOURCE_PREFIX).ToLower() -replace '[^a-z0-9]', '' }
$suffix = -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })

foreach ($pair in @(
        @{ Var = 'SEARCH_NAME';  Role = 'search' },
        @{ Var = 'FOUNDRY_NAME'; Role = 'foundry' })) {
    $existing = [System.Environment]::GetEnvironmentVariable($pair.Var, 'Process')
    if ([string]::IsNullOrWhiteSpace($existing)) {
        $generated = "$prefix-$($pair.Role)-$suffix"
        Set-DerivedVar -Name $pair.Var -Value $generated   # persists to .env.derived + sets process env
        Write-Host "==> Generated $($pair.Var) = $generated" -ForegroundColor Cyan
    }
}

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
    "searchName=$env:SEARCH_NAME",
    "foundryName=$env:FOUNDRY_NAME",
    "searchSku=$env:SEARCH_SKU",
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
Set-DerivedVar -Name 'SEARCH_PRINCIPAL_ID'  -Value $out.searchPrincipalId.value

Write-Host ""
Write-Host "Provisioning complete." -ForegroundColor Green
Write-Host "  Search  : $($out.searchEndpoint.value)"
Write-Host "  Foundry : $($out.foundryEndpoint.value)"
Write-Host ""
Write-Host "Next: .\scripts\03-deploy-search.ps1" -ForegroundColor Yellow
