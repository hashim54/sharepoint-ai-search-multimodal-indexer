# validate.ps1

$templatePath = "C:\Users\mumann\OneDrive - Microsoft\Documents\sharepoint-ai-search-poc\iac\main.json"

$params = @(
    "--resource-group", $env:AZ_RG,
    "--template-file", $templatePath,
    "--parameters",
    "location=$env:RESOURCE_LOCATION",
    "searchName=$env:EXISTING_SEARCH_NAME",
    "foundryName=$env:EXISTING_FOUNDRY_NAME",
    "visionName=$env:VISION_NAME",
    "embedDeployment=$env:EMBED_DEPLOYMENT",
    "embedModel=$env:EMBED_MODEL",
    "embedSku=$env:EMBED_SKU",
    "embedCapacity=$env:EMBED_CAPACITY",
    "cuModelDeployment=$env:CU_MODEL_DEPLOYMENT",
    "cuModelName=$env:CU_MODEL_NAME",
    "gptSku=$env:GPT_SKU",
    "gptCapacity=$env:GPT_CAPACITY"
)

Write-Host "Template exists: $(Test-Path $templatePath)"
Write-Host ""

& az deployment group validate @params