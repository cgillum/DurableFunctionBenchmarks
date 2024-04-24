# Durable Function Benchmarks

This project is designed to make it easy to run [Durable Functions](https://docs.microsoft.com/azure/azure-functions/durable/durable-functions-overview) benchmark tests in Azure.

## Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- An [Azure Subscription](https://azure.microsoft.com/)
- (Optional) [Azure Functions Core Tools](https://docs.microsoft.com/azure/azure-functions/functions-run-local)

## Getting Started

1. Clone the repository
2. Open a terminal and navigate to the [Scripts](./Scripts) directory.
3. Run the `Deploy.ps1` script to deploy the Azure Functions to your Azure subscription.

Note that the deploy script will also take care of configuring any required secrets, such as the connection strings for the Azure Storage and Azure SQL Database backends. These secrets are randomly generated. In the future, the script may be updated to use only managed identities.

## Running Benchmarks

The above script can guide you through running *some* benchmarks, but you can do them manually as well. The two main parameters you'll want to configure are:

1. The number of VM instances to run
1. The Durable Functions backend to use

### Configuring the type and number of VM instances

The deploy script currently hardcodes the function app to run on Azure App Service P2v3 instances, which are powerful 4-core VMs but can be expensive. The Azure CLI command that creates the App Service plan is:

```powershell
az functionapp plan create `
    --name "$deploymentName-asp" `
    --resource-group $resourceGroup `
    --location "$location" `
    --sku "P2v3" `
    --output table
```

A separate command can be used to change the number of VM instances:

```powershell
az functionapp plan update `
    --name "$deploymentName-asp" `
    --resource-group $resourceGroup `
    --number-of-workers 4 `
    --output table
```

Note that it may take a few minutes for the changes to take effect.

### Configuring the Durable Functions backend

The Durable Functions backend can be configured in the `host.json` file. However, to avoid requiring a redeployment just to change the backend type, the project is configured to use all three backends simultaneously. You can then choose which backend to use by updating environment variables on the deployed app.

#### Azure Storage

This command configures the function app to use Azure Storage with the specified number of partitions and enables extended sessions:

```powershell
az functionapp config appsettings set `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --settings `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__type=azureStorage" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__connectionStringName=AzureWebJobsStorage" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__partitionCount=8" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__extendedSessionsEnabled=true" `
    --output table
```

Note that before changing the number of partitions, you must first delete the `{username}dfbenchmarking-leases/taskhub.json` file in the Azure Storage account. Otherwise, the function app may continue to use the old number of partitions.

#### Azure SQL Database (MSSQL)

This command configures the function app to use Azure SQL Database (MSSQL) backend.

```powershell
az functionapp config appsettings set `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --settings `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__type=mssql" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__connectionStringName=SQLDB_Connection" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__createDatabaseIfNotExists=true" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__extendedSessionsEnabled=false" `
    --output table
```

 Note that extended sessions are not supported with the MSSQL backend, which is why we must set it to `false` to avoid running into runtime problems.

#### Netherite

This command configures the function app to use Netherite backend:

```powershell
az functionapp config appsettings set `
    --name $functionAppName `
    --resource-group $resourceGroup `
    --settings `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__type=netherite" `
        "AzureFunctionsJobHost__extensions__durableTask__storageProvider__extendedSessionsEnabled=false" `
    --output table
```

Note that extended sessions are not supported with the Netherite backend (it has its own internal implementation of this feature, which is always enabled), which is why we must set it to `false` to avoid running into compatibility problems.

### Starting a test run

Tests can be run by sending an HTTP request to the deployed function app. For example, the following `cURL` command sends a request to start a test run with 5000 orchestrations:

```powershell
curl -X POST https://$functionAppUrl/api/ScheduleFunctionChaining?count=5000
```

The function app will response with an HTTP 200 status code and a text response that looks something like the following:

```plaintext
Scheduled 5000 orchestrations prefixed with '20240424-040847'.
```

This prefix is a timestamp that can be used to identify all the orchestration instances that were created as part of this test run.

### Collecting the results

If you're part of the Azure Functions engineering team, you can find all the necessary traces for measuring latency and throughput numbers in Kusto. The following Kusto query will show the throughput results for a run with prefix `20240424-040847`:

```kql
DurableFunctionsEvents
| where TIMESTAMP between (datetime(2024-04-23 17:00:00) .. 3d)
| where ProviderName == "WebJobs-Extensions-DurableTask"
| where AppName == "xxx-df-benchmarking-func"
| where InstanceId startswith "20240424-040847"
| where FunctionType == "Orchestrator"
| where IsReplay != true
| summarize
    Scheduled   = countif(TaskName == "FunctionScheduled"),
    Started     = countif(TaskName == "FunctionStarting"),
    Completed   = countif(TaskName == "FunctionCompleted"),
    Failed      = countif(TaskName == "FunctionFailed"),
    StartTime   = min(TIMESTAMP),
    LastUpdated = max(TIMESTAMP),
    Workers = dcount(RoleInstance)
    by EventStampName, ExtensionVersion
| extend Duration = LastUpdated - StartTime
| extend TPS = Completed / (Duration / 1s)
| order by StartTime asc
```

The result will look something like the following:

| EventStampName | ExtensionVersion | Scheduled | Started | Completed | Failed | StartTime | LastUpdated | Workers | Duration | TPS |
|----------------|------------------|-----------|---------|-----------|--------|-----------|-------------|---------|----------|-----|
| waws-prod-mwh-099 | 2.13.2 | 5000 | 5000 | 5000 | 0 | 2024-04-24 04:08:47.7466773 | 2024-04-24 04:08:51.9985005 | 8 | 00:00:04.2518232 | 1175.96611260788 |

The `TPS` column shows the throughput in transactions per second. The `Workers` column shows the number of VM instances that were used to run the orchestrations, which should generally match the number of VM instances that you previously configured for the App Service plan.

If you're not part of the Azure Functions engineering team, you can still collect the results by going to the app's Azure Application Insights resource, which is automatically configured for the deployed function app. You can then use the portal UI to query the `traces` collection using queries similar to the one above (some translation will be required since the Application Insights logs are less structured).
