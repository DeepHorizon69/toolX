using ToolX;
using System.IO.Compression;
using System.Security.Cryptography;

internal static class Program
{
    private static int passed, failed;
    private static void Check(string name, Action action) { try { action(); passed++; Console.WriteLine("PASS " + name); } catch (Exception e) { failed++; Console.Error.WriteLine("FAIL " + name + ": " + e.Message); } }
    private static void Assert(bool value, string message = "Assertion failed") { if (!value) throw new Exception(message); }
    private static void Throws(Action action) { try { action(); } catch { return; } throw new Exception("Expected rejection."); }
    private static async Task<int> Main(string[] args)
    {
        var sandbox = Path.Combine(Path.GetTempPath(), "toolx-tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(sandbox);
        try
        {
            Check("91 unique commands and native handlers", () => { Assert(Catalog.Commands.Count == 91); Assert(Catalog.Commands.All(c => WindowsProviders.HasHandler(c.Id))); Assert(Catalog.Commands.Select(c => c.Id).Distinct().Count() == 91); });
            Check("all command names translated", () => { Assert(Catalog.Commands.All(c => L10n.CommandName(c, "id").Length > 0)); Assert(L10n.CommandName(Catalog.Get("repair.tcpip-reset"), "id") == "Reset stack TCP/IP"); });
            Check("host injection rejected", () => Throws(() => Catalog.Validate(Catalog.Get("network.ping"), new Dictionary<string, string> { ["host"] = "example.com & calc.exe" })));
            Check("invalid choice rejected", () => Throws(() => Catalog.Validate(Catalog.Get("network.dns"), new Dictionary<string, string> { ["host"] = "example.com", ["recordType"] = "A;whoami" })));
            Check("unknown parameter rejected", () => Throws(() => Catalog.Validate(Catalog.Get("system.os"), new Dictionary<string, string> { ["script"] = "anything" })));
            Check("required host rejected", () => Throws(() => Catalog.Validate(Catalog.Get("network.ping"), new Dictionary<string, string>())));
            Check("port bounds", () => Throws(() => Catalog.Validate(Catalog.Get("network.port"), new Dictionary<string, string> { ["host"] = "localhost", ["port"] = "65536" })));
            Check("choice normalized", () => Assert(Catalog.Validate(Catalog.Get("system.full-specs"), new Dictionary<string, string> { ["scope"] = "hardware" })["scope"] == "Hardware"));
            Check("countdown total bounded", () => Throws(() => Catalog.Validate(Catalog.Get("power.countdown"), new Dictionary<string, string> { ["duration"] = "8", ["unit"] = "Days" })));
            Check("unapproved executable rejected", () => Throws(() => Paths.WindowsExe("powershell.exe")));
            Check("path escape rejected", () => Throws(() => Paths.Contained(sandbox, Path.Combine(sandbox, "..", "outside.ps1"))));
            Check("UNC paths rejected", () => Throws(() => Paths.Local(@"\\server\share\file.ps1", false)));
            var engine = new Engine(sandbox);
            Check("high risk requires explicit confirmation", () => { var r = engine.Run(new("power.force-restart", [], true)).GetAwaiter().GetResult(); Assert(r.Status == OperationStatus.Failed && r.Detail.Contains("command ID")); });
            Check("modification without confirmation rejected", () => Assert(engine.Run(new("repair.sfc", [])).GetAwaiter().GetResult().Status == OperationStatus.Failed));
            Check("pre-cancelled query returns Cancelled", () => { using var cancel = new CancellationTokenSource(); cancel.Cancel(); Assert(engine.Run(new("system.environment", []), cancel.Token).GetAwaiter().GetResult().Status == OperationStatus.Cancelled); });
            var source = Path.Combine(sandbox, "sources"); Directory.CreateDirectory(source); var script = Path.Combine(source, "Check.ps1"); File.WriteAllText(script, "Write-Output 'fixture, do not run'");
            var importer = new ScriptImporter(Path.Combine(sandbox, "portable"));
            Check("local import does not execute and preserves bytes", () => { importer.Import(script, "IT-Support", null, false, default).GetAwaiter().GetResult(); Assert(File.ReadAllText(Path.Combine(importer.Root, "IT-Support", "Check.ps1")) == File.ReadAllText(script)); });
            Check("discovery finds imported script", () => Assert(importer.Discover().Count == 1));
            Check("existing destination not overwritten implicitly", () => Throws(() => importer.Import(script, "IT-Support", null, false, default).GetAwaiter().GetResult()));
            File.WriteAllText(script + ".json", "{\"schemaVersion\":1,\"enabled\":false,\"requiresAdmin\":true}");
            Check("metadata preserved", () => { importer.Import(script, "IT-Support", null, true, default).GetAwaiter().GetResult(); var found = importer.Discover().Single(); Assert(found.Metadata.RequiresAdmin && !found.Metadata.Enabled && found.UnavailableReason != null); });
            var original = File.ReadAllText(Path.Combine(importer.Root, "IT-Support", "Check.ps1"));
            File.WriteAllText(script, "changed"); File.WriteAllText(script + ".json", "{broken");
            Check("failed overwrite preserves original and metadata", () => { Throws(() => importer.Import(script, "IT-Support", null, true, default).GetAwaiter().GetResult()); Assert(File.ReadAllText(Path.Combine(importer.Root, "IT-Support", "Check.ps1")) == original); Assert(!importer.Discover().Single().Metadata.Enabled); });
            File.WriteAllText(script + ".json", new string('x', 65537));
            Check("oversized metadata rejected", () => Throws(() => importer.Import(script, "IT-Support", null, true, default).GetAwaiter().GetResult()));
            File.Delete(script + ".json");
            Check("generated metadata preserves public schema-v1 casing", () => { var path = Path.Combine(source, "generated.json"); File.WriteAllText(path, Json.Write(new ScriptMetadata(Name: "Generated", RequiresAdmin: true, Enabled: false))); var metadata = ScriptImporter.Metadata(path); Assert(metadata.Name == "Generated" && metadata.RequiresAdmin && !metadata.Enabled); });
            var remoteBytes = System.Text.Encoding.UTF8.GetBytes("# downloaded fixture, never executed");
            var manifest = Json.Write(new { schemaVersion = 1, publisher = "fixture", scripts = new[] { new { name = "Remote fixture", description = "fixture only", folder = "Remote", fileName = "Remote.ps1", url = "https://fixture.example/Remote.ps1", sha256 = Convert.ToHexString(SHA256.HashData(remoteBytes)), requiresAdmin = true } } });
            using var handler = new FixtureHttpHandler(request => new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(request.RequestUri!.AbsolutePath.EndsWith("manifest.json") ? System.Text.Encoding.UTF8.GetBytes(manifest) : remoteBytes) });
            var remoteImporter = new ScriptImporter(Path.Combine(sandbox, "remote"), handler);
            Check("HTTPS manifest import preserves hash and metadata", () => { remoteImporter.Import("https://fixture.example/manifest.json", "", null, false, default).GetAwaiter().GetResult(); var found = remoteImporter.Discover().Single(); Assert(found.Metadata.Name == "Remote fixture" && found.Metadata.RequiresAdmin); Assert(File.ReadAllBytes(found.Path).SequenceEqual(remoteBytes)); });
            using var redirectHandler = new FixtureHttpHandler(_ => { var response = new HttpResponseMessage(System.Net.HttpStatusCode.Redirect); response.Headers.Location = new Uri("http://fixture.example/unsafe.ps1"); return response; });
            Check("HTTPS redirect downgrade rejected", () => Throws(() => new ScriptImporter(Path.Combine(sandbox, "redirect"), redirectHandler).Import("https://fixture.example/Check.ps1", "", null, false, default).GetAwaiter().GetResult()));
            using var oversizedHandler = new FixtureHttpHandler(_ => new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[524289]) });
            Check("oversized HTTPS response rejected", () => Throws(() => new ScriptImporter(Path.Combine(sandbox, "oversized"), oversizedHandler).Import("https://fixture.example/Check.ps1", "", null, false, default).GetAwaiter().GetResult()));
            Check("incorrect SHA256 rejected", () => Throws(() => importer.Import(script, "Other", new string('0', 64), false, default).GetAwaiter().GetResult()));
            var zip = Path.Combine(source, "bad.zip"); using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create)) { using var writer = new StreamWriter(archive.CreateEntry("../escape.ps1").Open()); writer.Write("do not run"); }
            Check("ZIP traversal rejected", () => Throws(() => importer.Import(zip, "", null, false, default).GetAwaiter().GetResult()));
            var pack = Path.Combine(source, "support.zip"); using (var archive = ZipFile.Open(pack, ZipArchiveMode.Create)) { foreach (var (name, data) in new[] { ("Network/Fixture.ps1", "# fixture"), ("Network/_support/settings.txt", "preserve me"), ("Network/_support/Helper.ps1", "# helper, not an entrypoint") }) { using var writer = new StreamWriter(archive.CreateEntry(name).Open()); writer.Write(data); } }
            Check("ZIP support files preserved without helper discovery", () => { importer.Import(pack, "", null, false, default).GetAwaiter().GetResult(); Assert(File.ReadAllText(Path.Combine(importer.Root, "Network", "_support", "settings.txt")) == "preserve me"); Assert(importer.Discover().Count == 2); });
            var transaction = Path.Combine(source, "transaction.zip"); using (var archive = ZipFile.Open(transaction, ZipArchiveMode.Create)) { foreach (var name in new[] { "First.ps1", "Second.ps1" }) { using var writer = new StreamWriter(archive.CreateEntry(name).Open()); writer.Write("# replacement"); } }
            Directory.CreateDirectory(Path.Combine(importer.Root, "Atomic")); File.WriteAllText(Path.Combine(importer.Root, "Atomic", "First.ps1"), "# original"); Directory.CreateDirectory(Path.Combine(importer.Root, "Atomic", "Second.ps1"));
            Check("pack failure rolls back previous files", () => { Throws(() => importer.Import(transaction, "Atomic", null, true, default).GetAwaiter().GetResult()); Assert(File.ReadAllText(Path.Combine(importer.Root, "Atomic", "First.ps1")) == "# original"); });
            Check("script execution requires confirmation", () => Throws(() => importer.Run(importer.Discover().First(), false).GetAwaiter().GetResult()));
            var left = new SupportReport { Machine = "fixture", Results = [new() { CommandId = "system.environment", Rows = [new() { ["_key"] = "environment", ["Value"] = "<script>alert('x')</script>", ["TimeCreated"] = "earlier" }] }] };
            var right = Json.Read<SupportReport>(Json.Write(left)); right.CreatedUtc = DateTimeOffset.UtcNow.AddHours(1); right.Results[0].Rows[0]["TimeCreated"] = "later";
            Check("report comparison ignores capture timestamps", () => Assert(Reports.Compare(left, right).Count == 0));
            right.Results[0].Rows[0]["Value"] = "changed";
            Check("report comparison identifies changed field", () => Assert(Reports.Compare(left, right).Single().Field == "Value"));
            right.Results[0].Rows.Add(new() { ["_key"] = "new", ["Value"] = "added" });
            Check("report comparison identifies additions", () => Assert(Reports.Compare(left, right).Any(d => d.Change == "Added")));
            right.Machine = "another";
            Check("cross-machine comparison rejected", () => Throws(() => Reports.Compare(left, right)));
            Check("HTML escapes provider data", () => { var html = Reports.Html(left); Assert(!html.Contains("<script>")); Assert(html.Contains("&lt;script&gt;")); Assert(!html.Contains("http://") && !html.Contains("https://")); });
            Check("JSON round trip", () => { var path = Path.Combine(sandbox, "report.json"); Reports.Export(left, path, "json"); Assert(Reports.Load(path).Machine == "fixture"); });
            Check("unsupported report schema rejected", () => { var path = Path.Combine(sandbox, "future.json"); File.WriteAllText(path, "{\"schemaVersion\":9,\"results\":[]}"); Throws(() => Reports.Load(path)); });
            Check("unknown managed job kind rejected", () => Throws(() => ManagedChanges.Validate(new() { Kind = "Anything", Helper = "x" })));
            Check("invalid managed job ID rejected", () => Throws(() => ManagedChanges.Validate(new() { Id = "../escape", Kind = "Power", Helper = "x" })));
            Check("managed helper cannot escape protected versions", () => Throws(() => ManagedChanges.Validate(new() { Kind = "Probe", Scope = "Local", Helper = Path.Combine(sandbox, "Toolkit.Worker.exe") })));
            Check("valid managed probe contract", () => ManagedChanges.Validate(new() { Kind = "Probe", Scope = "Local", Helper = Path.Combine(ManagedChanges.Root, "versions", "fixture", "Toolkit.Worker.exe") }));
            Check("firewall snapshot requires all selected profiles", () => Throws(() => ManagedChanges.Validate(new() { Kind = "Firewall", Scope = "All", Helper = Path.Combine(ManagedChanges.Root, "versions", "fixture", "Toolkit.Worker.exe"), Original = new() { ["Private"] = "1" }, Applied = new() { ["Private"] = "2" } })));
            Check("wire input is bounded", () => { using var reader = new StreamReader(new MemoryStream(System.Text.Encoding.UTF8.GetBytes("12345\n"))); Throws(() => Wire.Read(reader, default, 4).GetAwaiter().GetResult()); });
            Check("CLI rejects unknown arguments", () => Throws(() => CliArguments.Validate(["-Version", "-Ignored"])));
            Check("CLI rejects conflicting modes", () => Throws(() => CliArguments.Validate(["-Run", "system.os", "-Gui"])));
            Check("CLI accepts repeated parameters and paths with spaces", () => CliArguments.Validate(["-Run", "storage.hash", "-Param", "path=C:\\My Files\\sample.zip", "-Param", "expected=" + new string('0', 64)]));
            var mixed = new Dictionary<string, string> { ["Domain"] = "0", ["Private"] = "1", ["Public"] = "2" }; var applied = mixed.Keys.ToDictionary(k => k, _ => "2");
            Check("recovery handles original mixed firewall state", () => Assert(RecoveryPolicy.Restoration(mixed, applied, mixed) == RestorationDecision.AlreadyOriginal));
            Check("recovery handles fully applied state", () => Assert(RecoveryPolicy.Restoration(mixed, applied, applied) == RestorationDecision.RestoreOwnedChange));
            var partial = new Dictionary<string, string>(mixed) { ["Private"] = "2" };
            Check("recovery handles interrupted partial application", () => Assert(RecoveryPolicy.Restoration(mixed, applied, partial) == RestorationDecision.RestoreOwnedChange));
            var conflict = new Dictionary<string, string>(mixed) { ["Domain"] = "1" };
            Check("recovery preserves external changes", () => Assert(RecoveryPolicy.Restoration(mixed, applied, conflict) == RestorationDecision.Conflict));
            Check("recovery rejects missing snapshot fields", () => Assert(RecoveryPolicy.Restoration(mixed, applied, new Dictionary<string, string>()) == RestorationDecision.Conflict));
            var now = DateTimeOffset.UtcNow; var power = new ManagedJob { Kind = "Power", ExpiresUtc = now, Status = "Active", BootId = "boot1" };
            Check("power action is due once within grace", () => Assert(RecoveryPolicy.Power(power, now.AddSeconds(1), "boot1") == PowerDecision.Execute));
            Check("power action expires when late", () => Assert(RecoveryPolicy.Power(power, now.AddSeconds(61), "boot1") == PowerDecision.Expire));
            Check("power action expires after reboot", () => Assert(RecoveryPolicy.Power(power, now, "boot2") == PowerDecision.Expire));
            Check("future power deadline waits", () => Assert(RecoveryPolicy.Power(power, now.AddSeconds(-1), "boot1") == PowerDecision.Wait));
            power.Status = "Executed"; Check("executed power action never replays", () => Assert(RecoveryPolicy.Power(power, now, "boot1") == PowerDecision.Wait));
            power.Status = "Prepared"; Check("interrupted preparation never issues power action", () => Assert(RecoveryPolicy.Power(power, now, "boot1") == PowerDecision.Expire));
            if (args.Contains("--live"))
            {
                foreach (var id in new[] { "system.environment", "system.locale", "system.os", "system.computer", "storage.space", "network.adapters", "processes.list", "security.certificates" })
                {
                    var result = await engine.Run(new(id, [])); Check("live " + id, () => { Assert(result.Status is OperationStatus.Succeeded or OperationStatus.Partial, result.Detail); Assert(id == "security.certificates" || result.Rows.Count > 0); });
                }
            }
            if (args.Contains("--diagnostics"))
            {
                foreach (var command in Catalog.Commands.Where(c => c.ReadOnly && !c.RequiresAdmin && c.NetworkAccess == "None" && c.Cost != "Heavy" && c.Parameters.All(p => !p.Required || p.Default.ValueKind is not (System.Text.Json.JsonValueKind.Null or System.Text.Json.JsonValueKind.Undefined))))
                {
                    var result = await engine.Run(new(command.Id, [])); Check("diagnostic " + command.Id, () => Assert(result.Status is OperationStatus.Succeeded or OperationStatus.Partial or OperationStatus.Unavailable or OperationStatus.PermissionDenied, result.Detail));
                }
            }
        }
        finally { Paths.NoReparse(sandbox); Directory.Delete(sandbox, true); }
        Console.WriteLine($"{passed} passed; {failed} failed."); return failed == 0 ? 0 : 1;
    }
    private sealed class FixtureHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(response(request));
    }
}
