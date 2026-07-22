# ============================================================
# 04-check-status.ps1
#
# Kicks the indexer once (so we don't wait up to an hour for the schedule),
# then polls its execution status every 15s until success/failure.
# ============================================================

[CmdletBinding()]
param(
    # Seconds between polls.
    [int] $IntervalSeconds = 15,
    # Safety cap so the script can't loop forever.
    [int] $MaxMinutes = 60,
    # Skip the on-demand run and just watch the current/last execution.
    [switch] $NoRun
)

. "$PSScriptRoot\_common.ps1"
Initialize-Env

Assert-EnvVar -Names @(
    'AZ_SUBSCRIPTION_ID', 'AZ_RG', 'EXISTING_SEARCH_NAME',
    'SEARCH_ENDPOINT', 'SEARCH_API_VERSION', 'INDEXER_NAME'
)

az account set --subscription $env:AZ_SUBSCRIPTION_ID
Assert-LastExit 'az account set'

$adminKey = az search admin-key show `
    --service-name $env:EXISTING_SEARCH_NAME `
    --resource-group $env:AZ_RG `
    --query primaryKey -o tsv
Assert-LastExit 'az search admin-key show'

$headers = @{ 'api-key' = $adminKey; 'Content-Type' = 'application/json' }
$apiVersion = $env:SEARCH_API_VERSION
$base = "$($env:SEARCH_ENDPOINT)/indexers/$($env:INDEXER_NAME)"

if (-not $NoRun) {
    Write-Host "==> Triggering on-demand run of '$($env:INDEXER_NAME)'" -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Uri "$base/run`?api-version=$apiVersion" -Method Post -Headers $headers | Out-Null
    }
    catch {
        Write-Warning "Could not trigger run (it may already be running): $_"
    }
}

$deadline = (Get-Date).AddMinutes($MaxMinutes)
Write-Host "==> Polling status every ${IntervalSeconds}s (timeout ${MaxMinutes}m)" -ForegroundColor Cyan

while ($true) {
    $status = Invoke-RestMethod -Uri "$base/status`?api-version=$apiVersion" -Method Get -Headers $headers
    $last = $status.lastResult

    $state = if ($last) { $last.status } else { $status.status }
    $processed = if ($last) { $last.itemsProcessed } else { 0 }
    $failed = if ($last) { $last.itemsFailed } else { 0 }
    $stamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "  [$stamp] status=$state processed=$processed failed=$failed"

    switch ($state) {
        'success' {
            Write-Host ""
            Write-Host "Indexer succeeded: $processed processed, $failed failed." -ForegroundColor Green
            if ($last.errors) {
                Write-Warning "Item-level errors present:"
                $last.errors | ForEach-Object { Write-Host "   - $($_.errorMessage)" -ForegroundColor Red }
            }
            return
        }
        'transientFailure' {
            Write-Warning "Transient failure; the indexer will retry. Continuing to poll..."
        }
        'error' {
            Write-Host ""
            Write-Error "Indexer failed."
            if ($last.errorMessage) { Write-Host "  $($last.errorMessage)" -ForegroundColor Red }
            if ($last.errors) {
                $last.errors | ForEach-Object { Write-Host "   - $($_.errorMessage)" -ForegroundColor Red }
            }
            return
        }
        default {
            # 'inProgress' / 'reset' / null -> keep waiting.
        }
    }

    if ((Get-Date) -gt $deadline) {
        Write-Warning "Timed out after $MaxMinutes minutes while status was '$state'."
        return
    }
    Start-Sleep -Seconds $IntervalSeconds
}
