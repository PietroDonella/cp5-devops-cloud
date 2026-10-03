# Clona a API .NET, cria grupo de recursos, Azure SQL, Application Insights
# e App Service, e publica a aplicacao. Rode na raiz do repositorio.
#
#   $env:SQL_PASSWORD = "StellarGear.Cp6.2026"
#   .\scripts\deploy-azure.ps1

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
$apiUrl = if ($env:API_REPO_URL) { $env:API_REPO_URL } else { "https://github.com/EnzoVazz/StellarGear.API.git" }
$apiBranch = if ($env:API_BRANCH) { $env:API_BRANCH } else { "cp6-azure" }
$app = Join-Path $repo ".api"
$publish = Join-Path $repo "publish"
$zip = Join-Path $repo "stellargear.zip"

$suffix = (Get-Date -Format "ddHHmmss") + (Get-Random -Maximum 9999).ToString("0000")
$location = "brazilsouth"
$resourceGroup = "rg-stellargear-cp6"
$plan = "asp-stellargear-$suffix"
$webApp = "app-stellargear-$suffix"
$sqlServer = "sql-stellargear-$suffix"
$sqlDatabase = "StellarGearDb"
$sqlUser = "stellaradmin"
$appInsights = "appi-stellargear-$suffix"
$sqlPassword = $env:SQL_PASSWORD

foreach ($tool in @("git", "az", "dotnet")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' nao foi encontrado no PATH. Instale antes de rodar o script."
    }
}

Write-Host "Clonando a API ($apiBranch)"
Remove-Tree $app
git clone --branch $apiBranch --depth 1 $apiUrl $app
if ($LASTEXITCODE -ne 0) { throw "git clone falhou." }

$csproj = Join-Path $app "StellarGear.API\StellarGear.API.csproj"
if (-not (Test-Path $csproj)) { throw "Nao achei $csproj no repositorio clonado." }

Write-Host "Conferindo login do Azure CLI..."
az account show --query name -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) {
    az login
    if ($LASTEXITCODE -ne 0) { throw "az login falhou." }
}

$extension = az extension show --name application-insights --query name -o tsv 2>$null
if (-not $extension) {
    Invoke-Az extension add --name application-insights
}

Write-Host "Grupo de recursos"
Invoke-Az group create --name $resourceGroup --location $location

Write-Host "Azure SQL (PaaS)"
Invoke-Az sql server create `
    --resource-group $resourceGroup `
    --name $sqlServer `
    --location $location `
    --admin-user $sqlUser `
    --admin-password $sqlPassword

Invoke-Az sql db create `
    --resource-group $resourceGroup `
    --server $sqlServer `
    --name $sqlDatabase `
    --service-objective Basic `
    --backup-storage-redundancy Local

Invoke-Az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $sqlServer `
    --name AllowAzureServices `
    --start-ip-address 0.0.0.0 `
    --end-ip-address 0.0.0.0

$clientIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Invoke-Az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $sqlServer `
    --name AllowClient `
    --start-ip-address $clientIp `
    --end-ip-address $clientIp

Write-Host "Application Insights"
Invoke-Az monitor app-insights component create `
    --resource-group $resourceGroup `
    --location $location `
    --app $appInsights `
    --application-type web

$insightsConnection = az monitor app-insights component show `
    --resource-group $resourceGroup `
    --app $appInsights `
    --query connectionString `
    -o tsv
if ($LASTEXITCODE -ne 0 -or -not $insightsConnection) {
    throw "Nao foi possivel ler a connection string do Application Insights."
}

Write-Host "App Service Linux (.NET 10)"
Invoke-Az appservice plan create `
    --resource-group $resourceGroup `
    --name $plan `
    --location $location `
    --is-linux `
    --sku B1

Invoke-Az webapp create `
    --resource-group $resourceGroup `
    --plan $plan `
    --name $webApp `
    --runtime "DOTNETCORE:10.0"

$sqlConnection = "Server=tcp:$sqlServer.database.windows.net,1433;Initial Catalog=$sqlDatabase;Persist Security Info=False;User ID=${sqlUser};Password=${sqlPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

Invoke-Az webapp config connection-string set `
    --resource-group $resourceGroup `
    --name $webApp `
    --connection-string-type SQLAzure `
    --settings "SqlServerConnection=$sqlConnection"

Invoke-Az webapp config appsettings set `
    --resource-group $resourceGroup `
    --name $webApp `
    --settings `
        "APPLICATIONINSIGHTS_CONNECTION_STRING=$insightsConnection" `
        "ApplicationInsightsAgent_EXTENSION_VERSION=~3" `
        "XDT_MicrosoftApplicationInsights_Mode=default" `
        "Database__AutoMigrate=true" `
        "ASPNETCORE_ENVIRONMENT=Production" `
        "SCM_DO_BUILD_DURING_DEPLOYMENT=false"

Invoke-Az webapp config set `
    --resource-group $resourceGroup `
    --name $webApp `
    --startup-file "dotnet StellarGear.API.dll"

Invoke-Az webapp update `
    --resource-group $resourceGroup `
    --name $webApp `
    --https-only true

Write-Host "Publicando a API"
Remove-Tree $publish
if (Test-Path $zip) { Remove-Item $zip -Force }

dotnet publish $csproj -c Release -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish falhou." }

Push-Location $publish
tar -a -c -f $zip *
Pop-Location

Write-Host "Deploy no Web App"
Invoke-Az webapp deploy `
    --resource-group $resourceGroup `
    --name $webApp `
    --src-path $zip `
    --type zip

$url = "https://$webApp.azurewebsites.net"
$summary = @"
Resource group : $resourceGroup
Web App        : $webApp
Swagger        : $url/swagger
SQL Server     : $sqlServer.database.windows.net
Database       : $sqlDatabase
SQL user       : $sqlUser
SQL password   : $sqlPassword
Firewall IP    : $clientIp
App Insights   : $appInsights
API clonada de : $apiUrl ($apiBranch)
"@

$summary | Set-Content -Encoding utf8 (Join-Path $repo "deploy-output.txt")
Write-Host ""
Write-Host $summary
Write-Host "Dados salvos em deploy-output.txt. Nao commite esse arquivo: ele tem a senha."
Write-Host "Aguarde cerca de 1 minuto e abra $url/swagger"
Write-Host "A primeira requisicao cria as tabelas no Azure SQL."
