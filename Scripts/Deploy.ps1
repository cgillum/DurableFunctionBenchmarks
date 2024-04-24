param(
    [string]$deploymentName="$([Environment]::UserName)-df-benchmarking",
    [string]$location="westus2",
    [switch]$yes
)

# Stop the script if any command fails
$ErrorActionPreference = 'Stop'

# Check if the Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "The Azure CLI is not installed. Please install it from https://aka.ms/az-cli-download." -ForegroundColor Red
    exit 1
}

# Check if the user is logged in
if (-not (az account show --query id -o tsv)) {
    Write-Host "Please sign in to Azure using 'az login' and select an Azure subscription using 'az account set --subscription <subscription-id>'." -ForegroundColor Red
    exit 1
}

$currentSubscription = az account show --query name -o tsv

# Check to see if the resource group already exists and offer to delete it
$resourceGroup = "$deploymentName-rg"

$alreadyExists = (az group exists --name $resourceGroup -o tsv) -eq "true"
if ($alreadyExists) {
    Write-Host "The resource group '$resourceGroup' already exists in '$currentSubscription'." -ForegroundColor Yellow
    if (-not $yes -and (Read-Host "Do you want to delete it first? (y/n)").ToLower() -eq "y") {
        Write-Host "Deleting resource group '$resourceGroup'..." -ForegroundColor Yellow
        az group delete --name $resourceGroup --yes
    }
}

# Create a resource group
# https://learn.microsoft.com/cli/azure/group?view=azure-cli-latest#az-group-create
Write-Host "Creating resource group '$resourceGroup' in $location..." -ForegroundColor Yellow
az group create --name $resourceGroup --location $location -o table

# Create an Azure Storage account
# https://learn.microsoft.com/cli/azure/storage/account#az-storage-account-create
$storage="${deploymentName}".Replace("-", "").ToLower()
Write-Host "Creating Azure Storage account '$storage'..." -ForegroundColor Yellow
az storage account create --name $storage --location "$location" --resource-group $resourceGroup --sku 'Standard_LRS'

# Create the SQL Server and database
# https://learn.microsoft.com/cli/azure/sql/server?view=azure-cli-latest#az-sql-server-create
$server = "$deploymentName-sqlserver"
Write-Host "Creating SQL Server '$server'..." -ForegroundColor Yellow
$login = "dfadmin"
$password = "P@-" + -join (1..24 | ForEach-Object {[char]((97..122) + (48..57) | Get-Random)})
az sql server create `
    --name $server `
    --resource-group $resourceGroup `
    --location "$location" `
    --admin-user $login `
    --admin-password $password `
    --output table

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# Create the firewall rule to allow Azure services to access the server
# https://learn.microsoft.com/cli/azure/sql/server/firewall-rule?view=azure-cli-latest#az-sql-server-firewall-rule-create
Write-Host "Creating firewall rule to allow access by Azure services..." -ForegroundColor Yellow
az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $server `
    --name AllowAzureServices `
    --start-ip-address 0.0.0.0 `
    --end-ip-address 0.0.0.0 `
    --output table

Write-Host "Creating firewall rules to allow access from the corporate network..." -ForegroundColor Yellow

$localIP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json" | Select-Object -ExpandProperty ip)
Write-Host "Your current public IP address is $localIP." -ForegroundColor DarkGray

# Change the IP address to Class B subnet using the System.Version APIs as a convenient way to parse the IP address
$subnet = [System.Version]::Parse($localIP)
$startIPAddress = (New-Object -TypeName System.Version -ArgumentList $subnet.Major, $subnet.Minor, 0, 0).ToString()
$endIPAddress = (New-Object -TypeName System.Version -ArgumentList $subnet.Major, $subnet.Minor, 255, 255).ToString()
    
Write-Host "Creating firewall rule to allow access from $startIPAddress to $endIPAddress..." -ForegroundColor Yellow
az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $server `
    --name AllowCorpNet1 `
    --start-ip-address $startIPAddress `
    --end-ip-address $endIPAddress `
    --output table

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# Add the current user as an Entra ID admin for the server
# https://learn.microsoft.com/cli/azure/sql/server/ad-admin?view=azure-cli-latest#az-sql-server-ad-admin-create
$user=(az account show --query user.name -o tsv)
Write-Host "Adding $user as an admin for the server..." -ForegroundColor Yellow
$uid=(az ad user show --id $user --query id -o tsv)
az sql server ad-admin create `
    --resource-group $resourceGroup `
    --server $server `
    --display-name "$user" `
    --object-id $uid `
    --output table

# Create a SQL database
# https://learn.microsoft.com/cli/azure/sql/db?view=azure-cli-latest#az-sql-db-create
$database="DurableDB"
Write-Host "Creating a database '$database'..." -ForegroundColor Yellow
az sql db create `
    --resource-group $resourceGroup `
    --name $database `
    --server $server `
    --compute-model Serverless `
    --edition Hyperscale `
    --family Gen5 `
    --collation "Latin1_General_100_BIN2_UTF8" `
    --min-capacity 2 `
    --capacity 8 `
    --output table

# Create a Azure Event Hubs namespace
# https://learn.microsoft.com/cli/azure/eventhubs/namespace?view=azure-cli-latest#az-eventhubs-namespace-create
$namespace = "$deploymentName-eh"
Write-Host "Creating Azure Event Hubs namespace '$namespace'..." -ForegroundColor Yellow
az eventhubs namespace create `
	--name $namespace `
	--resource-group $resourceGroup `
	--location "$location" `
	--sku Standard `
	--output table

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# Create a Log Analytics workspace
# https://learn.microsoft.com/cli/azure/monitor/workspace?view=azure-cli-latest#az-monitor-log-analytics-workspace-create
$workspaceName = "$deploymentName-logs"
Write-Host "Creating a Log Analytics workspace '$workspaceName'..." -ForegroundColor Yellow
az monitor log-analytics workspace create `
    --resource-group $resourceGroup `
    --workspace-name $workspaceName `
    --output table

# Create an Application Insights resource
# https://learn.microsoft.com/cli/azure/monitor/app-insights?view=azure-cli-latest#az-monitor-app-insights-component-create
$workspaceResourceId = az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $workspaceName --query id -o tsv
$appInsightsName = "$deploymentName-appinsights"
Write-Host "Creating an Application Insights resource '$appInsightsName'..." -ForegroundColor Yellow
az monitor app-insights component create `
    --resource-group $resourceGroup `
    --app $appInsightsName `
    --location "$location" `
    --workspace $workspaceResourceId `
    --output table

$appInsightsKey = az monitor app-insights component show --resource-group $resourceGroup --app $appInsightsName --query instrumentationKey -o tsv

# Create an App Service Hosting Plan
# https://learn.microsoft.com/cli/azure/functionapp/plan#az-functionapp-plan-create
Write-Host "Creating Azure Function app plan '$deploymentName-asp'..." -ForegroundColor Yellow
az functionapp plan create `
    --name "$deploymentName-asp" `
    --resource-group $resourceGroup `
    --location "$location" `
    --sku "P2v3" `
    --output table

# Create a function App
# https://learn.microsoft.com/cli/azure/functionapp#az-functionapp-create
$functionAppName = "$deploymentName-func"
Write-Host "Creating Azure Function app '$functionAppName'..." -ForegroundColor Yellow
az functionapp create `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --storage-account $storage `
    --plan "$deploymentName-asp" `
    --runtime dotnet-isolated `
    --functions-version 4 `
    --app-insights $appInsightsName `
    --app-insights-key $appInsightsKey
    --output table

# Set the environment variables on the function App for Azure Storage, Event Hubs, SQL, and Application Insights
# https://learn.microsoft.com/cli/azure/functionapp/config/appsettings?view=azure-cli-latest#az-functionapp-config-appsettings-set
Write-Host "Setting additional connection string values on the function app..." -ForegroundColor Yellow

$eventHubsKey=$(az eventhubs namespace authorization-rule keys list --resource-group $resourceGroup --namespace-name $namespace --name RootManageSharedAccessKey --query primaryKey -o tsv)
$eventHubsConnStr="Endpoint=sb://$namespace.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=$eventHubsKey"
$sqlDbConnStr="Server=tcp:$server.database.windows.net,1433;Initial Catalog=$database;Persist Security Info=False;User ID=$login;Password=$password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

az functionapp config appsettings set `
	--name $functionAppName `
	--resource-group $resourceGroup `
	--settings `
        "EventHubsConnection=$eventHubsConnStr" `
        "SQLDB_Connection=$sqlDbConnStr" `
	--output table


# Configure the function app to be use a 64-bit worker process
# https://learn.microsoft.com/cli/azure/functionapp/config#az-functionapp-config-set
Write-Host "Configuring the function app to use a 64-bit worker process..." -ForegroundColor Yellow
az functionapp config set `
	--name $functionAppName `
	--resource-group $resourceGroup `
	--use-32bit-worker-process false `
	--output table

# Ping the app to see if it starts up correctly
$functionAppUrl = az functionapp show --name $functionAppName --resource-group $resourceGroup --query defaultHostName -o tsv
curl -I $functionAppUrl

# Build the function app and publish it as a local zip file
$projectName = "DurableFunctionBenchmarks"
$functionAppDir = "../$projectName"
if (-not (Test-Path $functionAppDir)) {
    Write-Host "The function app directory '$functionAppDir' does not exist." -ForegroundColor Red
    exit 1
}
$zipFile = "$functionAppDir/$projectName.zip"
Write-Host "Building the function app and publishing it as '$zipFile'..."
dotnet publish "$functionAppDir/$projectName.csproj" -c Release -o "$functionAppDir/publish"
Compress-Archive -Path "$functionAppDir/publish/*" -DestinationPath "$zipFile" -Force

# Deploy the function app
# https://learn.microsoft.com/cli/azure/functionapp/deployment/source?view=azure-cli-latest#az-functionapp-deployment-source-config-zip
Write-Host "Deploying the function app to Azure..." -ForegroundColor Yellow
az functionapp deployment source config-zip `
	--name $functionAppName `
	--resource-group $resourceGroup `
	--src $zipFile `
	--output table

# Ping the site again to make sure it's still functional
curl -I $functionAppUrl

Write-Host "The deployment is complete. The function app is available at https://$functionAppUrl." -ForegroundColor Green

# TODO: Setup is complete - the rest of the script focuses on execution. This should probably be broken out into a
#       separate script with more configuration options, looping, etc. The below is currently just a placeholder,
#       but is useful for copy/pasting.

Write-Host "Start a perf test by sending a POST request to https://$functionAppUrl/api/ScheduleFunctionChaining?count=N"

# Pause the script and prompt to run the MSSQL test
Read-Host "Press Enter to configure the app for MSSQL testing..."

# Set the extensions/durabletask/type values to "mssql"
# https://learn.microsoft.com/cli/azure/functionapp/config/appsettings?view=azure-cli-latest#az-functionapp-config-appsettings-set
Write-Host "Reconfiguring function app for MSSQL..." -ForegroundColor Yellow
az functionapp config appsettings set `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --settings `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__type=mssql" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__connectionStringName=SQLDB_Connection" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__createDatabaseIfNotExists=true" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__extendedSessionsEnabled=false" `
    --output table

# Ping the site again to make sure it's still functional
curl -I $functionAppUrl

Write-Host "Start a perf test by sending a POST request to https://$functionAppUrl/api/ScheduleFunctionChaining?count=N"

# Pause the script and prompt to run the Netherite test
Read-Host "Press Enter to configure the app for Netherite testing..."

# Set the extensions/durabletask/type values to "netherite"
# https://learn.microsoft.com/cli/azure/functionapp/config/appsettings?view=azure-cli-latest#az-functionapp-config-appsettings-set
Write-Host "Reconfiguring function app for Netherite..." -ForegroundColor Yellow
az functionapp config appsettings set `
	--name $functionAppName `
	--resource-group $resourceGroup `
	--settings `
		"AzureFunctionsJobHost__extensions__durableTask__storageProvider__type=netherite" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__extendedSessionsEnabled=false" `
	--output table

# Ping the site again to make sure it's still functional
curl -I $functionAppUrl

Write-Host "Start a perf test by sending a POST request to https://$functionAppUrl/api/ScheduleFunctionChaining?count=N"

# Pause the script and prompt to scale out the app service plan
Read-Host "Press Enter to scale out the app service plan..."

# Scale out the number of workers in the app service plan to 4
# https://learn.microsoft.com/cli/azure/functionapp/plan?view=azure-cli-latest#az-functionapp-plan-update
Write-Host "Scaling out the app service plan to 4 instances..." -ForegroundColor Yellow
az functionapp plan update `
	--name "$deploymentName-asp" `
	--resource-group $resourceGroup `
	--number-of-workers 4 `
	--output table

# Pause the script and prompt to run the Netherite test
Read-Host "Press Enter to configure the app for Azure Storage testing..."

# Set the extensions/durabletask/type values to "azureStorage" and change partitionCount to 8
# https://learn.microsoft.com/cli/azure/functionapp/config/appsettings?view=azure-cli-latest#az-functionapp-config-appsettings-set
Write-Host "Reconfiguring function app for Azure Storage..." -ForegroundColor Yellow
az functionapp config appsettings set `
	--name $functionAppName `
	--resource-group $resourceGroup `
	--settings `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__type=azureStorage" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__connectionStringName=AzureWebJobsStorage" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__partitionCount=8" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__extendedSessionsEnabled=true" `
	--output table

# Ping the site again to make sure it's still functional
curl -I $functionAppUrl


