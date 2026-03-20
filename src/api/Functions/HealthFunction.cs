using System.Net;
using System.Text.Json;
using ClickCounter.Api.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace ClickCounter.Api.Functions;

public class HealthFunction
{
    private readonly ILogger<HealthFunction> _logger;
    private readonly DatabaseService _db;

    public HealthFunction(ILogger<HealthFunction> logger, DatabaseService db)
    {
        _logger = logger;
        _db = db;
    }

    [Function("Health")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequestData req)
    {
        _logger.LogInformation("Health check requested");

        var dbHealthy = await _db.CheckHealthAsync();
        var statusCode = dbHealthy ? HttpStatusCode.OK : HttpStatusCode.ServiceUnavailable;

        var response = req.CreateResponse(statusCode);
        response.Headers.Add("Content-Type", "application/json");
        await response.WriteStringAsync(JsonSerializer.Serialize(new
        {
            status = dbHealthy ? "healthy" : "unhealthy",
            database = dbHealthy ? "connected" : "unavailable",
            timestamp = DateTime.UtcNow.ToString("o")
        }));
        return response;
    }
}
