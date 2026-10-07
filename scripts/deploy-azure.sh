#!/usr/bin/env bash
# Mesmo fluxo do deploy-azure.ps1, para Azure Cloud Shell ou Git Bash.
# Rode na raiz do repositorio.
#   export SQL_PASSWORD='StellarGear.Cp6.2026'
#   bash scripts/deploy-azure.sh
#
# O script verifica se o .NET SDK exigido pela API esta disponivel. Se nao
# estiver (caso do Cloud Shell, que vem so com o SDK 9), instala no diretorio
# do usuario com o dotnet-install.sh oficial, sem precisar de sudo.

set -euo pipefail

if [[ -z "${SQL_PASSWORD:-}" ]]; then
  echo "Defina SQL_PASSWORD antes de rodar. Exemplo: export SQL_PASSWORD='StellarGear.Cp6.2026'"
  exit 1
fi

for tool in git az zip curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "'$tool' nao esta no PATH."; exit 1; }
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
API_REPO_URL="${API_REPO_URL:-https://github.com/PietroDonella/StellarGear.API.git}"
API_BRANCH="${API_BRANCH:-cp6-azure}"
APP="$REPO/.api"
PUBLISH="$REPO/publish"
ZIP="$REPO/stellargear.zip"

# Versao major do .NET exigida. Por padrao e lida do TargetFramework do csproj
# (net10.0 -> 10); pode ser forcada com DOTNET_MAJOR=10.
DOTNET_MAJOR="${DOTNET_MAJOR:-}"
DOTNET_USER_DIR="${DOTNET_USER_DIR:-$HOME/.dotnet}"

SUFFIX="$(date +%d%H%M%S)$RANDOM"
LOCATION="brazilsouth"
RESOURCE_GROUP="rg-stellargear-cp6"
PLAN="asp-stellargear-${SUFFIX}"
WEBAPP="app-stellargear-${SUFFIX}"
SQL_SERVER="sql-stellargear-${SUFFIX}"
SQL_DATABASE="StellarGearDb"
SQL_USER="stellaradmin"
APPINSIGHTS="appi-stellargear-${SUFFIX}"

# Imprime a primeira versao de SDK instalada com o major pedido (vazio se nao houver).
installed_sdk_version() {
  local major="$1"
  command -v dotnet >/dev/null 2>&1 || return 0
  dotnet --list-sdks 2>/dev/null | awk '{print $1}' | grep -E "^${major}\." | head -n1 || true
}

# Retorna 0 se algum SDK instalado (visivel no PATH atual) tem o major pedido.
has_dotnet_sdk() {
  [[ -n "$(installed_sdk_version "$1")" ]]
}

ensure_dotnet_sdk() {
  local major="$1"

  # Uma instalacao anterior em ~/.dotnet pode existir mas estar fora do PATH
  # (o Cloud Shell nao persiste o PATH entre sessoes). Coloca na frente para
  # que tenha prioridade sobre /usr/share/dotnet.
  if [[ -x "$DOTNET_USER_DIR/dotnet" ]]; then
    export DOTNET_ROOT="$DOTNET_USER_DIR"
    export PATH="$DOTNET_USER_DIR:$PATH"
  fi

  if has_dotnet_sdk "$major"; then
    echo ".NET SDK ${major}.x ja disponivel ($(installed_sdk_version "$major")). Pulando instalacao."
    return 0
  fi

  echo ".NET SDK ${major}.x nao encontrado. SDKs atuais:"
  dotnet --list-sdks 2>/dev/null || echo "  (dotnet nao esta no PATH)"
  echo "Instalando .NET SDK ${major}.0 em ${DOTNET_USER_DIR} (sem sudo)..."

  local installer
  installer="$(mktemp)"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer"
  bash "$installer" --channel "${major}.0" --install-dir "$DOTNET_USER_DIR"
  rm -f "$installer"

  export DOTNET_ROOT="$DOTNET_USER_DIR"
  export PATH="$DOTNET_USER_DIR:$PATH"

  if ! has_dotnet_sdk "$major"; then
    echo "A instalacao terminou mas 'dotnet --list-sdks' ainda nao mostra ${major}.x."
    exit 1
  fi

  echo ".NET SDK instalado: $(installed_sdk_version "$major")"

  # Deixa pronto para as proximas sessoes do Cloud Shell (so adiciona uma vez).
  if [[ -w "$HOME/.bashrc" ]] && ! grep -q 'DOTNET_ROOT=' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# .NET SDK instalado pelo deploy-azure.sh'
      echo "export DOTNET_ROOT=\"$DOTNET_USER_DIR\""
      echo 'export PATH="$DOTNET_ROOT:$PATH"'
    } >> "$HOME/.bashrc"
  fi
}

echo "Clonando a API (${API_BRANCH})"
rm -rf "$APP"
git clone --branch "$API_BRANCH" --depth 1 "$API_REPO_URL" "$APP"

CSPROJ="$APP/StellarGear.API/StellarGear.API.csproj"
[[ -f "$CSPROJ" ]] || { echo "Nao achei $CSPROJ no repositorio clonado."; exit 1; }

if [[ -z "$DOTNET_MAJOR" ]]; then
  DOTNET_MAJOR="$(grep -oE '<TargetFramework>net[0-9]+' "$CSPROJ" | grep -oE '[0-9]+' | head -n1 || true)"
  DOTNET_MAJOR="${DOTNET_MAJOR:-10}"
fi

echo "Verificando .NET SDK ${DOTNET_MAJOR}.x"
ensure_dotnet_sdk "$DOTNET_MAJOR"

az account show --query name -o tsv >/dev/null
az extension add --name application-insights --only-show-errors || true

echo "Grupo de recursos"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "Azure SQL (PaaS)"
az sql server create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SQL_SERVER" \
  --location "$LOCATION" \
  --admin-user "$SQL_USER" \
  --admin-password "$SQL_PASSWORD"

az sql db create \
  --resource-group "$RESOURCE_GROUP" \
  --server "$SQL_SERVER" \
  --name "$SQL_DATABASE" \
  --service-objective Basic \
  --backup-storage-redundancy Local

az sql server firewall-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --server "$SQL_SERVER" \
  --name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0

CLIENT_IP="$(curl -fsS https://api.ipify.org)"
az sql server firewall-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --server "$SQL_SERVER" \
  --name AllowClient \
  --start-ip-address "$CLIENT_IP" \
  --end-ip-address "$CLIENT_IP"

echo "Application Insights"
az monitor app-insights component create \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --app "$APPINSIGHTS" \
  --application-type web

INSIGHTS_CONNECTION="$(az monitor app-insights component show \
  --resource-group "$RESOURCE_GROUP" \
  --app "$APPINSIGHTS" \
  --query connectionString -o tsv)"

echo "App Service Linux (.NET ${DOTNET_MAJOR})"
az appservice plan create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PLAN" \
  --location "$LOCATION" \
  --is-linux \
  --sku B1

az webapp create \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN" \
  --name "$WEBAPP" \
  --runtime "DOTNETCORE:${DOTNET_MAJOR}.0"

SQL_CONNECTION="Server=tcp:${SQL_SERVER}.database.windows.net,1433;Initial Catalog=${SQL_DATABASE};Persist Security Info=False;User ID=${SQL_USER};Password=${SQL_PASSWORD};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

az webapp config connection-string set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP" \
  --connection-string-type SQLAzure \
  --settings "SqlServerConnection=${SQL_CONNECTION}"

az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP" \
  --settings \
    "APPLICATIONINSIGHTS_CONNECTION_STRING=${INSIGHTS_CONNECTION}" \
    "ApplicationInsightsAgent_EXTENSION_VERSION=~3" \
    "XDT_MicrosoftApplicationInsights_Mode=default" \
    "Database__AutoMigrate=true" \
    "ASPNETCORE_ENVIRONMENT=Production" \
    "SCM_DO_BUILD_DURING_DEPLOYMENT=false"

az webapp config set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP" \
  --startup-file "dotnet StellarGear.API.dll"

az webapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP" \
  --https-only true

echo "Publicando a API"
rm -rf "$PUBLISH"
rm -f "$ZIP"
dotnet publish "$CSPROJ" -c Release -o "$PUBLISH"
(
  cd "$PUBLISH"
  zip -q -r "$ZIP" .
)

echo "Deploy no Web App"
az webapp deploy \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP" \
  --src-path "$ZIP" \
  --type zip

cat > "$REPO/deploy-output.txt" <<EOF
Resource group : ${RESOURCE_GROUP}
Web App        : ${WEBAPP}
Swagger        : https://${WEBAPP}.azurewebsites.net/swagger
SQL Server     : ${SQL_SERVER}.database.windows.net
Database       : ${SQL_DATABASE}
SQL user       : ${SQL_USER}
SQL password   : ${SQL_PASSWORD}
Firewall IP    : ${CLIENT_IP}
App Insights   : ${APPINSIGHTS}
API clonada de : ${API_REPO_URL} (${API_BRANCH})
EOF

echo
cat "$REPO/deploy-output.txt"
echo "Dados salvos em deploy-output.txt. Nao commite esse arquivo: ele tem a senha."
echo "Aguarde cerca de 1 minuto e abra o Swagger. A primeira requisicao cria as tabelas."