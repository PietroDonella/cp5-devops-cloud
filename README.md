# 2º Checkpoint — Aplicações e Banco em Nuvem

DevOps Tools & Cloud Computing — turma **2TDSPF**.

| Integrante | RM |
|---|---|
| Enzo Vaz | 561702 |
| Lucas Ryuji Fukuda | 562152 |
| Pietro Donella Salomão | 561722 |

Uma API .NET 10 sobe no Azure App Service, grava os dados em um Azure SQL Database (PaaS) e manda telemetria para o Application Insights. Toda a criação de recursos e o deploy são feitos por **Azure CLI**, em um único script.

## Como funciona

O script de deploy **clona a API durante a execução**. O código da aplicação mora no repositório abaixo e não é versionado aqui:

- Repositório: <https://github.com/EnzoVazz/StellarGear.API>
- Branch usada no deploy: **`cp6-azure`**

A branch `cp6-azure` é a adaptação da API para a nuvem: provider Oracle trocado por SQL Server, migração `InitialSqlServer`, Application Insights ligado e Swagger exposto em produção.

## O que tem neste repositório

| Item pedido no enunciado | Arquivo |
|---|---|
| Script do CLI (Windows / PowerShell) | [`scripts/deploy-azure.ps1`](scripts/deploy-azure.ps1) |
| Script do CLI (Azure Cloud Shell / Bash) | [`scripts/deploy-azure.sh`](scripts/deploy-azure.sh) |
| Plano B com container, se o runtime .NET 10 não existir na região | [`scripts/deploy-azure-docker.ps1`](scripts/deploy-azure-docker.ps1) |
| DDL das tabelas (colunas, PK, FK e índices) | [`database/ddl-stellargear.sql`](database/ddl-stellargear.sql) |
| Consultas para mostrar a persistência depois de cada operação | [`database/verificar-persistencia.sql`](database/verificar-persistencia.sql) |
| JSON das operações GET, POST, PUT e DELETE | [`api/operacoes-crud.json`](api/operacoes-crud.json) |
| How to da implantação | este arquivo |
| Código fonte da aplicação | clonado de [`EnzoVazz/StellarGear.API`, branch `cp6-azure`](https://github.com/EnzoVazz/StellarGear.API/tree/cp6-azure) |

## Recursos criados na Azure

Todos no grupo `rg-stellargear-cp6`, região `brazilsouth`. Os nomes levam um sufixo com data e número aleatório para não colidir com recursos de outros grupos.

| Recurso | Nome | Observação |
|---|---|---|
| Resource group | `rg-stellargear-cp6` | |
| SQL Server (lógico) | `sql-stellargear-<sufixo>` | admin `stellaradmin` |
| SQL Database | `StellarGearDb` | service objective `Basic` |
| Application Insights | `appi-stellargear-<sufixo>` | tipo `web` |
| App Service plan | `asp-stellargear-<sufixo>` | Linux, SKU `B1` |
| Web App | `app-stellargear-<sufixo>` | runtime `DOTNETCORE:10.0`, HTTPS only |

Duas regras de firewall são criadas no SQL Server: `AllowAzureServices` (`0.0.0.0`), que libera o Web App, e `AllowClient`, com o IP público da máquina que rodou o script, para dar acesso ao Query Editor do portal.

## Pré-requisitos

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az --version`)
- [.NET 10 SDK](https://dotnet.microsoft.com/download) (`dotnet --version`)
- Git (`git --version`)
- Uma assinatura Azure com permissão para criar App Service, Azure SQL e Application Insights

No Bash é preciso também o `zip`, que já vem no Azure Cloud Shell.

## Implantação

### 1. Entrar na conta

```powershell
az login
az account set --subscription "<nome ou id da assinatura>"
```

### 2. Definir a senha do SQL

A senha nunca fica no repositório. Ela entra por variável de ambiente e precisa atender à política da Azure: no mínimo 8 caracteres, com maiúscula, minúscula e número ou símbolo.

```powershell
$env:SQL_PASSWORD = "StellarGear.Cp6.2026"
```

### 3. Rodar o script

Na raiz deste repositório:

```powershell
.\scripts\deploy-azure.ps1
```

No Azure Cloud Shell ou Git Bash:

```bash
export SQL_PASSWORD='StellarGear.Cp6.2026'
bash scripts/deploy-azure.sh
```

O script leva algo entre 8 e 12 minutos e executa, nesta ordem:

1. `git clone --branch cp6-azure --depth 1` da API para a pasta `.api/` (ignorada pelo git).
2. `az group create` — grupo de recursos em `brazilsouth`.
3. `az sql server create` e `az sql db create` — Azure SQL PaaS, banco `StellarGearDb`.
4. `az sql server firewall-rule create` — duas vezes: serviços da Azure e o IP da sua máquina.
5. `az monitor app-insights component create` e leitura da connection string.
6. `az appservice plan create` — plano Linux B1.
7. `az webapp create --runtime "DOTNETCORE:10.0"`.
8. `az webapp config connection-string set` — connection string `SqlServerConnection`, tipo `SQLAzure`.
9. `az webapp config appsettings set` — Application Insights, `Database__AutoMigrate=true` e `ASPNETCORE_ENVIRONMENT=Production`.
10. `az webapp config set --startup-file` e `az webapp update --https-only true`.
11. `dotnet publish -c Release`, compactação em zip e `az webapp deploy --type zip`.

No fim ele grava `deploy-output.txt` com os nomes gerados, a URL do Swagger e a senha do SQL. **Esse arquivo não vai para o git** — está no `.gitignore`.

Para rodar o deploy a partir de outro fork ou branch da API:

```powershell
$env:API_REPO_URL = "https://github.com/<seu-usuario>/StellarGear.API.git"
$env:API_BRANCH   = "cp6-azure"
```

### 4. Conferir que subiu

Espere cerca de um minuto depois do deploy e abra:

```
https://app-stellargear-<sufixo>.azurewebsites.net/swagger
```

Na primeira requisição a aplicação roda `Database.Migrate()` e cria as tabelas no Azure SQL. Se a tabela `traje` estiver vazia, ela grava um conjunto de exemplo: um passageiro, o traje ligado a ele, um médico, um histórico médico, uma leitura de sensor e um alerta. Isso acontece uma vez só; reiniciar o Web App não duplica as linhas.

### 5. Criar as tabelas manualmente (opcional)

Se preferir mostrar o DDL rodando antes da aplicação, abra o banco `StellarGearDb` no portal, vá em **Query editor (preview)**, entre com `stellaradmin` e a senha, e execute [`database/ddl-stellargear.sql`](database/ddl-stellargear.sql). O script é idempotente: não recria o que já existe, e insere a linha correspondente em `__EFMigrationsHistory` para a migração do EF não tentar criar tudo de novo.

## Banco de dados

O par master-detail pedido no enunciado:

- **`passageiro`** (master) — PK `id_passageiro`
- **`traje`** (detail) — PK `id_traje`, FK `FK_traje_passageiro_id_passageiro` em `traje.id_passageiro` → `passageiro.id_passageiro`, com `ON DELETE CASCADE`

O modelo completo tem seis tabelas e cinco chaves estrangeiras:

| Detail | Coluna | Master | Chave estrangeira |
|---|---|---|---|
| `traje` | `id_passageiro` | `passageiro` | `FK_traje_passageiro_id_passageiro` |
| `historico_medico` | `id_passageiro` | `passageiro` | `FK_historico_medico_passageiro_id_passageiro` |
| `leitura_sensor` | `id_traje` | `traje` | `FK_leitura_sensor_traje_id_traje` |
| `alerta_emergencia` | `id_leitura` | `leitura_sensor` | `FK_alerta_emergencia_leitura_sensor_id_leitura` |
| `alerta_emergencia` | `id_medico` | `medico` | `FK_alerta_emergencia_medico_id_medico` |

## Demonstrar a persistência

Os corpos de requisição de cada operação estão em [`api/operacoes-crud.json`](api/operacoes-crud.json). As consultas estão numeradas em [`database/verificar-persistencia.sql`](database/verificar-persistencia.sql) na mesma ordem. A sequência sugerida para a apresentação, alternando entre o Swagger e o Query editor:

| # | Operação no Swagger | Consulta no Query editor |
|---|---|---|
| 1 | `POST /api/Passageiro` | `SELECT ... FROM passageiro` — a linha nova aparece |
| 2 | `GET /api/Passageiro/{id}` | mesma linha filtrada pelo id |
| 3 | `PUT /api/Passageiro/{id}` | a coluna alterada já vem com o valor novo |
| 4 | `POST /api/Traje` | `JOIN` entre `traje` e `passageiro`, mostrando a FK preenchida |
| 5 | `GET /api/Traje` | lista de trajes |
| 6 | `PUT /api/Traje/{id}` | `codigo_rfid` atualizado |
| 7 | `DELETE /api/Traje/{id}` | o traje some e o passageiro continua |
| 8 | `DELETE /api/Passageiro/{id}` | passageiro some e o cascade leva os trajes junto |

Vale começar a consulta das FKs (primeiro bloco do arquivo, em `sys.foreign_keys`) para mostrar o relacionamento antes de qualquer operação.

## Application Insights

Depois de algumas requisições no Swagger, abra o recurso `appi-stellargear-<sufixo>` no portal:

- **Live metrics** — requisições chegando em tempo real
- **Application map** — o Web App e a dependência de SQL
- **Performance** e **Failures** — tempo de resposta por endpoint e erros
- **Logs** — por exemplo:

```kusto
requests
| where timestamp > ago(30m)
| project timestamp, name, resultCode, duration
| order by timestamp desc
```

A telemetria é ligada de dois jeitos: `builder.Services.AddApplicationInsightsTelemetry()` no código da API e as app settings `APPLICATIONINSIGHTS_CONNECTION_STRING` e `ApplicationInsightsAgent_EXTENSION_VERSION=~3` configuradas pelo script.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `az webapp create` reclama do runtime | Rode `az webapp list-runtimes --os-type linux`. Se `DOTNETCORE:10.0` não estiver na lista, use `.\scripts\deploy-azure-docker.ps1`, que compila a imagem no Azure Container Registry. |
| Senha recusada no `az sql server create` | A política pede 8+ caracteres com maiúscula, minúscula e número ou símbolo, e a senha não pode conter o nome do usuário. |
| HTTP 500 na primeira requisição | O App Service ainda está subindo. Espere cerca de um minuto. Se continuar, veja `az webapp log tail -g rg-stellargear-cp6 -n app-stellargear-<sufixo>`. |
| Query editor dá erro de firewall | Seu IP mudou. Rode `az sql server firewall-rule create -g rg-stellargear-cp6 -s sql-stellargear-<sufixo> -n MeuIp --start-ip-address <ip> --end-ip-address <ip>`. |
| O nome do Web App já existe | Rode o script de novo: o sufixo é gerado a cada execução. |

## Apagar tudo

```powershell
az group delete --name rg-stellargear-cp6 --yes --no-wait
```
