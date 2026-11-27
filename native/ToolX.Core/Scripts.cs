using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ToolX;

public sealed record ScriptMetadata([property: JsonPropertyName("schemaVersion")] int SchemaVersion = 1, [property: JsonPropertyName("name")] string? Name = null, [property: JsonPropertyName("description")] string? Description = null, [property: JsonPropertyName("requiresAdmin")] bool RequiresAdmin = false, [property: JsonPropertyName("enabled")] bool Enabled = true);
public sealed record CustomScript(string Path, ScriptMetadata Metadata, string? UnavailableReason = null);
public sealed class ScriptImporter(string appRoot, HttpMessageHandler? networkHandler = null)
{
    public string Root { get; } = Path.Combine(Path.GetFullPath(appRoot), "Scripts");
    public static ScriptMetadata Metadata(string path)
    {
        if (!File.Exists(path)) return new();
        Paths.NoReparse(path);
        if (new FileInfo(path).Length > 65536) throw new InvalidDataException("Metadata exceeds 64 KiB.");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var allowed = new[] { "schemaVersion", "name", "description", "requiresAdmin", "enabled" };
        if (doc.RootElement.ValueKind != JsonValueKind.Object || doc.RootElement.EnumerateObject().Any(p => !allowed.Contains(p.Name)) || doc.RootElement.EnumerateObject().GroupBy(p => p.Name).Any(g => g.Count() != 1) || !doc.RootElement.TryGetProperty("schemaVersion", out var schema) || schema.GetInt32() != 1) throw new InvalidDataException("Invalid script metadata fields.");
        var data = Json.Read<ScriptMetadata>(doc.RootElement.GetRawText()); if (data.SchemaVersion != 1 || data.Name?.Length > 120 || data.Description?.Length > 4096) throw new InvalidDataException("Unsupported script metadata."); return data;
    }
    private static bool Entry(string path) => new[] { ".ps1", ".bat", ".cmd" }.Contains(Path.GetExtension(path).ToLowerInvariant());
    public List<CustomScript> Discover()
    {
        var scripts = new List<CustomScript>(); if (!Directory.Exists(Root)) return scripts; Paths.NoReparse(Root);
        var folders = new[] { Root }.Concat(Directory.EnumerateDirectories(Root).Where(p => !Path.GetFileName(p).StartsWith('_') && !File.GetAttributes(p).HasFlag(FileAttributes.ReparsePoint)));
        foreach (var folder in folders) foreach (var file in Directory.EnumerateFiles(folder).Where(Entry))
        {
            if (scripts.Count >= 500) return scripts;
            try { Paths.Contained(Root, file); if (new FileInfo(file).Length is < 1 or > 524288) throw new InvalidDataException("Script size must be 1 byte through 512 KiB."); var data = Metadata(file + ".json"); scripts.Add(new(file, data, data.Enabled ? null : "Disabled by metadata.")); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException) { scripts.Add(new(file, new(), e.Message)); }
        }
        return scripts;
    }
    private string Destination(string folder, string name)
    {
        if (folder != "" && !Regex.IsMatch(folder, "\\A[A-Za-z0-9][A-Za-z0-9_.-]*\\z")) throw new ArgumentException("Invalid destination folder.");
        if (!Regex.IsMatch(name, "\\A[A-Za-z0-9][A-Za-z0-9_.-]*\\z") || !Entry(name)) throw new ArgumentException("Invalid script filename.");
        return Paths.Contained(Root, Path.Combine(Root, folder, name));
    }
    public async Task Import(string source, string folder, string? expectedHash, bool overwrite, CancellationToken token)
    {
        var stage = Path.Combine(Path.GetTempPath(), "toolx-import-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(stage);
        try
        {
            var items = new List<(string Source, string Destination)>();
            var assets = new List<(string Source, string Destination)>();
            if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme == "https")
            {
                var bytes = await Download(uri, uri.AbsolutePath.EndsWith("manifest.json", StringComparison.OrdinalIgnoreCase) ? 262144 : 524288, token);
                if (uri.AbsolutePath.EndsWith("manifest.json", StringComparison.OrdinalIgnoreCase))
                {
                    using var doc = JsonDocument.Parse(bytes); var manifest = doc.RootElement;
                    if (manifest.GetProperty("schemaVersion").GetInt32() != 1 || manifest.GetProperty("scripts").GetArrayLength() is < 1 or > 100) throw new InvalidDataException("Invalid manifest.");
                    foreach (var item in manifest.GetProperty("scripts").EnumerateArray())
                    {
                        var hash = item.GetProperty("sha256").GetString()!; var url = new Uri(item.GetProperty("url").GetString()!); var content = await Download(url, 524288, token); CheckHash(content, hash, true);
                        var temp = Path.Combine(stage, Guid.NewGuid().ToString("N") + ".ps1"); await File.WriteAllBytesAsync(temp, content, token);
                        var target = Destination(item.GetProperty("folder").GetString() ?? "", item.GetProperty("fileName").GetString()!);
                        var metadata = new ScriptMetadata(Name: item.GetProperty("name").GetString(), Description: item.GetProperty("description").GetString(), RequiresAdmin: item.TryGetProperty("requiresAdmin", out var admin) && admin.GetBoolean());
                        await File.WriteAllTextAsync(temp + ".json", Json.Write(metadata), token); items.Add((temp, target));
                    }
                }
                else { CheckHash(bytes, expectedHash, false); var name = Path.GetFileName(Uri.UnescapeDataString(uri.AbsolutePath)); var temp = Path.Combine(stage, name); await File.WriteAllBytesAsync(temp, bytes, token); items.Add((temp, Destination(folder, name))); }
            }
            else
            {
                var local = Paths.Local(source, false);
                if (Path.GetExtension(local).Equals(".zip", StringComparison.OrdinalIgnoreCase))
                {
                    if (new FileInfo(local).Length > 6 * 1024 * 1024) throw new InvalidDataException("Archive too large.");
                    using var archive = ZipFile.OpenRead(local); long total = 0; var files = archive.Entries.Where(e => e.Name != "").ToArray();
                    if (files.Length > 100) throw new InvalidDataException("ZIP exceeds 100 files.");
                    foreach (var entry in files) { total = checked(total + entry.Length); if (total > 5 * 1024 * 1024) throw new InvalidDataException("ZIP exceeds 5 MiB uncompressed."); var relative = entry.FullName.Replace('/', '\\'); if (relative.Split('\\').Length > 3 || relative.Split('\\').Any(p => p is "." or ".." or "" || p.Contains(':')) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000) throw new InvalidDataException("Unsafe ZIP path."); var target = Paths.Contained(stage, Path.Combine(stage, relative)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); using var input = entry.Open(); using var output = File.Create(target); await input.CopyToAsync(output, token); }
                    foreach (var file in Directory.EnumerateFiles(stage, "*", SearchOption.AllDirectories))
                    {
                        var relative = Path.GetRelativePath(stage, file); var parts = relative.Split(Path.DirectorySeparatorChar);
                        if (parts.Any(p => !Regex.IsMatch(p, "\\A[A-Za-z0-9_][A-Za-z0-9_.-]*\\z"))) throw new InvalidDataException("Invalid ZIP filename.");
                        if (parts.Contains("_support")) { var destinationRelative = folder == "" ? relative : Path.Combine(folder, parts[0] == "_support" ? relative : Path.Combine(parts.Skip(1).ToArray())); assets.Add((file, Paths.Contained(Root, Path.Combine(Root, destinationRelative)))); continue; }
                        if (!Entry(file) || parts.Length > 2 || parts.Any(p => p.StartsWith('_'))) continue;
                        items.Add((file, Destination(folder == "" && parts.Length == 2 ? parts[0] : folder, Path.GetFileName(file))));
                    }
                }
                else { if (!Entry(local)) throw new ArgumentException("Supported: ps1, bat, cmd, zip."); CheckHash(await File.ReadAllBytesAsync(local, token), expectedHash, false); items.Add((local, Destination(folder, Path.GetFileName(local)))); }
            }
            if (items.Count == 0) throw new InvalidDataException("No script entries found.");
            if (items.Select(i => i.Destination).Distinct(StringComparer.OrdinalIgnoreCase).Count() != items.Count) throw new InvalidDataException("Duplicate import destination.");
            foreach (var item in items) { Paths.NoReparse(item.Source); if (new FileInfo(item.Source).Length is < 1 or > 524288) throw new InvalidDataException("Script exceeds size limits."); Metadata(item.Source + ".json"); if (!overwrite && (File.Exists(item.Destination) || File.Exists(item.Destination + ".json"))) throw new IOException("Destination exists: " + item.Destination); }
            foreach (var asset in assets) { Paths.NoReparse(asset.Source); if (!overwrite && File.Exists(asset.Destination)) throw new IOException("Destination exists: " + asset.Destination); }
            var writes = items.SelectMany(item => new[] { (Source: item.Source, Destination: item.Destination), (Source: item.Source + ".json", Destination: item.Destination + ".json") }).Concat(assets).ToArray();
            if (writes.Select(w => w.Destination).Distinct(StringComparer.OrdinalIgnoreCase).Count() != writes.Length) throw new InvalidDataException("Duplicate destination.");
            foreach (var write in writes) if (File.Exists(write.Destination) && new FileInfo(write.Destination).Length > 5 * 1024 * 1024) throw new InvalidDataException("Existing destination exceeds overwrite limits.");
            Directory.CreateDirectory(Root); Paths.NoReparse(Root);
            var backups = new List<(string Target, byte[]? Original)>();
            try
            {
                foreach (var item in writes)
                {
                    token.ThrowIfCancellationRequested(); var target = item.Destination; Paths.Contained(Root, target); Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    backups.Add((target, File.Exists(target) ? File.ReadAllBytes(target) : null));
                    if (File.Exists(item.Source)) { var temporary = Path.Combine(Path.GetDirectoryName(target)!, ".toolx-" + Guid.NewGuid().ToString("N")); try { File.Copy(item.Source, temporary); File.Move(temporary, target, true); } finally { if (File.Exists(temporary)) File.Delete(temporary); } } else if (File.Exists(target)) File.Delete(target);
                }
            }
            catch { foreach (var backup in backups.AsEnumerable().Reverse()) { if (backup.Original != null) File.WriteAllBytes(backup.Target, backup.Original); else if (File.Exists(backup.Target)) File.Delete(backup.Target); } throw; }
        }
        finally { Paths.NoReparse(stage); Directory.Delete(stage, true); }
    }
    private static void CheckHash(byte[] bytes, string? expected, bool required) { if (string.IsNullOrEmpty(expected)) { if (required) throw new InvalidDataException("SHA256 required."); return; } if (!Regex.IsMatch(expected, "\\A[0-9a-fA-F]{64}\\z") || !Convert.ToHexString(SHA256.HashData(bytes)).Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("SHA256 mismatch."); }
    private async Task<byte[]> Download(Uri uri, int limit, CancellationToken token)
    {
        using var client = networkHandler == null ? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) : new HttpClient(networkHandler, false); client.Timeout = TimeSpan.FromSeconds(30);
        for (var redirect = 0; redirect < 6; redirect++)
        {
            if (uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo)) throw new ArgumentException("HTTPS URLs without credentials are required.");
            using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token);
            if ((int)response.StatusCode is >= 300 and < 400) { uri = new Uri(uri, response.Headers.Location ?? throw new IOException("Redirect missing location.")); continue; }
            response.EnsureSuccessStatusCode(); if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("Download too large.");
            await using var stream = await response.Content.ReadAsStreamAsync(token); using var output = new MemoryStream(); var buffer = new byte[8192]; int count;
            while ((count = await stream.ReadAsync(buffer, token)) > 0) { if (output.Length + count > limit) throw new InvalidDataException("Download too large."); output.Write(buffer, 0, count); }
            return output.ToArray();
        }
        throw new IOException("Too many redirects.");
    }
    public async Task<int> Run(CustomScript entry, bool confirmed, CancellationToken token = default)
    {
        if (!confirmed) throw new InvalidOperationException("Custom scripts require explicit confirmation.");
        var script = Discover().SingleOrDefault(s => s.Path.Equals(entry.Path, StringComparison.OrdinalIgnoreCase)) ?? throw new IOException("Script disappeared.");
        if (script.UnavailableReason != null) throw new InvalidOperationException(script.UnavailableReason);
        var needsAdmin = script.Metadata.RequiresAdmin && !Security.IsAdmin;
        if (needsAdmin || !string.Equals(Path.GetFileName(Environment.ProcessPath), "Toolkit.CLI.exe", StringComparison.OrdinalIgnoreCase))
        {
            var elevated = new ProcessStartInfo(Path.Combine(Path.GetDirectoryName(Root)!, "Toolkit.CLI.exe")) { UseShellExecute = true, Verb = needsAdmin ? "runas" : "", WorkingDirectory = Path.GetDirectoryName(script.Path)! };
            elevated.ArgumentList.Add("-RunScript"); elevated.ArgumentList.Add(Path.GetRelativePath(Root, script.Path)); elevated.ArgumentList.Add("-ScriptConfirmed");
            using var child = Process.Start(elevated) ?? throw new IOException("Script console did not start."); await child.WaitForExitAsync(token); return child.ExitCode;
        }
        var powershell = Path.GetExtension(script.Path).Equals(".ps1", StringComparison.OrdinalIgnoreCase);
        var exe = powershell ? Path.Combine(Path.GetDirectoryName(Paths.WindowsExe("cmd.exe"))!, @"WindowsPowerShell\v1.0\powershell.exe") : Paths.WindowsExe("cmd.exe");
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(script.Path)! };
        if (powershell) { foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-File", script.Path }) start.ArgumentList.Add(arg); }
        else { start.Environment["TOOLX_SCRIPT"] = script.Path; start.Arguments = "/d /v:off /s /c \"\"%TOOLX_SCRIPT%\"\""; }
        using var process = Process.Start(start) ?? throw new IOException("Interpreter did not start."); await process.WaitForExitAsync(token);
        if (powershell && process.ExitCode != 0) throw new IOException("PowerShell exited with code " + process.ExitCode + ". Script policy or the script itself may have failed. TOOLX did not change execution policy."); return process.ExitCode;
    }
    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";
}
