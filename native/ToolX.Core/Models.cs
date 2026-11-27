using System.Diagnostics;
using System.Globalization;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ToolX;

public static class Json
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true, WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    public static T Read<T>(string text) => JsonSerializer.Deserialize<T>(text, Options) ?? throw new InvalidDataException("Empty JSON.");
    public static string Write<T>(T value) => JsonSerializer.Serialize(value, Options);
}

public sealed record ParameterDefinition(string Name, string Type, string Label, bool Required, JsonElement Default, long? Minimum, long? Maximum, string[]? AllowedValues);
public sealed record Compatibility(int MinimumBuild, string[] Architectures, string[] Capabilities);
public sealed record CommandDefinition(string Id, string Name, string Description, string Category, string[] Keywords, string SourceKind, string ExecutionType, string TargetId, ParameterDefinition[] Parameters, bool RequiresAdmin, Compatibility Compatibility, string Risk, string Confirmation, string Consequences, string Cost, string NetworkAccess, string Cancellation)
{
    public string Handler => TargetId;
    public bool ReadOnly => Risk == "ReadOnly";
}
public sealed record OperationRequest(string CommandId, Dictionary<string, string> Parameters, bool Confirmed = false, string? Confirmation = null, CleanupItem[]? CleanupPreview = null);
public sealed record OperationProgress(string CommandId, string Message);
public enum OperationStatus { Succeeded, Failed, Partial, Cancelled, Unavailable, PermissionDenied }
public sealed class OperationResult
{
    public string CommandId { get; set; } = "";
    public OperationStatus Status { get; set; }
    public DateTimeOffset StartedUtc { get; set; } = DateTimeOffset.UtcNow;
    public long DurationMs { get; set; }
    public int? ExitCode { get; set; }
    public string Detail { get; set; } = "";
    public List<Dictionary<string, string>> Rows { get; set; } = [];
}

public static class Catalog
{
    private sealed record Document(CommandDefinition[] Commands);
    public const int SchemaVersion = 2;
    public static readonly IReadOnlyList<CommandDefinition> Commands = Load();
    private static CommandDefinition[] Load()
    {
        using var stream = typeof(Catalog).Assembly.GetManifestResourceStream("commands.json")!;
        using var reader = new StreamReader(stream);
        var commands = Json.Read<Document>(reader.ReadToEnd()).Commands;
        if (commands.Length != 91 || commands.Select(c => c.Id).Distinct().Count() != commands.Length) throw new InvalidDataException("Invalid command catalog.");
        return commands.Select(c => c with { ExecutionType = "WindowsProvider", Compatibility = c.Compatibility with { MinimumBuild = 14393, Capabilities = c.Compatibility.Capabilities.Where(s => !s.StartsWith("cmdlet:", StringComparison.OrdinalIgnoreCase)).ToArray() } }).ToArray();
    }
    public static CommandDefinition Get(string id) => Commands.SingleOrDefault(c => c.Id == id) ?? throw new ArgumentException("Unknown command: " + id);
    public static Dictionary<string, string> Validate(CommandDefinition command, IReadOnlyDictionary<string, string> input)
    {
        if (input.Keys.Any(k => command.Parameters.All(p => p.Name != k))) throw new ArgumentException("Unknown parameter.");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var p in command.Parameters)
        {
            input.TryGetValue(p.Name, out var value);
            if (string.IsNullOrWhiteSpace(value) && p.Default.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)) value = p.Default.ToString();
            if (string.IsNullOrWhiteSpace(value)) { if (p.Required) throw new ArgumentException("Required: " + p.Name); else continue; }
            value = value.Trim();
            switch (p.Type)
            {
                case "Integer": if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number) || number < p.Minimum || number > p.Maximum) throw new ArgumentException("Out of range: " + p.Name); break;
                case "Choice": value = p.AllowedValues?.FirstOrDefault(x => x.Equals(value, StringComparison.OrdinalIgnoreCase)) ?? throw new ArgumentException("Invalid choice: " + p.Name); break;
                case "Host": if (Uri.CheckHostName(value) == UriHostNameType.Unknown || value.Length > 253) throw new ArgumentException("Invalid host."); break;
                case "Sha256": if (!Regex.IsMatch(value, "\\A[0-9a-fA-F]{64}\\z")) throw new ArgumentException("Invalid SHA256."); break;
                case "DriveLetter": if (!Regex.IsMatch(value, "\\A[A-Za-z]\\z")) throw new ArgumentException("Invalid drive letter."); break;
                case "LocalFile": case "LocalDirectory": value = Paths.Local(value, p.Type == "LocalDirectory"); break;
                default: throw new InvalidDataException("Unknown parameter type.");
            }
            values[p.Name] = value;
        }
        if (command.Id == "power.countdown")
        {
            var scale = values["unit"] switch { "Seconds" => 1L, "Minutes" => 60, "Hours" => 3600, _ => 86400 };
            if (long.Parse(values["duration"]) * scale > 604800) throw new ArgumentException("Maximum countdown: seven days.");
        }
        return values;
    }
}

public static class Paths
{
    public static string Local(string path, bool directory)
    {
        var full = Path.GetFullPath(path);
        if (full.StartsWith("\\\\") || full.StartsWith("\\?")) throw new ArgumentException("A local path is required.");
        if (directory ? !Directory.Exists(full) : !File.Exists(full)) throw new FileNotFoundException("Path unavailable.", full);
        NoReparse(full);
        return full;
    }
    public static void NoReparse(string path)
    {
        for (var current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("Reparse paths are not allowed: " + current);
    }
    public static string Contained(string root, string path)
    {
        var full = Path.GetFullPath(path);
        if (!full.StartsWith(Path.GetFullPath(root).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) throw new IOException("Path escapes its root.");
        NoReparse(full); return full;
    }
    public static string WindowsExe(string name)
    {
        if (!new[] { "ipconfig.exe", "ping.exe", "tracert.exe", "arp.exe", "route.exe", "netstat.exe", "resmon.exe", "taskmgr.exe", "mmc.exe", "sfc.exe", "dism.exe", "chkdsk.exe", "netsh.exe", "cmd.exe", "shutdown.exe", "powercfg.exe", "nslookup.exe" }.Contains(name)) throw new ArgumentException("Unknown Windows executable.");
        var folder = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), folder, name);
    }
}

public static class Security
{
    public static bool IsAdmin { get { using var identity = WindowsIdentity.GetCurrent(); return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator); } }
    public static string Sid { get { using var identity = WindowsIdentity.GetCurrent(); return identity.User!.Value; } }
}

public static class NativeProcess
{
    public static async Task<int> Run(string exe, IEnumerable<string> arguments, Action<string> output, CancellationToken token, string? directory = null)
    {
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = directory ?? Environment.GetFolderPath(Environment.SpecialFolder.Windows) };
        foreach (var arg in arguments) start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new IOException("Process did not start.");
        async Task Drain(StreamReader reader) { var buffer = new char[2048]; int count; while ((count = await reader.ReadAsync(buffer)) > 0) output(new string(buffer, 0, count)); }
        var stdout = Drain(process.StandardOutput); var stderr = Drain(process.StandardError);
        try { await process.WaitForExitAsync(token); }
        catch (OperationCanceledException) { try { process.Kill(true); } catch (InvalidOperationException) { } await process.WaitForExitAsync(); throw; }
        finally { await Task.WhenAll(stdout, stderr); }
        return process.ExitCode;
    }
}
