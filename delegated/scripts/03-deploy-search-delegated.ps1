# ============================================================
# 03-deploy-search-delegated.ps1  (DELEGATED-permissions variant)
#
# Deploys a SEPARATE set of search artifacts (index/datasource/skillset/indexer)
# that use DELEGATED SharePoint permissions. It does NOT touch the primary
# application-permission deployment — it uses its own "-del" artifact names.
#
# WHAT'S DIFFERENT FROM THE APP-PERMISSION PATH:
#   - Data source connection string is secret-less (no ApplicationSecret).
#   - No ACL ingestion (delegated can't do it) -> no UserIds/GroupIds/permissionFilter.
#   - Creating the indexer triggers a DEVICE-CODE sign-in: you must open
#     https://microsoft.com/devicelogin, enter the code this script prints, and
#     sign in AS THE INDEXING USER within ~10 minutes.
#   - Delegated user tokens expire (~75 min). Re-running this script re-triggers
#     the device-code flow to refresh the token.
#
# PREREQUISITES (see delegated/README.md):
#   - A NEW Entra app registration with DELEGATED Graph permissions:
#       Files.Read.All, Sites.Read.All, User.Read
#     plus Authentication -> "Allow public client flows" = Yes, and the
#     native-client redirect URI.
#   - Set SP_DEL_CLIENT_ID (the delegated app's client id) in .env.
#   - The shared Azure resources (Search/Foundry/Vision) already exist
#     (from scripts/01-provision-resources.ps1) and .env.derived is populated.
# ============================================================

[CmdletBinding()]
param(
    [int] $AuthTimeoutMinutes = 12,
    [int] $IndexTimeoutMinutes = 30
)

. "$PSScriptRoot\..\..\scripts\_common.ps1"
Initialize-Env

Assert-EnvVar -Names @(
    'AZ_SUBSCRIPTION_ID', 'AZ_RG', 'SEARCH_NAME',
    'SEARCH_ENDPOINT', 'SEARCH_API_VERSION',
    'FOUNDRY_ENDPOINT',
    'CU_MODEL_NAME', 'CU_MODEL_DEPLOYMENT',
    'SP_SITE_URL', 'SP_APP_TENANT_ID', 'SP_DEL_CLIENT_ID'
)

# Dedicated delegated artifact names (env-overridable) so this variant never
# clobbers the ACL-preserving application-permission deployment.
$delIndex      = if ($env:DEL_INDEX_NAME)      { $env:DEL_INDEX_NAME }      else { 'sharepoint-page-index-del' }
$delDataSource = if ($env:DEL_DATASOURCE_NAME) { $env:DEL_DATASOURCE_NAME } else { 'sharepoint-ds-del' }
$delSkillset   = if ($env:DEL_SKILLSET_NAME)   { $env:DEL_SKILLSET_NAME }   else { 'sharepoint-mm-skillset-del' }
$delIndexer    = if ($env:DEL_INDEXER_NAME)    { $env:DEL_INDEXER_NAME }    else { 'sharepoint-indexer-del' }

az account set --subscription $env:AZ_SUBSCRIPTION_ID
Assert-LastExit 'az account set'

Write-Host "==> Retrieving Search admin key" -ForegroundColor Cyan
$adminKey = az search admin-key show --service-name $env:SEARCH_NAME --resource-group $env:AZ_RG --query primaryKey -o tsv
Assert-LastExit 'az search admin-key show'
if ([string]::IsNullOrWhiteSpace($adminKey)) { throw 'Empty Search admin key.' }

$headers = @{ 'api-key' = $adminKey; 'Content-Type' = 'application/json' }
$api = $env:SEARCH_API_VERSION
$base = ($env:SEARCH_ENDPOINT).TrimEnd('/')
$dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skillset'

# Token map (note: NO SP_APP_CLIENT_SECRET in the delegated path).
$tokens = @{
    '<REPLACE_INDEX_NAME>'          = $delIndex
    '<REPLACE_DATASOURCE_NAME>'     = $delDataSource
    '<REPLACE_SKILLSET_NAME>'       = $delSkillset
    '<REPLACE_INDEXER_NAME>'        = $delIndexer
    '<REPLACE_FOUNDRY_ENDPOINT>'    = $env:FOUNDRY_ENDPOINT
    '<REPLACE_CU_MODEL_NAME>'       = $env:CU_MODEL_NAME
    '<REPLACE_CU_MODEL_DEPLOYMENT>' = $env:CU_MODEL_DEPLOYMENT
    '<REPLACE_SP_SITE_URL>'         = $env:SP_SITE_URL
    '<REPLACE_SP_APP_CLIENT_ID>'    = $env:SP_DEL_CLIENT_ID
    '<REPLACE_SP_APP_TENANT_ID>'    = $env:SP_APP_TENANT_ID
}

function Expand-Tokens([string] $text) {
    foreach ($k in $tokens.Keys) { $text = $text.Replace($k, [string]$tokens[$k]) }
    return $text
}

function Publish-Artifact([string] $file, [string] $collection, [string] $name) {
    $body = Expand-Tokens (Get-Content -LiteralPath (Join-Path $dir $file) -Raw)
    Write-Host "==> PUT $collection/$name" -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Method Put -Uri "$base/$collection/$name`?api-version=$api" -Headers $headers -Body $body | Out-Null
        Write-Host "  ok" -ForegroundColor Green
    }
    catch {
        Write-Host "  FAILED: $($_.ErrorDetails.Message)" -ForegroundColor Red
        throw
    }
}

function Remove-IfExists([string] $collection, [string] $name) {
    try {
        Invoke-RestMethod -Method Delete -Uri "$base/$collection/$name`?api-version=$api" -Headers $headers | Out-Null
        Write-Host "  removed existing $collection/$name" -ForegroundColor DarkGray
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) { Write-Verbose "delete ${name}: $($_.Exception.Message)" }
    }
}

# A stale device-code grant sticks to the same (non-working) code, so we delete
# the datasource + indexer first to force a FRESH sign-in every run.
Write-Host "==> Clearing any existing delegated datasource/indexer (fresh sign-in)" -ForegroundColor Cyan
Remove-IfExists 'indexers'    $delIndexer
Remove-IfExists 'datasources' $delDataSource

Publish-Artifact 'index.json'      'indexes'     $delIndex
Publish-Artifact 'datasource.json' 'datasources' $delDataSource
Publish-Artifact 'skillset.json'   'skillsets'   $delSkillset

# ---- Create the indexer; this triggers the DELEGATED device-code sign-in ----
$indexerBody = Expand-Tokens (Get-Content -LiteralPath (Join-Path $dir 'indexer.json') -Raw)
$indexerUri = "$base/indexers/$delIndexer`?api-version=$api"
$statusUri = "$base/indexers/$delIndexer/status`?api-version=$api"

Write-Host ""
Write-Host "==> Creating indexer '$delIndexer' (keeps the request OPEN for device-code sign-in)" -ForegroundColor Cyan

# CRITICAL: the SharePoint delegated flow binds your token to the OPEN create
# request — the service polls the token endpoint for the duration of THIS
# request. If the request closes early (short timeout), the device-code session
# is abandoned and your sign-in never lands (the same code just keeps showing).
# So we run the PUT in a background job with a long timeout and surface the code
# while it stays open.
$putJob = Start-Job -ScriptBlock {
    param($u, $hh, $b)
    try { Invoke-RestMethod -Method Put -Uri $u -Headers $hh -Body $b -TimeoutSec 700 | Out-Null; 'ok' }
    catch { $_.Exception.Message }
} -ArgumentList $indexerUri, $headers, $indexerBody

$authDeadline = (Get-Date).AddMinutes($AuthTimeoutMinutes)
$lastCode = ''
while ((Get-Date) -lt $authDeadline -and $putJob.State -eq 'Running') {
    Start-Sleep -Seconds 5
    $st = $null
    try { $st = Invoke-RestMethod -Uri $statusUri -Headers $headers } catch { continue }
    if ($st.lastResult.errorMessage -match 'enter the code (\S+)') {
        $code = $Matches[1]
        if ($code -ne $lastCode) {
            $lastCode = $code
            Write-Host ""
            Write-Host "  ============================================================" -ForegroundColor Yellow
            Write-Host "   SIGN IN:  https://microsoft.com/devicelogin" -ForegroundColor Yellow
            Write-Host "   CODE:     $code" -ForegroundColor Yellow
            Write-Host "   Sign in AS THE INDEXING USER and approve NOW (request is open)." -ForegroundColor Yellow
            Write-Host "  ============================================================" -ForegroundColor Yellow
            Write-Host ""
        }
    }
}
$putResult = Receive-Job $putJob -ErrorAction SilentlyContinue
Remove-Job $putJob -Force -ErrorAction SilentlyContinue
Write-Host "==> Indexer create result: $putResult" -ForegroundColor Cyan
if ($putResult -ne 'ok') {
    Write-Warning "The create request didn't complete cleanly. If you didn't sign in during the open window, re-run this script and authenticate promptly."
}

# ---- Poll indexing to completion ----
Write-Host "==> Polling indexer status (timeout $IndexTimeoutMinutes m)" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes($IndexTimeoutMinutes)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $st = $null
    try { $st = Invoke-RestMethod -Uri $statusUri -Headers $headers } catch { continue }
    $s = $st.lastResult.status
    Write-Host ("  [{0:HH:mm:ss}] status={1} processed={2} failed={3}" -f (Get-Date), $s, $st.lastResult.itemsProcessed, $st.lastResult.itemsFailed)
    if ($s -eq 'success') {
        Write-Host "Indexer succeeded: $($st.lastResult.itemsProcessed) processed, $($st.lastResult.itemsFailed) failed." -ForegroundColor Green
        break
    }
    if ($s -eq 'transientFailure' -and $st.lastResult.errorMessage -match 'devicelogin') {
        Write-Warning "Sign-in didn't land in time. Re-run this script and authenticate promptly while the request is open."
        break
    }
}
