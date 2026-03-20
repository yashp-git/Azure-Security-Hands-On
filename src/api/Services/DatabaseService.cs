using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace ClickCounter.Api.Services;

public class DatabaseService
{
    private readonly string _connectionString;

    public DatabaseService(IConfiguration configuration)
    {
        _connectionString = configuration["SqlConnectionString"]
            ?? throw new InvalidOperationException("SqlConnectionString is not configured.");
    }

    private SqlConnection CreateConnection() => new(_connectionString);

    public async Task RecordClickAsync(string ipAddress)
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();

        await using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO dbo.ClickRecords (IpAddress) VALUES (@IpAddress)";
        command.Parameters.Add(new SqlParameter("@IpAddress", System.Data.SqlDbType.NVarChar, 45) { Value = ipAddress });
        await command.ExecuteNonQueryAsync();
    }

    public async Task<int> GetTotalCountAsync()
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();

        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM dbo.ClickRecords";
        var result = await command.ExecuteScalarAsync();
        return Convert.ToInt32(result);
    }

    public async Task<int> GetIpCountAsync(string ipAddress)
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();

        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM dbo.ClickRecords WHERE IpAddress = @IpAddress";
        command.Parameters.Add(new SqlParameter("@IpAddress", System.Data.SqlDbType.NVarChar, 45) { Value = ipAddress });
        var result = await command.ExecuteScalarAsync();
        return Convert.ToInt32(result);
    }

    public async Task<bool> CheckHealthAsync()
    {
        try
        {
            await using var connection = CreateConnection();
            await connection.OpenAsync();

            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT 1";
            await command.ExecuteScalarAsync();
            return true;
        }
        catch
        {
            return false;
        }
    }
}
