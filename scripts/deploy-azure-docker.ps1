# Alternativa com o Dockerfile da API: sobe a imagem no Azure Container Registry
# e aponta o Web App para ela. Use se DOTNETCORE:10.0 nao aparecer em
# `az webapp list-runtimes --os-type linux`.
#
#   $env:SQL_PASSWORD = "StellarGear.Cp6.2026"
#   .\scripts\deploy-azure-docker.ps1

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

if (-not $env:SQL_PASSWORD) {
    throw "Defina a senha do SQL antes de rodar: `$env:SQL_PASSWORD = 'StellarGear.Cp6.2026'"
}

function Invoke-Az {
    Write-Host ""
    Write-Host "> az $($args -join ' ')" -ForegroundColor Cyan
    & az @args
    if ($LASTEXITCODE -ne 0) {
        throw "O comando az falhou (exit $LASTEXITCODE)."
    }
}

# O clone traz arquivos somente leitura em .git, que travam o Remove-Item.
function Remove-Tree($path) {
    if (-not (Test-Path $path)) { return }
    Get-ChildItem $path -Recurse -Force | ForEach-Object { $_.Attributes = "Normal" }
    Remove-Item $path -Recurse -Force
}

$repo = Split-Path -Parent $PSScriptRoot
$apiUrl = if ($env:API_REPO_URL) { $env:API_REPO_URL } else { "https://github.com/PietroDonella/StellarGear.API.git" }
$apiBranch = if ($env:API_BRANCH) { $env:API_BRANCH } else { "cp6-azure" }
$app = Join-Path $repo ".api"

$suffix = (Get-Date -Format "ddHHmmss") + (Get-Random -Maximum 9999).ToString("0000")
$location = "brazilsouth"
$resourceGroup = "rg-stellargear-cp6"
$plan = "asp-stellargear-$suffix"
$webApp = "app-stellargear-$suffix"
$sqlServer = "sql-stellargear-$suffix"
$sqlDatabase = "StellarGearDb"
$sqlUser = "stellaradmin"
$appInsights = "appi-stellargear-$suffix"
$registry = "acrstellargear$suffix"
$sqlPassword = $env:SQL_PASSWORD

foreach ($tool in @("git", "az")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' nao foi encontrado no PATH. Instale antes de rodar o script."
    }
}

Write-Host "Clonando a API ($apiBranch)"
Remove-Tree $app
git clone --branch $apiBranch --depth 1 $apiUrl $app
if ($LASTEXITCODE -ne 0) { throw "git clone falhou." }

$dockerfile = Join-Path $app "Dockerfile"
if (-not (Test-Path $dockerfile)) { throw "Nao achei o Dockerfile no repositorio clonado." }

az account show --query name -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) { az login }

az extension add -n application-insights
$extension = az extension show --name application-insights --query name -o tsv 2>$null
if (-not $extension) { Invoke-Az extension add --name application-insights }

Invoke-Az group create --name $resourceGroup --location $location
Invoke-Az sql server create --resource-group $resourceGroup --name $sqlServer --location $location --admin-user $sqlUser --admin-password $sqlPassword
Invoke-Az sql db create --resource-group $resourceGroup --server $sqlServer --name $sqlDatabase --service-objective Basic --backup-storage-redundancy Local
Invoke-Az sql server firewall-rule create --resource-group $resourceGroup --server $sqlServer --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0

$clientIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Invoke-Az sql server firewall-rule create --resource-group $resourceGroup --server $sqlServer --name AllowClient --start-ip-address $clientIp --end-ip-address $clientIp

Invoke-Az monitor app-insights component create --resource-group $resourceGroup --location $location --app $appInsights --application-type web
$insightsConnection = az monitor app-insights component show --resource-group $resourceGroup --app $appInsights --query connectionString -o tsv

Invoke-Az acr create --resource-group $resourceGroup --name $registry --sku Basic --admin-enabled true
Invoke-Az acr build --registry $registry --image "stellargear:cp6" --file $dockerfile $app

$acrUser = az acr credential show --name $registry --query username -o tsv
$acrPass = az acr credential show --name $registry --query "passwords[0].value" -o tsv
$image = "$registry.azurecr.io/stellargear:cp6"

Invoke-Az appservice plan create --resource-group $resourceGroup --name $plan --location $location --is-linux --sku B1
Invoke-Az webapp create `
    --resource-group $resourceGroup `
    --plan $plan `
    --name $webApp `
    --container-image-name $image `
    --container-registry-url "https://$registry.azurecr.io" `
    --container-registry-user $acrUser `
    --container-registry-password $acrPass

$sqlConnection = "Server=tcp:$sqlServer.database.windows.net,1433;Initial Catalog=$sqlDatabase;Persist Security Info=False;User ID=${sqlUser};Password=${sqlPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

Invoke-Az webapp config connection-string set --resource-group $resourceGroup --name $webApp --connection-string-type SQLAzure --settings "SqlServerConnection=$sqlConnection"
Invoke-Az webapp config appsettings set --resource-group $resourceGroup --name $webApp --settings `
    "APPLICATIONINSIGHTS_CONNECTION_STRING=$insightsConnection" `
    "ApplicationInsightsAgent_EXTENSION_VERSION=~3" `
    "Database__AutoMigrate=true" `
    "ASPNETCORE_ENVIRONMENT=Production" `
    "WEBSITES_PORT=8080"

@"
Resource group : $resourceGroup
Web App        : $webApp
Swagger        : https://$webApp.azurewebsites.net/swagger
SQL Server     : $sqlServer.database.windows.net
Database       : $sqlDatabase
SQL user       : $sqlUser
SQL password   : $sqlPassword
Registry       : $registry
Image          : $image
App Insights   : $appInsights
API clonada de : $apiUrl ($apiBranch)
"@ | Set-Content -Encoding utf8 (Join-Path $repo "deploy-output.txt")

Get-Content (Join-Path $repo "deploy-output.txt")
