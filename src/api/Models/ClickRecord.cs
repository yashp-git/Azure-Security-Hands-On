namespace ClickCounter.Api.Models;

public class ClickRecord
{
    public int Id { get; set; }
    public string IpAddress { get; set; } = string.Empty;
    public DateTime ClickedAt { get; set; }
}
