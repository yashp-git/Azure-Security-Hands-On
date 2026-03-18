using System.Net;
using System.Text.Json;
using ClickCounter.Api.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace ClickCounter.Api.Functions;

public class CountFunction
{
    private readonly ILogger<CountFunction> _logger;
    private readonly DatabaseService _db;

    public CountFunction(ILogger<CountFunction> logger, DatabaseService db)
    {
        _logger = logger;
        _db = db;
    }

    [Function("Count")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "count")] HttpRequestData req)
    {
        // Accept IP as query parameter from frontend
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        var ipAddress = query["ip"];

        if (string.IsNullOrWhiteSpace(ipAddress))
            ipAddress = GetIpFromHeaders(req);

        _logger.LogInformation("Count requested from IP: {IpAddress}", ipAddress);

        var totalCount = await _db.GetTotalCountAsync();
        var ipCount = await _db.GetIpCountAsync(ipAddress);

        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json");
        await response.WriteStringAsync(JsonSerializer.Serialize(new
        {
            totalCount,
            ipCount,
            ipAddress
        }));
        return response;
    }

    private static string GetIpFromHeaders(HttpRequestData req)
    {
        string[] headerNames = ["X-Forwarded-For", "X-Client-IP", "X-Real-IP", "CLIENT-IP"];
        foreach (var headerName in headerNames)
        {
            if (req.Headers.TryGetValues(headerName, out var values))
            {
                var raw = values.FirstOrDefault()?.Split(',', StringSplitOptions.TrimEntries).FirstOrDefault();
                if (!string.IsNullOrWhiteSpace(raw))
                {
                    var ip = StripPort(raw);
                    if (!ip.StartsWith("10.") && !ip.StartsWith("127.") && !ip.StartsWith("192.168."))
                        return ip;
                }
            }
        }
        return "unknown";
    }

    private static string StripPort(string ip)
    {
        var colonIndex = ip.LastIndexOf(':');
        if (colonIndex > 0 && !ip.Contains(']'))
            return ip[..colonIndex];
        return ip;
    }
}
