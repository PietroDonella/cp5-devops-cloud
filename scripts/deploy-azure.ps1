# Clona a API .NET, cria grupo de recursos, Azure SQL, Application Insights
# e App Service, e publica a aplicacao. Rode na raiz do repositorio.
#
#   $env:SQL_PASSWORD = "StellarGear.Cp6.2026"
#   .\scripts\deploy-azure.ps1
#
# O script verifica se o .NET SDK exigido pela API esta instalado. Se nao
# estiver, instala no diretorio do usuario com o dotnet-install oficial
# (sem precisar de administrador). Se ja estiver, pula a instalacao.

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

# Retorna a primeira versao de SDK instalada com o major pedido, ou $null.
function Get-InstalledDotnetSdk([int]$major) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { return $null }
    $sdks = & dotnet --list-sdks 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sdks) { return $null }
    foreach ($line in $sdks) {
        $version = ($line -split '\s+')[0]
        if ($version -like "$major.*") { return $version }
    }
    return $null
}

# Garante que o SDK .NET $major.x esteja no PATH. Instala em $installDir
# se nao encontrar; se ja existir, apenas informa e segue.
function Ensure-DotnetSdk([int]$major, [string]$installDir) {
    $pathSep = [IO.Path]::PathSeparator

    # Uma instalacao anterior em $installDir pode existir mas estar fora do
    # PATH desta sessao. Coloca na frente para ter prioridade sobre o SDK global.
    $userDotnet = Join-Path $installDir $(if ($IsWindows -or $env:OS -eq "Windows_NT") { "dotnet.exe" } else { "dotnet" })
    if (Test-Path $userDotnet) {
        $env:DOTNET_ROOT = $installDir
        $env:PATH = "$installDir$pathSep$env:PATH"
    }

    $found = Get-InstalledDotnetSdk $major
    if ($found) {
        Write-Host ".NET SDK $major.x ja disponivel ($found). Pulando instalacao." -ForegroundColor Green
        return
    }

    Write-Host ".NET SDK $major.x nao encontrado. SDKs atuais:" -ForegroundColor Yellow
    if (Get-Command dotnet -ErrorAction SilentlyContinue) { & dotnet --list-sdks } else { Write-Host "  (dotnet nao esta no PATH)" }
    Write-Host "Instalando .NET SDK $major.0 em $installDir (sem administrador)..."

    $isWin = $IsWindows -or $env:OS -eq "Windows_NT"
    if ($isWin) {
        $installer = Join-Path ([IO.Path]::GetTempPath()) "dotnet-install.ps1"
        Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installer -UseBasicParsing
        & $installer -Channel "$major.0" -InstallDir $installDir
    } else {
        $installer = Join-Path ([IO.Path]::GetTempPath()) "dotnet-install.sh"
        Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.sh" -OutFile $installer -UseBasicParsing
        & bash $installer --channel "$major.0" --install-dir $installDir
        if ($LASTEXITCODE -ne 0) { throw "dotnet-install.sh falhou (exit $LASTEXITCODE)." }
    }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    $env:DOTNET_ROOT = $installDir
    $env:PATH = "$installDir$pathSep$env:PATH"

    $found = Get-InstalledDotnetSdk $major
    if (-not $found) {
        throw "A instalacao terminou mas 'dotnet --list-sdks' ainda nao mostra $major.x."
    }
    Write-Host ".NET SDK instalado: $found" -ForegroundColor Green

    # Deixa pronto para as proximas sessoes (so adiciona uma vez).
    if ($isWin) {
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if ($userPath -notlike "*$installDir*") {
            [Environment]::SetEnvironmentVariable("DOTNET_ROOT", $installDir, "User")
            [Environment]::SetEnvironmentVariable("PATH", "$installDir;$userPath", "User")
            Write-Host "PATH do usuario atualizado. Novos terminais ja enxergam o SDK."
        }
    } else {
        $bashrc = Join-Path $HOME ".bashrc"
        if ((Test-Path $bashrc) -and -not (Select-String -Path $bashrc -Pattern 'DOTNET_ROOT=' -Quiet)) {
            Add-Content $bashrc "`n# .NET SDK instalado pelo deploy-azure.ps1`nexport DOTNET_ROOT=`"$installDir`"`nexport PATH=`"`$DOTNET_ROOT:`$PATH`""
        }
    }
}

$repo = Split-Path -Parent $PSScriptRoot
$apiUrl = if ($env:API_REPO_URL) { $env:API_REPO_URL } else { "https://github.com/PietroDonella/StellarGear.API.git" }
$apiBranch = if ($env:API_BRANCH) { $env:API_BRANCH } else { "cp6-azure" }
$app = Join-Path $repo ".api"
$publish = Join-Path $repo "publish"
$zip = Join-Path $repo "stellargear.zip"

# Versao major do .NET exigida. Por padrao e lida do TargetFramework do csproj
# (net10.0 -> 10); pode ser forcada com $env:DOTNET_MAJOR = "10".
$dotnetMajor = if ($env:DOTNET_MAJOR) { [int]$env:DOTNET_MAJOR } else { $null }
$dotnetUserDir = if ($env:DOTNET_USER_DIR) { $env:DOTNET_USER_DIR } else { Join-Path $HOME ".dotnet" }

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

foreach ($tool in @("git", "az")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' nao foi encontrado no PATH. Instale antes de rodar o script."
    }
}

Write-Host "Clonando a API ($apiBranch)"
Remove-Tree $app
git clone --branch $apiBranch --depth 1 $apiUrl $app
if ($LASTEXITCODE -ne 0) { throw "git clone falhou." }

$csproj = Join-Path $app "StellarGear.API/StellarGear.API.csproj"
if (-not (Test-Path $csproj)) { throw "Nao achei $csproj no repositorio clonado." }

if (-not $dotnetMajor) {
    $match = Select-String -Path $csproj -Pattern '<TargetFramework>net(\d+)' | Select-Object -First 1
    $dotnetMajor = if ($match) { [int]$match.Matches[0].Groups[1].Value } else { 10 }
}

Write-Host "Verificando .NET SDK $dotnetMajor.x"
Ensure-DotnetSdk $dotnetMajor $dotnetUserDir

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

Write-Host "App Service Linux (.NET $dotnetMajor)"
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
    --runtime "DOTNETCORE:$dotnetMajor.0"

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