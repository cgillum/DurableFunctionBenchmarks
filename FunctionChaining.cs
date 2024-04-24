using System.Diagnostics;
using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using Microsoft.Extensions.Logging;

namespace DurableFunctionBenchmarks;

/// <summary>
/// Defines functions for executing a set of concurrently executing "Hello cities" function chains.
/// These functions are used for basic throughput testing.
/// </summary>
/// <remarks>
/// Use the <see cref="ScheduleFunctionChaining"/> function to start the test. Note that a
/// <c>count</c> query string parameter is required. This parameter specifies the number of
/// orchestrations to start. The orchestrations will be started in parallel.
/// </remarks>
public class FunctionChaining(ILoggerFactory loggerFactory)
{
    readonly ILogger logger = loggerFactory.CreateLogger<FunctionChaining>();

    /// <summary>
    /// Schedules N instances of the <see cref="HelloCities"/> orchestration.
    /// </summary>
    /// <remarks>
    /// The HTTP request accepts two query string parameters:
    /// <list type="bullet">
    /// <item><c>count</c>: the number of orchestrations to start. Must be a positive integer.</item>
    /// <item><c>prefix</c>: a string to use as the prefix for the instance IDs. Optional.</item>
    /// </list>
    /// </remarks>
    /// <param name="req">The HTTP request that triggered this function.</param>
    /// <param name="durableClient">The bound Durable Functions client SDK.</param>
    /// <returns>The HTTP response to return to the caller.</returns>
    [Function(nameof(ScheduleFunctionChaining))]
    public async Task<HttpResponseData> ScheduleFunctionChaining(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post")] HttpRequestData req,
        [DurableClient] DurableTaskClient durableClient)
    {
        HttpResponseData response;
        if (!int.TryParse(req.Query["count"], out int count) || count < 1)
        {
            response = req.CreateResponse(HttpStatusCode.BadRequest);
            response.Headers.Add("Content-Type", "text/plain; charset=utf-8");
            await response.WriteStringAsync("A 'count' query string parameter is required and it must contain a positive number.");
            return response;
        }

        string prefix = req.Query["prefix"] ?? string.Empty;
        prefix += DateTime.UtcNow.ToString("yyyyMMdd-hhmmss");

        this.logger.LogWarning("Scheduling {Count} orchestration(s) with a prefix of '{Prefix}'...", count, prefix);

        await Enumerable.Range(0, count).ParallelForEachAsync(200, i =>
        {
            string instanceId = $"{prefix}-{i:X16}";
            return durableClient.ScheduleNewOrchestrationInstanceAsync(
                nameof(HelloCities),
                new StartOrchestrationOptions(instanceId));
        });

        this.logger.LogWarning("All {Count} orchestrations were scheduled successfully!", count);

        response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "text/plain; charset=utf-8");
        response.Headers.Add("x-trace-id", Activity.Current?.Id);
        await response.WriteStringAsync($"Scheduled {count} orchestrations prefixed with '{prefix}'.");
        return response;
    }

    /// <summary>
    /// Orchestrator function that calls the <see cref="SayHello"/> activity function several times in a sequence.
    /// </summary>
    /// <param name="context">The orchestration context used to schedule activities.</param>
    /// <returns>Returns a list of greetings.</returns>
    [Function(nameof(HelloCities))]
    public static async Task<IList<string>> HelloCities([OrchestrationTrigger] TaskOrchestrationContext context)
    {
        List<string> results =
        [
            await context.CallSayHelloAsync("Seattle"),
            await context.CallSayHelloAsync("Amsterdam"),
            await context.CallSayHelloAsync("Hyderabad"),
            await context.CallSayHelloAsync("Shanghai"),
            await context.CallSayHelloAsync("Tokyo"),
        ];
        return results;
    }

    /// <summary>
    /// Simple activity function that returns the string "Hello, {input}!".
    /// </summary>
    /// <param name="cityName">The name of the city to greet.</param>
    /// <returns>Returns a greeting string to the orchestrator that called this activity.</returns>
    [Function(nameof(SayHello))]
    public static string SayHello([ActivityTrigger] string cityName)
    {
        return $"Hello, {cityName}!";
    }
}

