using System.Diagnostics;
using System.Management;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;

namespace ToolX;

public static class TaskSchedulerApi
{
    internal static dynamic Connect() { dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")!)!; scheduler.Connect(); return scheduler; }
    public static List<Dictionary<string, string>> List()
    {
        dynamic scheduler = Connect(); var rows = new List<Dictionary<string, string>>();
        void Visit(dynamic folder) { foreach (dynamic task in folder.GetTasks(1)) { string path = task.Path; if (path.StartsWith("\\Microsoft\\Windows\\", StringComparison.OrdinalIgnoreCase)) continue; rows.Add(new() { ["_key"] = path, ["TaskPath"] = path, ["State"] = task.State.ToString(), ["LastTaskResult"] = task.LastTaskResult.ToString() }); if (rows.Count >= 200) return; } foreach (dynamic child in folder.GetFolders(0)) { if (rows.Count >= 200) return; Visit(child); } }
        Visit(scheduler.GetFolder("\\")); return rows;
    }
    private static dynamic Folder()
    {
        dynamic scheduler = Connect(); dynamic parent = scheduler.GetFolder("\\");
        try { return scheduler.GetFolder("\\ToolXNative"); } catch (System.Runtime.InteropServices.COMException) { return parent.CreateFolder("ToolXNative", "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)"); }
    }
    public static void Register(ManagedJob job, bool probe = false)
    {
        dynamic scheduler = Connect(); dynamic definition = scheduler.NewTask(0);
        definition.RegistrationInfo.Description = "TOOLX native recovery " + job.Id;
        definition.Principal.UserId = job.OwnerSid; definition.Principal.LogonType = 2; definition.Principal.RunLevel = 1;
        definition.Settings.Enabled = true; definition.Settings.AllowDemandStart = true; definition.Settings.DisallowStartIfOnBatteries = false; definition.Settings.StopIfGoingOnBatteries = false; definition.Settings.WakeToRun = false; definition.Settings.ExecutionTimeLimit = "PT5M"; definition.Settings.StartWhenAvailable = job.Kind != "Power";
        dynamic action = definition.Actions.Create(0); action.Path = job.Helper; action.Arguments = "--job " + job.Id + " --mode " + (probe ? "Probe" : "Execute"); action.WorkingDirectory = Path.GetDirectoryName(job.Helper);
        if (!probe && job.ExpiresUtc.HasValue) { dynamic trigger = definition.Triggers.Create(1); trigger.StartBoundary = job.ExpiresUtc.Value.ToLocalTime().ToString("yyyy-MM-ddTHH:mm:sszzz"); if (job.Kind != "Power") definition.Triggers.Create(8); }
        Folder().RegisterTaskDefinition("TX-" + job.Id, definition, 6, job.OwnerSid, null, 2, "D:P(A;;FA;;;SY)(A;;FA;;;BA)");
    }
    public static void Start(string id) { dynamic task = Folder().GetTask("TX-" + id); task.Run(null); }
    public static void Remove(string id) { try { Folder().DeleteTask("TX-" + id, 0); } catch (System.Runtime.InteropServices.COMException) { } }
    public static (string State, int? Result) Status(string id) { try { dynamic scheduler = Connect(); dynamic task = scheduler.GetFolder("\\ToolXNative").GetTask("TX-" + id); return (task.State.ToString(), (int)task.LastTaskResult); } catch (System.Runtime.InteropServices.COMException) { return ("Unavailable", null); } }
}

public sealed class ManagedJob
{
    public int SchemaVersion { get; set; } = 2;
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Kind { get; set; } = "";
    public string Scope { get; set; } = "";
    public Dictionary<string, string> Original { get; set; } = [];
    public Dictionary<string, string> Applied { get; set; } = [];
    public string OwnerSid { get; set; } = Security.Sid;
    public DateTimeOffset CreatedUtc { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? ExpiresUtc { get; set; }
    public string Helper { get; set; } = "";
    public string Status { get; set; } = "Prepared";
    public string Detail { get; set; } = "";
    public string PowerAction { get; set; } = "None";
    public bool Force { get; set; }
    public string BootId { get; set; } = "";
}

public static class ManagedChanges
{
    public static string LegacyRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WindowsEngineeringToolkit");
    public static string Root => Path.Combine(LegacyRoot, "native");
    private static string Jobs => Path.Combine(Root, "jobs");
    private static readonly string[] Active = ["Prepared", "Active", "Restoring", "Failed", "Conflict"];
    private const string UpdateKey = @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";
    private static readonly string[] ProtectedWriters = ["S-1-5-18", "S-1-5-32-544"];
    private static readonly FileSystemRights WriteMask = FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership | FileSystemRights.DeleteSubdirectoriesAndFiles;
    public static void VerifyProtected(string path)
    {
        Paths.NoReparse(path);
        var current = Path.GetFullPath(path);
        if (current != LegacyRoot) Paths.Contained(LegacyRoot, current);
        while (current.Length >= LegacyRoot.Length)
        {
            FileSystemSecurity acl = Directory.Exists(current) ? new DirectoryInfo(current).GetAccessControl() : new FileInfo(current).GetAccessControl();
            if (!ProtectedWriters.Contains(acl.GetOwner(typeof(SecurityIdentifier))?.Value ?? "")) throw new UnauthorizedAccessException("Unexpected recovery storage owner.");
            foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) if (rule.AccessControlType == AccessControlType.Allow && !ProtectedWriters.Contains(rule.IdentityReference.Value) && (rule.FileSystemRights & WriteMask) != 0) throw new UnauthorizedAccessException("Recovery storage permits untrusted writes.");
            if (current.Equals(LegacyRoot, StringComparison.OrdinalIgnoreCase)) return;
            current = Path.GetDirectoryName(current)!;
        }
        throw new IOException("Invalid recovery ancestry.");
    }
    private static void DirectoryProtected(string path)
    {
        if (Directory.Exists(path)) { VerifyProtected(path); return; }
        Paths.NoReparse(path);
        var acl = new DirectorySecurity(); acl.SetOwner(new SecurityIdentifier("S-1-5-32-544")); acl.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { "S-1-5-18", "S-1-5-32-544", "S-1-5-32-545" }) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), ProtectedWriters.Contains(sid) ? FileSystemRights.FullControl : FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(acl); VerifyProtected(path);
    }
    private static FileStream Lock()
    {
        VerifyProtected(Root); var path = Path.Combine(Root, "state.lock"); Paths.NoReparse(path);
        for (var attempt = 0; ; attempt++) { try { var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); VerifyProtected(path); return stream; } catch (IOException) when (attempt < 100) { Thread.Sleep(50); } }
    }
    private static string JobPath(string id) { if (!System.Text.RegularExpressions.Regex.IsMatch(id, "\\A[a-f0-9]{32}\\z")) throw new InvalidDataException("Invalid job ID."); return Path.Combine(Jobs, id + ".json"); }
    public static void Validate(ManagedJob job)
    {
        JobPath(job.Id);
        if (job.SchemaVersion != 2 || !new[] { "Probe", "Firewall", "Defender", "Updates", "Power" }.Contains(job.Kind) || !Active.Concat(new[] { "Restored", "Cancelled", "Expired", "Executed", "ProbePassed" }).Contains(job.Status)) throw new InvalidDataException("Invalid recovery job.");
        if (!job.OwnerSid.StartsWith("S-1-5-", StringComparison.Ordinal) || new SecurityIdentifier(job.OwnerSid).Value != job.OwnerSid) throw new InvalidDataException("Invalid recovery owner.");
        Paths.Contained(Path.Combine(Root, "versions"), job.Helper);
        if (Path.GetFileName(job.Helper) != "Toolkit.Worker.exe") throw new InvalidDataException("Invalid helper.");
        if (job.Kind == "Firewall") { if (!new[] { "Private", "Public", "Domain", "All" }.Contains(job.Scope)) throw new InvalidDataException("Invalid firewall scope."); var names = job.Scope == "All" ? new[] { "Domain", "Private", "Public" } : new[] { job.Scope }; foreach (var state in new[] { job.Original, job.Applied }) if (!state.Keys.Order().SequenceEqual(names.Order()) || state.Values.Any(v => v is not ("0" or "1" or "2"))) throw new InvalidDataException("Invalid firewall snapshot."); }
        if (job.Kind == "Defender" && (job.Scope != "Realtime" || new[] { job.Original, job.Applied }.Any(s => s.Count != 1 || !s.TryGetValue("Disabled", out var v) || v is not ("True" or "False")))) throw new InvalidDataException("Invalid Defender snapshot.");
        if (job.Kind == "Updates" && (job.Scope != "Automatic" || new[] { job.Original, job.Applied }.Any(s => s.Count != 1 || !s.TryGetValue("Value", out var v) || v is not ("Absent" or "0" or "1")))) throw new InvalidDataException("Invalid update snapshot.");
        if (job.Kind == "Power" && (job.Scope != "Local" || job.ExpiresUtc == null || job.PowerAction is not ("Shutdown" or "Restart") || job.BootId.Length == 0 || job.Original.Count != 0 || job.Applied.Count != 0)) throw new InvalidDataException("Invalid power job.");
        if (job.Kind != "Power" && (job.PowerAction != "None" || job.Force)) throw new InvalidDataException("Power fields on setting job.");
    }
    private static ManagedJob Load(string id)
    {
        var path = JobPath(id); VerifyProtected(path);
        if (new FileInfo(path).Length > 65536) throw new InvalidDataException("Recovery record too large.");
        var job = Json.Read<ManagedJob>(File.ReadAllText(path)); Validate(job); if (job.Id != id) throw new InvalidDataException("Recovery filename mismatch."); return job;
    }
    private static void Save(ManagedJob job)
    {
        Validate(job); VerifyProtected(Jobs); var path = JobPath(job.Id); if (File.Exists(path)) VerifyProtected(path);
        var temporary = Path.Combine(Jobs, Guid.NewGuid().ToString("N") + ".tmp");
        try { File.WriteAllText(temporary, Json.Write(job)); VerifyProtected(temporary); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static List<ManagedJob> All() { if (!Directory.Exists(Jobs)) return []; VerifyProtected(Jobs); return Directory.EnumerateFiles(Jobs, "*.json").Select(f => Load(Path.GetFileNameWithoutExtension(f))).ToList(); }
    public static List<Dictionary<string, string>> Summary()
    {
        var rows = new List<Dictionary<string, string>>();
        foreach (var job in All()) { var task = job.ExpiresUtc.HasValue && Active.Contains(job.Status) ? TaskSchedulerApi.Status(job.Id) : ("Not scheduled", (int?)null); rows.Add(new() { ["_key"] = job.Id, ["Id"] = job.Id, ["Kind"] = job.Kind, ["Scope"] = job.Scope, ["Status"] = job.Status, ["Deadline"] = job.ExpiresUtc?.ToString("O") ?? "Manual", ["TaskState"] = task.Item1, ["LastTaskResult"] = task.Item2?.ToString() ?? "", ["Detail"] = job.Detail }); }
        var legacy = Path.Combine(LegacyRoot, "jobs");
        if (Directory.Exists(legacy)) { VerifyProtected(legacy); foreach (var file in Directory.EnumerateFiles(legacy, "*.json").Take(500)) { VerifyProtected(file); if (new FileInfo(file).Length > 65536) throw new InvalidDataException("Legacy record too large."); using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(file)); var job = doc.RootElement; var status = job.GetProperty("Status").GetString() ?? ""; rows.Add(new() { ["_key"] = "legacy:" + Path.GetFileName(file), ["Kind"] = job.GetProperty("Kind").GetString() ?? "", ["Status"] = status, ["Legacy"] = "True", ["Detail"] = "Manage with the original TOOLX version; its helper and task remain pinned." }); } }
        return rows;
    }
    public static Dictionary<string, string> ReadSetting(string kind, string scope)
    {
        if (kind == "Firewall") return WindowsProviders.Query("MSFT_NetFirewallProfile", "Name,Enabled", ns: "root/standardcimv2").Where(r => scope == "All" || r["Name"].Equals(scope, StringComparison.OrdinalIgnoreCase)).ToDictionary(r => r["Name"], r => r["Enabled"]);
        if (kind == "Defender") { var row = WindowsProviders.Query("MSFT_MpComputerStatus", "AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled", ns: "root/Microsoft/Windows/Defender").Single(); if (row["AMServiceEnabled"] != "True" || row["AntivirusEnabled"] != "True") throw new IOException("Microsoft Defender Antivirus is not active."); return new() { ["Disabled"] = (row["RealTimeProtectionEnabled"] != "True").ToString() }; }
        if (kind == "Updates") { using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(UpdateKey); if (key == null || !key.GetValueNames().Contains("NoAutoUpdate")) return new() { ["Value"] = "Absent" }; var value = key.GetValue("NoAutoUpdate"); if (key.GetValueKind("NoAutoUpdate") != RegistryValueKind.DWord || value is not int n || n is not (0 or 1)) throw new InvalidDataException("Unsupported existing update policy."); return new() { ["Value"] = n.ToString() }; }
        throw new ArgumentException("Unknown setting.");
    }
    private static void WriteSetting(string kind, string scope, Dictionary<string, string> state)
    {
        if (kind == "Firewall") { using var searcher = new ManagementObjectSearcher(@"root\standardcimv2", "SELECT * FROM MSFT_NetFirewallProfile"); using var objects = searcher.Get(); foreach (ManagementObject obj in objects) using (obj) if (state.TryGetValue((string)obj["Name"], out var enabled)) { obj["Enabled"] = ushort.Parse(enabled); obj.Put(); } return; }
        if (kind == "Defender") { if (state["Disabled"] == "True" && WindowsProviders.Query("MSFT_MpComputerStatus", "IsTamperProtected", ns: "root/Microsoft/Windows/Defender").Single()["IsTamperProtected"] == "True") throw new UnauthorizedAccessException("Tamper Protection blocks this change."); using var cls = new ManagementClass(@"\\.\root\Microsoft\Windows\Defender:MSFT_MpPreference"); using var input = cls.GetMethodParameters("Set"); input["DisableRealtimeMonitoring"] = bool.Parse(state["Disabled"]); using var output = cls.InvokeMethod("Set", input, null); if (Convert.ToUInt32(output?["ReturnValue"]) != 0) throw new IOException("Defender rejected the change."); return; }
        if (kind == "Updates") { using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64); using var key = machine.CreateSubKey(UpdateKey, true); if (state["Value"] == "Absent") key.DeleteValue("NoAutoUpdate", false); else key.SetValue("NoAutoUpdate", int.Parse(state["Value"]), RegistryValueKind.DWord); return; }
        throw new ArgumentException("Unknown setting.");
    }
    private static bool Equal(Dictionary<string, string> a, Dictionary<string, string> b) => a.Count == b.Count && a.All(p => b.TryGetValue(p.Key, out var v) && v == p.Value);
    private static async Task<string> Initialize(string source, CancellationToken token)
    {
        if (!Security.IsAdmin) throw new UnauthorizedAccessException("Administrator privileges required.");
        DirectoryProtected(LegacyRoot); DirectoryProtected(Root); DirectoryProtected(Jobs); DirectoryProtected(Path.Combine(Root, "versions"));
        var payload = Directory.EnumerateFiles(source).Where(p => new[] { ".exe", ".dll" }.Contains(Path.GetExtension(p)) || p.EndsWith(".deps.json") || p.EndsWith(".runtimeconfig.json")).OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase).ToArray();
        using var digest = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        foreach (var path in payload) { Paths.NoReparse(path); digest.AppendData(System.Text.Encoding.UTF8.GetBytes(Path.GetFileName(path))); using var file = File.OpenRead(path); digest.AppendData(await System.Security.Cryptography.SHA256.HashDataAsync(file, token)); }
        var hash = Convert.ToHexString(digest.GetHashAndReset());
        var folder = Path.Combine(Root, "versions", "0.2.3-" + hash[..16]); DirectoryProtected(folder);
        foreach (var path in payload) { Paths.NoReparse(path); var target = Path.Combine(folder, Path.GetFileName(path)); if (File.Exists(target)) { VerifyProtected(target); if (!System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)).SequenceEqual(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(target)))) throw new IOException("Pinned helper content changed; rebuild with a new version."); } else File.Copy(path, target); VerifyProtected(target); }
        var helper = Path.Combine(folder, "Toolkit.Worker.exe");
        var probe = new ManagedJob { Kind = "Probe", Scope = "Local", Helper = helper }; Save(probe);
        try { TaskSchedulerApi.Register(probe, true); TaskSchedulerApi.Start(probe.Id); for (var n = 0; n < 40; n++) { await Task.Delay(250, token); if (Load(probe.Id).Status == "ProbePassed") return helper; } throw new IOException("Scheduled recovery preflight failed. No setting was changed."); }
        finally { TaskSchedulerApi.Remove(probe.Id); }
    }
    private static void Restore(ManagedJob job)
    {
        var current = ReadSetting(job.Kind, job.Scope);
        var decision = RecoveryPolicy.Restoration(job.Original, job.Applied, current);
        if (decision == RestorationDecision.AlreadyOriginal) { job.Status = "Restored"; job.Detail = "Already at the original state."; Save(job); TaskSchedulerApi.Remove(job.Id); return; }
        if (decision == RestorationDecision.Conflict) { job.Status = "Conflict"; job.Detail = "External changes detected; original state was not overwritten."; Save(job); return; }
        job.Status = "Restoring"; Save(job);
        try { WriteSetting(job.Kind, job.Scope, job.Original); if (!Equal(ReadSetting(job.Kind, job.Scope), job.Original)) throw new IOException("Restoration verification failed."); job.Status = "Restored"; job.Detail = "Original state restored."; Save(job); TaskSchedulerApi.Remove(job.Id); }
        catch (Exception e) { job.Status = "Failed"; job.Detail = e.Message; Save(job); throw; }
    }
    public static async Task<List<Dictionary<string, string>>> Execute(string source, string id, Dictionary<string, string> values, CancellationToken token)
    {
        if (id is "power.status" or "maintenance.managed-changes") return Summary().Where(r => id != "power.status" || r["Kind"] == "Power").ToList();
        if (!Security.IsAdmin) throw new UnauthorizedAccessException("Administrator privileges required.");
        if (id == "power.force-restart") { await Power("Restart", true); return []; }
        if (Summary().Any(r => r.GetValueOrDefault("Legacy") == "True" && Active.Contains(r["Status"]))) throw new InvalidOperationException("Finish legacy recovery jobs in the original TOOLX before creating native changes.");
        var helper = await Initialize(source, token);
        using var stateLock = Lock();
        if (id == "power.cancel") { foreach (var job in All().Where(j => j.Kind == "Power" && Active.Contains(j.Status))) { job.Status = "Cancelled"; Save(job); TaskSchedulerApi.Remove(job.Id); } return Summary(); }
        var kind = id.StartsWith("security.firewall") ? "Firewall" : id.StartsWith("security.defender") ? "Defender" : id.StartsWith("updates.") ? "Updates" : "Power";
        if (id.EndsWith("-restore") || id == "updates.resume") { foreach (var job in All().Where(j => j.Kind == kind && Active.Contains(j.Status))) Restore(job); return Summary(); }
        if (kind is "Firewall" or "Defender" && values.GetValueOrDefault("action") == "Enable") foreach (var job in All().Where(j => j.Kind == kind && Active.Contains(j.Status))) Restore(job);
        if (All().Any(j => Active.Contains(j.Status) && j.Kind == kind)) throw new InvalidOperationException("Restore or cancel the existing job of this kind first.");
        var scope = kind == "Firewall" ? values["profile"] : kind == "Defender" ? "Realtime" : kind == "Updates" ? "Automatic" : "Local";
        var newJob = new ManagedJob { Kind = kind, Scope = scope, Helper = helper };
        if (kind == "Power") { var scale = values["unit"] switch { "Seconds" => 1, "Minutes" => 60, "Hours" => 3600, _ => 86400 }; newJob.ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(long.Parse(values["duration"]) * scale); newJob.PowerAction = values["action"]; newJob.Force = values["closure"] == "Force"; newJob.BootId = WindowsProviders.BootId(); }
        else
        {
            if (kind == "Updates") { using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"); var edition = key?.GetValue("EditionID") as string ?? ""; if (!edition.StartsWith("Professional") && !edition.StartsWith("Enterprise") && !edition.StartsWith("Education")) throw new PlatformNotSupportedException("Automatic-update suspension requires Pro, Enterprise or Education."); using var managed = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Enrollments"); if (WindowsProviders.Query("Win32_ComputerSystem", "PartOfDomain").Single()["PartOfDomain"] == "True" || managed?.GetSubKeyNames().Any(n => { using var k = managed.OpenSubKey(n); return k?.GetValue("EnrollmentType") != null; }) == true) throw new UnauthorizedAccessException("Organization-managed devices are not supported for update suspension."); }
            newJob.Original = ReadSetting(kind, scope);
            if (kind == "Firewall" && newJob.Original.Count != (scope == "All" ? 3 : 1)) throw new IOException("Incomplete firewall snapshot.");
            newJob.Applied = kind == "Firewall" ? newJob.Original.Keys.ToDictionary(k => k, _ => values["action"] == "Enable" ? "1" : "2") : kind == "Defender" ? new() { ["Disabled"] = (values["action"] != "Enable").ToString() } : new() { ["Value"] = "1" };
            if (kind is "Firewall" or "Defender" && Equal(newJob.Original, newJob.Applied)) return Summary();
            if (kind == "Updates" && newJob.Original["Value"] != "Absent") throw new InvalidOperationException("An existing update policy will not be overridden.");
            if (kind == "Updates") newJob.ExpiresUtc = DateTimeOffset.UtcNow.AddMonths(int.Parse(values["months"]));
            else if (values["action"] == "Disable" && values["mode"] == "Timed") newJob.ExpiresUtc = DateTimeOffset.UtcNow.AddMinutes(int.Parse(values["minutes"]));
        }
        Save(newJob);
        try { if (newJob.ExpiresUtc != null) TaskSchedulerApi.Register(newJob); if (kind != "Power") { WriteSetting(kind, scope, newJob.Applied); if (!Equal(ReadSetting(kind, scope), newJob.Applied)) throw new IOException("Setting verification failed."); } newJob.Status = "Active"; Save(newJob); }
        catch (Exception e) { newJob.Detail = e.Message; newJob.Status = "Failed"; Save(newJob); if (kind != "Power") { try { Restore(newJob); } catch { } } throw; }
        return Summary();
    }
    public static async Task RunJob(string id, string mode, string executable)
    {
        if (!Security.IsAdmin) throw new UnauthorizedAccessException("Recovery requires an administrator token.");
        var job = Load(id); if (job.OwnerSid != Security.Sid || !Path.GetFullPath(executable).Equals(job.Helper, StringComparison.OrdinalIgnoreCase)) throw new UnauthorizedAccessException("Recovery owner/helper mismatch."); VerifyProtected(job.Helper);
        using var stateLock = Lock(); job = Load(id);
        if (mode == "Probe") { if (job.Kind != "Probe" || job.Status != "Prepared") throw new InvalidDataException("Invalid probe."); job.Status = "ProbePassed"; Save(job); return; }
        if (mode != "Execute" || job.Kind == "Probe") throw new InvalidDataException("Invalid recovery mode.");
        if (!Active.Contains(job.Status) || job.ExpiresUtc == null || DateTimeOffset.UtcNow < job.ExpiresUtc) return;
        if (job.Kind != "Power") { Restore(job); return; }
        var powerDecision = RecoveryPolicy.Power(job, DateTimeOffset.UtcNow, WindowsProviders.BootId());
        if (powerDecision == PowerDecision.Wait) return;
        if (powerDecision == PowerDecision.Expire) { job.Status = "Expired"; Save(job); TaskSchedulerApi.Remove(job.Id); return; }
        job.Status = "Executed"; Save(job);
        try { await Power(job.PowerAction, job.Force); } catch (Exception e) { job.Detail = "Power request failed: " + e.Message; Save(job); throw; } finally { TaskSchedulerApi.Remove(job.Id); }
    }
    private static async Task Power(string action, bool force) { var args = new List<string> { action == "Restart" ? "/r" : "/s", "/t", "0" }; if (force) args.Add("/f"); if (await NativeProcess.Run(Paths.WindowsExe("shutdown.exe"), args, _ => { }, CancellationToken.None) != 0) throw new IOException("Windows rejected the power request."); }
}
