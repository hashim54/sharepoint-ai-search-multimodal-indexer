# ============================================================
# 03-deploy-search.ps1
#
# Reads the JSON templates in skillset/, substitutes <REPLACE_*> tokens with
# real values from .env / .env.derived, then PUTs each artifact to the Azure
# AI Search REST API in dependency order:
#     index -> datasource -> skillset -> indexer
#
# WHY PUT (not POST): PUT to a named resource is create-or-update, so re-runs
# are idempotent. POST to the collection would fail on the second run.
#
# WHY token substitution (not env-var binding): the Search REST payloads are
# plain JSON files, and several values (splitter URL with key, SP secret) are
# only known after earlier steps. Regex replacement keeps the templates clean
# and reviewable while injecting secrets only at deploy time.
# ============================================================

[CmdletBinding()]
param()

. "$PSScriptRoot\_common.ps1"
Initialize-Env

Assert-EnvVar -Names @(
    'AZ_SUBSCRIPTION_ID', 'AZ_RG', 'SEARCH_NAME',
    'SEARCH_ENDPOINT', 'SEARCH_API_VERSION',
    'INDEX_NAME', 'DATASOURCE_NAME', 'SKILLSET_NAME', 'INDEXER_NAME',
    'FOUNDRY_ENDPOINT', 'VISION_ENDPOINT',
    'SP_SITE_URL', 'SP_APP_CLIENT_ID', 'SP_APP_CLIENT_SECRET', 'SP_APP_TENANT_ID'
)

az account set --subscription $env:AZ_SUBSCRIPTION_ID
Assert-LastExit 'az account set'

# ---- Get an admin key to authenticate REST calls ----
# WHY admin key (not MI): the local operator running this script authenticates
# to the control plane via az; pulling the admin key is the simplest way to
# call the data-plane REST API from PowerShell. The key never leaves this run.
Write-Host "==> Retrieving Search admin key" -ForegroundColor Cyan
$adminKey = az search admin-key show `
    --service-name $env:SEARCH_NAME `
    --resource-group $env:AZ_RG `
    --query primaryKey -o tsv
Assert-LastExit 'az search admin-key show'
if ([string]::IsNullOrWhiteSpace($adminKey)) { throw 'Empty Search admin key.' }

$headers = @{
    'api-key'      = $adminKey
    'Content-Type' = 'application/json'
}
$apiVersion = $env:SEARCH_API_VERSION
$skillsetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skillset'

# Token map applied to every template before upload.
$tokens = @{
    '<REPLACE_INDEX_NAME>'          = $env:INDEX_NAME
    '<REPLACE_DATASOURCE_NAME>'     = $env:DATASOURCE_NAME
    '<REPLACE_SKILLSET_NAME>'       = $env:SKILLSET_NAME
    '<REPLACE_INDEXER_NAME>'        = $env:INDEXER_NAME
    '<REPLACE_FOUNDRY_ENDPOINT>'    = $env:FOUNDRY_ENDPOINT
    '<REPLACE_VISION_ENDPOINT>'     = $env:VISION_ENDPOINT
    '<REPLACE_SP_SITE_URL>'         = $env:SP_SITE_URL
    '<REPLACE_SP_APP_CLIENT_ID>'    = $env:SP_APP_CLIENT_ID
    '<REPLACE_SP_APP_CLIENT_SECRET>' = $env:SP_APP_CLIENT_SECRET
    '<REPLACE_SP_APP_TENANT_ID>'    = $env:SP_APP_TENANT_ID
}

function Publish-SearchArtifact {
    param(
        [Parameter(Mandatory)] [string] $File,      # template file name in skillset/
        [Parameter(Mandatory)] [string] $Collection, # indexes | datasources | skillsets | indexers
        [Parameter(Mandatory)] [string] $Name        # resource name
    )

    $path = Join-Path $skillsetDir $File
    if (-not (Test-Path $path)) { throw "Template not found: $path" }

    $body = Get-Content -LiteralPath $path -Raw
    foreach ($k in $tokens.Keys) {
        # Literal replace (not regex) so URL/query chars in values are safe.
        $body = $body.Replace($k, [string]$tokens[$k])
    }

    # Guard: fail loud if any token remained unsubstituted.
    $leftover = [regex]::Matches($body, '<REPLACE_[A-Z_]+>')
    if ($leftover.Count -gt 0) {
        $names = ($leftover | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
        throw "Unsubstituted tokens in $File`: $names"
    }

    $uri = "$($env:SEARCH_ENDPOINT)/$Collection/$Name`?api-version=$apiVersion"
    Write-Host "==> PUT $Collection/$Name" -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body | Out-Null
        Write-Host "  ok" -ForegroundColor DarkGray
    }
    catch {
        # PowerShell 7 surfaces the response body on $_.ErrorDetails.Message.
        $detail = $_.ErrorDetails.Message
        if (-not $detail -and $_.Exception.Response) {
            try { $detail = $_.Exception.Response.Content.ReadAsStringAsync().Result } catch { }
        }
        Write-Error "PUT $Collection/$Name failed: $detail"
        throw
    }
}

# Order matters: index first (skillset projections + indexer target it),
# datasource next, then skillset, then indexer (which references all three).
Publish-SearchArtifact -File 'index.json'      -Collection 'indexes'     -Name $env:INDEX_NAME
Publish-SearchArtifact -File 'datasource.json' -Collection 'datasources' -Name $env:DATASOURCE_NAME
Publish-SearchArtifact -File 'skillset.json'   -Collection 'skillsets'   -Name $env:SKILLSET_NAME
Publish-SearchArtifact -File 'indexer.json'    -Collection 'indexers'    -Name $env:INDEXER_NAME

Write-Host ""
Write-Host "Search artifacts deployed." -ForegroundColor Green
Write-Host "  The indexer will run on its PT1H schedule, or run 04 to watch it." -ForegroundColor Yellow
Write-Host "Next: .\scripts\04-check-status.ps1" -ForegroundColor Yellow
