using System.Net;
using System.Text.Json;
using ClickCounter.Api.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace ClickCounter.Api.Functions;

public class ClickFunction
{
    private readonly ILogger<ClickFunction> _logger;
    private readonly DatabaseService _db;

    public ClickFunction(ILogger<ClickFunction> logger, DatabaseService db)
    {
        _logger = logger;
        _db = db;
    }

    [Function("Click")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "click")] HttpRequestData req)
    {
        var ipAddress = await GetClientIpAddressAsync(req);
        _logger.LogInformation("Click recorded from IP: {IpAddress}", ipAddress);

        await _db.RecordClickAsync(ipAddress);

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

    private static async Task<string> GetClientIpAddressAsync(HttpRequestData req)
    {
        // 1. Check request body for client-provided IP
        try
        {
            var body = await req.ReadAsStringAsync();
            if (!string.IsNullOrWhiteSpace(body))
            {
                var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("ipAddress", out var ipProp))
                {
                    var ip = ipProp.GetString();
                    if (!string.IsNullOrWhiteSpace(ip))
                        return ip;
                }
            }
        }
        catch { /* body not JSON or missing property — fall through */ }

        return GetIpFromHeaders(req);
    }

    private static string GetIpFromHeaders(HttpRequestData req)
    {
        // Check standard proxy headers
        string[] headerNames = ["X-Forwarded-For", "X-Client-IP", "X-Real-IP", "CLIENT-IP"];
        foreach (var headerName in headerNames)
        {
            if (req.Headers.TryGetValues(headerName, out var values))
            {
                var raw = values.FirstOrDefault()?.Split(',', StringSplitOptions.TrimEntries).FirstOrDefault();
                if (!string.IsNullOrWhiteSpace(raw))
                {
                    var ip = StripPort(raw);
                    // Skip private/internal IPs
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
