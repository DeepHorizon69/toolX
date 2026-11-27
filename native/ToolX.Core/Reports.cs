using System.Net;
using System.Text;

namespace ToolX;

public sealed class SupportReport
{
    public int SchemaVersion { get; set; } = 1;
    public string ToolXVersion { get; set; } = "0.2.3";
    public string Machine { get; set; } = Environment.MachineName;
    public string WindowsVersion { get; set; } = Environment.OSVersion.VersionString;
    public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
    public string Language { get; set; } = "en";
    public string Check { get; set; } = "";
    public Dictionary<string, string> Parameters { get; set; } = [];
    public List<OperationResult> Results { get; set; } = [];
}
public sealed record ReportDifference(string CommandId, string Key, string Field, string Before, string After, string Change);
public static class Reports
{
    public static readonly string[] General = ["system.full-specs", "troubleshooting.updates", "troubleshooting.events", "troubleshooting.devices", "storage.space", "processes.stopped-auto-services"];
    public static readonly string[] Network = ["network.ip", "network.adapters", "network.routes", "network.proxy", "network.dns", "troubleshooting.connectivity"];
    public static async Task<SupportReport> Run(Engine engine, string check, string? host, IEnumerable<string>? extras, string language, CancellationToken token, IProgress<OperationProgress>? progress = null)
    {
        if (check is not ("general" or "network")) throw new ArgumentException("Unknown check.");
        if (check == "network" && (host == null || Uri.CheckHostName(host) == UriHostNameType.Unknown)) throw new ArgumentException("A valid explicit network target is required.");
        var ids = (check == "general" ? General : Network).Concat(extras ?? []).Distinct().ToArray();
        if (ids.Any(id => !Catalog.Get(id).ReadOnly)) throw new ArgumentException("Checks accept read-only diagnostics only.");
        var report = new SupportReport { Check = check, Language = language };
        if (host != null) report.Parameters["host"] = host;
        foreach (var id in ids)
        {
            token.ThrowIfCancellationRequested();
            var parameters = new Dictionary<string, string>(); var command = Catalog.Get(id);
            if (command.Parameters.Any(p => p.Name == "host") && host != null) parameters["host"] = host;
            if (command.Parameters.Any(p => p.Name == "port")) parameters["port"] = "443";
            // Batches do not prompt for UAC. The result records diagnostics that need an elevated token.
            if (command.RequiresAdmin && !Security.IsAdmin) { report.Results.Add(new() { CommandId = id, Status = OperationStatus.PermissionDenied, Detail = "Run this diagnostic separately as administrator." }); continue; }
            report.Results.Add(await engine.Run(new(id, parameters, true), token, progress));
        }
        return report;
    }
    public static SupportReport Load(string path)
    {
        var file = new FileInfo(Paths.Local(path, false)); if (file.Length > 16 * 1024 * 1024) throw new InvalidDataException("Report too large.");
        var report = Json.Read<SupportReport>(File.ReadAllText(file.FullName));
        if (report.SchemaVersion != 1 || string.IsNullOrWhiteSpace(report.Machine) || report.Results == null || report.Results.Count > 100 || report.Results.Select(r => r.CommandId).Distinct().Count() != report.Results.Count || report.Results.Any(r => !Catalog.Commands.Any(c => c.Id == r.CommandId) || !Enum.IsDefined(r.Status) || r.Rows == null || r.Rows.Count > 2000 || r.Rows.Any(row => row == null || !row.ContainsKey("_key")))) throw new InvalidDataException("Unsupported report.");
        return report;
    }
    public static List<ReportDifference> Compare(SupportReport before, SupportReport after)
    {
        if (before.SchemaVersion != 1 || after.SchemaVersion != 1 || !before.Machine.Equals(after.Machine, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Compare schema-v1 reports from the same machine.");
        Dictionary<(string Command, string Key, string Field), string> Flatten(SupportReport report)
        {
            var values = new Dictionary<(string, string, string), string>();
            foreach (var operation in report.Results)
            {
                values[(operation.CommandId, "operation", "Status")] = operation.Status.ToString();
                foreach (var row in operation.Rows) foreach (var field in row.Where(f => f.Key is not ("_key" or "TimeCreated" or "Timestamp" or "CreatedUtc"))) values[(operation.CommandId, row.GetValueOrDefault("_key", "row"), field.Key)] = field.Value;
            }
            return values;
        }
        var left = Flatten(before); var right = Flatten(after); var differences = new List<ReportDifference>();
        foreach (var key in left.Keys.Union(right.Keys).OrderBy(k => k.Command).ThenBy(k => k.Key).ThenBy(k => k.Field))
        {
            var hasLeft = left.TryGetValue(key, out var oldValue); var hasRight = right.TryGetValue(key, out var newValue);
            if (oldValue != newValue) differences.Add(new(key.Command, key.Key, key.Field, oldValue ?? "", newValue ?? "", !hasLeft ? "Added" : !hasRight ? "Removed" : "Changed"));
        }
        return differences;
    }
    public static string Html(SupportReport report)
    {
        string E(string? value) => WebUtility.HtmlEncode(value ?? "");
        var id = report.Language == "id";
        var html = new StringBuilder("<!doctype html><html lang=\"" + (id ? "id" : "en") + "\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>TOOLX report</title><style>body{font:15px Segoe UI,sans-serif;color:#202020;background:#fff;max-width:1100px;margin:32px auto;padding:0 20px}h1{border-bottom:3px solid #245d91}section{margin:28px 0}dl{display:grid;grid-template-columns:minmax(120px,1fr) 3fr;gap:8px}dt{font-weight:600}dd{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}.row{border:1px solid #bbb;padding:12px;margin:8px 0}</style><main><h1>TOOLX " + (id ? "Laporan dukungan" : "Support report") + "</h1><p>" + E(report.Machine) + " | " + E(report.WindowsVersion) + " | " + E(report.CreatedUtc.ToString("O")) + "</p>");
        foreach (var operation in report.Results) { html.Append("<section><h2>").Append(E(L10n.CommandName(Catalog.Get(operation.CommandId), report.Language))).Append("</h2><p>").Append(E(L10n.Status(operation.Status, report.Language))).Append(" ").Append(E(operation.Detail)).Append("</p>"); foreach (var row in operation.Rows) { html.Append("<dl class=row>"); foreach (var pair in row.Where(p => p.Key != "_key")) html.Append("<dt>").Append(E(pair.Key)).Append("</dt><dd>").Append(E(pair.Value)).Append("</dd>"); html.Append("</dl>"); } html.Append("</section>"); }
        return html.Append("</main></html>").ToString();
    }
    public static void Export(SupportReport report, string path, string format)
    {
        var content = format.ToLowerInvariant() switch { "json" => Json.Write(report), "html" => Html(report), _ => throw new ArgumentException("Format must be html or json.") };
        Paths.NoReparse(Path.GetFullPath(path)); File.WriteAllText(path, content, new UTF8Encoding(false));
    }
}
