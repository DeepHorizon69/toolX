using System.Diagnostics;
using System.Globalization;
using ToolX;

internal static class Program
{
    private static string language = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "id" ? "id" : "en";
    private static readonly Engine Engine = new(AppContext.BaseDirectory);
    private static readonly ScriptImporter Scripts = new(AppContext.BaseDirectory);
    private static bool confirmations = true;
    private static string T(string key) => L10n.T(key, language);
    private static async Task<int> Main(string[] args)
    {
        using var cancel = new CancellationTokenSource(); Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancel.Cancel(); };
        try
        {
            CliArguments.Validate(args);
            string? Option(string name) { var index = Array.FindIndex(args, a => a.Equals(name, StringComparison.OrdinalIgnoreCase)); if (index < 0) return null; if (index + 1 == args.Length) throw new ArgumentException("Missing value: " + name); return args[index + 1]; }
            bool Has(string name) => args.Contains(name, StringComparer.OrdinalIgnoreCase);
            var suppliedLanguage = Option("-Language"); if (suppliedLanguage != null) language = suppliedLanguage is "id" or "en" ? suppliedLanguage : throw new ArgumentException("Language: id or en.");
            if (Has("-Version")) { Console.WriteLine("TOOLX Windows Edition Alpha 0.2.3 | by ALSA | C#/.NET"); return 0; }
            if (Has("-Help") || Has("--help") || Has("-h")) { Console.WriteLine("Toolkit.CLI.exe [-Basic | -ListCommands | -Check | -Version | -Gui]\n-Run <command-id> [-Param name=value]...\n-RunCheck <general|network> [-Target host] [-Extra id,id] [-Export path] [-Format json|html]\n-Compare <before.json> <after.json> [-Export path]\n-ImportLocal <path> | -ImportUrl <https-url> [-ImportFolder name] [-ImportSha256 hash] [-ImportOverwrite]\n-Language <id|en>\nModifying operations prompt interactively; CLI has no unattended confirmation switch."); return 0; }
            if (Has("-Gui")) { Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Toolkit.exe")) { UseShellExecute = true }); return 0; }
            if (Option("-RunScript") is { } scriptPath)
            {
                if (Console.IsInputRedirected) throw new InvalidOperationException("Custom scripts require an interactive console.");
                var full = Paths.Contained(Scripts.Root, Path.Combine(Scripts.Root, scriptPath));
                var script = Scripts.Discover().Single(s => s.Path.Equals(full, StringComparison.OrdinalIgnoreCase));
                Console.WriteLine(full + "\nCustom scripts run with this console's Windows permissions. They are not sandboxed.");
                if (!Has("-ScriptConfirmed")) { Console.Write("yes: "); if (Console.ReadLine() != "yes") return 130; }
                int code;
                try { code = await Scripts.Run(script, true, cancel.Token); }
                catch (Exception e) { Console.Error.WriteLine(e.Message); code = 1; }
                Console.WriteLine("Exit code: " + code + "\nPress Enter to close."); Console.ReadLine(); return code;
            }
            if (Has("-ListCommands")) { foreach (var c in Catalog.Commands) Console.WriteLine($"{c.Id,-36} {c.Risk,-18} {L10n.CommandName(c, language)}"); return 0; }
            if (Has("-Check")) { Console.WriteLine(Json.Write(new { Version = "0.2.3", Runtime = Environment.Version.ToString(), Windows = Environment.OSVersion.VersionString, Compatible = Environment.OSVersion.Version.Build >= 14393, BuiltIns = Catalog.Commands.Count, MissingHandlers = Catalog.Commands.Where(c => !WindowsProviders.HasHandler(c.Id)).Select(c => c.Id), CoreUsesPowerShell = false, Administrator = Security.IsAdmin })); return 0; }
            var local = Option("-ImportLocal"); var url = Option("-ImportUrl");
            if (local != null || url != null) { await Scripts.Import(local ?? url!, Option("-ImportFolder") ?? "", Option("-ImportSha256"), Has("-ImportOverwrite"), cancel.Token); Console.WriteLine("Import completed."); return 0; }
            if (Option("-Compare") is { } before) { var i = Array.FindIndex(args, a => a.Equals("-Compare", StringComparison.OrdinalIgnoreCase)); if (i + 2 >= args.Length) throw new ArgumentException("Two report paths are required."); var text = Json.Write(Reports.Compare(Reports.Load(before), Reports.Load(args[i + 2]))); if (Option("-Export") is { } target) { Paths.NoReparse(Path.GetFullPath(target)); File.WriteAllText(target, text); } else Console.WriteLine(text); return 0; }
            if (Option("-RunCheck") is { } check) { var report = await Reports.Run(Engine, check, Option("-Target"), Option("-Extra")?.Split(','), language, cancel.Token, new Progress<OperationProgress>(p => Console.Error.WriteLine(p.CommandId))); if (Option("-Export") is { } path) Reports.Export(report, path, Option("-Format") ?? "json"); else Console.WriteLine(Json.Write(report)); return report.Results.All(r => r.Status == OperationStatus.Succeeded) ? 0 : 1; }
            if (Option("-Run") is { } id)
            {
                var parameters = new Dictionary<string, string>(); for (var i = 0; i < args.Length; i++) if (args[i].Equals("-Param", StringComparison.OrdinalIgnoreCase)) { if (++i >= args.Length || !args[i].Contains('=')) throw new ArgumentException("Use -Param name=value."); var pair = args[i].Split('=', 2); parameters.Add(pair[0], pair[1]); }
                var result = await Run(Catalog.Get(id), parameters, cancel.Token); Print(result); return result.Status == OperationStatus.Succeeded ? 0 : 1;
            }
            var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "-Basic", "-Language", "id", "en" }; if (args.Any(a => !known.Contains(a))) throw new ArgumentException("Unsupported argument. Use -Help.");
            await Menu(cancel.Token); return 0;
        }
        catch (OperationCanceledException) { Console.Error.WriteLine(T("Cancelled")); return 130; }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }
    private static void Print(OperationResult result) { Console.WriteLine($"{result.CommandId}: {L10n.Status(result.Status, language)} ({result.DurationMs} ms)"); foreach (var row in result.Rows) { foreach (var field in row.Where(p => p.Key != "_key")) Console.WriteLine(field.Key + ": " + field.Value); Console.WriteLine(); } if (result.Detail != "") Console.WriteLine(result.Detail); }
    private static async Task<OperationResult> Run(CommandDefinition command, Dictionary<string, string>? values, CancellationToken token)
    {
        Console.WriteLine(L10n.CommandName(command, language) + " [" + T(command.Risk) + "]"); Console.WriteLine(L10n.Consequence(command, language));
        values ??= [];
        foreach (var p in command.Parameters.Where(p => !values.ContainsKey(p.Name))) { Console.Write(p.Name + (p.AllowedValues?.Length > 0 ? " [" + string.Join('/', p.AllowedValues) + "]" : "") + " (" + p.Default + "): "); var input = Console.ReadLine(); if (!string.IsNullOrWhiteSpace(input)) values[p.Name] = input; }
        CleanupItem[]? preview = null; if (command.Id == "repair.temp") { preview = Cleanup.Preview(); Console.WriteLine(Json.Write(preview)); }
        var needed = !command.ReadOnly || command.RequiresAdmin;
        if (needed && Console.IsInputRedirected) throw new InvalidOperationException("An interactive console is required for this operation.");
        if (needed && confirmations) { Console.Write(command.Risk == "HighRisk" ? T("Type command ID to confirm") + ": " : T("Confirmation") + " (yes): "); var input = Console.ReadLine(); if (input != (command.Risk == "HighRisk" ? command.Id : "yes")) throw new OperationCanceledException(); }
        return await Engine.Run(new(command.Id, values, true, command.Id, preview), token);
    }
    private static async Task Menu(CancellationToken token)
    {
        var filtered = Catalog.Commands.ToList();
        while (!token.IsCancellationRequested)
        {
            Console.WriteLine("\nTOOLX 0.2.3 | by ALSA | " + T(confirmations ? "Confirmations are ON" : "Confirmations are OFF"));
            for (var i = 0; i < filtered.Count; i++) Console.WriteLine($"{i + 1,3}. {L10n.CommandName(filtered[i], language)} [{T(filtered[i].Risk)}]");
            Console.WriteLine("/search | checks | scripts | import | settings | language | gui | q"); Console.Write("> "); var input = Console.ReadLine(); if (input == null || input == "q") return;
            try
            {
                if (input.StartsWith('/')) { var search = input[1..]; filtered = Catalog.Commands.Where(c => (L10n.CommandName(c, language) + c.Id + c.Category + string.Join(' ', c.Keywords)).Contains(search, StringComparison.OrdinalIgnoreCase)).ToList(); }
                else if (input == "language") language = language == "id" ? "en" : "id";
                else if (input == "settings") { if (confirmations) { Console.WriteLine(T("Type OFF to disable confirmations for this session. Actions may delete files, change security settings, or restart Windows.")); confirmations = Console.ReadLine() != "OFF"; } else confirmations = true; }
                else if (input == "gui") Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Toolkit.exe")) { UseShellExecute = true });
                else if (input == "import") { Console.Write("File / HTTPS URL: "); var path = Console.ReadLine() ?? ""; Console.Write(T("Destination folder") + ": "); await Scripts.Import(path, Console.ReadLine() ?? "", null, false, token); }
                else if (input == "checks") { Console.Write("general / network: "); var check = Console.ReadLine() ?? "general"; string? host = null; if (check == "network") { Console.Write(T("Target host") + ": "); host = Console.ReadLine(); } var report = await Reports.Run(Engine, check, host, null, language, token); foreach (var result in report.Results) Print(result); Console.Write(T("Export JSON") + " (path / Enter): "); var export = Console.ReadLine(); if (!string.IsNullOrWhiteSpace(export)) Reports.Export(report, export, "json"); }
                else if (input == "scripts") { var scripts = Scripts.Discover(); for (var i = 0; i < scripts.Count; i++) Console.WriteLine($"{i + 1}. {scripts[i].Metadata.Name ?? Path.GetFileName(scripts[i].Path)} {scripts[i].UnavailableReason}"); Console.Write("> "); if (int.TryParse(Console.ReadLine(), out var index) && index > 0 && index <= scripts.Count) { Console.WriteLine("Custom scripts run with Windows permissions and may inherit administrator privileges. They are not sandboxed."); Console.Write("yes: "); if (!confirmations || Console.ReadLine() == "yes") Console.WriteLine("Exit code: " + await Scripts.Run(scripts[index - 1], true, token)); } }
                else if (int.TryParse(input, out var choice) && choice > 0 && choice <= filtered.Count) Print(await Run(filtered[choice - 1], null, token));
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { Console.WriteLine(T("Cancelled")); }
            catch (Exception e) { Console.Error.WriteLine(e.Message); }
        }
    }
}
