using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.ServiceProcess;
using Microsoft.Win32;

namespace ToolX;

public sealed class WindowsProviders(string root, OperationResult result, CancellationToken token, IProgress<OperationProgress>? progress)
{
    private static readonly Dictionary<string, (string Class, string Fields, string Filter, string Namespace)> Queries = new()
    {
        ["system.os"] = ("Win32_OperatingSystem", "Caption,Version,BuildNumber,OSArchitecture,WindowsDirectory", "", "root/cimv2"),
        ["system.computer"] = ("Win32_ComputerSystem", "Manufacturer,Model,TotalPhysicalMemory,DomainRole", "", "root/cimv2"),
        ["system.updates"] = ("Win32_QuickFixEngineering", "HotFixID,Description,InstalledOn", "", "root/cimv2"),
        ["system.activation"] = ("SoftwareLicensingProduct", "ID,Name,Description,PartialProductKey,LicenseStatus,GracePeriodRemaining", "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL", "root/cimv2"),
        ["system.drivers"] = ("Win32_PnPSignedDriver", "DeviceID,DeviceName,DriverProviderName,DriverVersion,DriverDate,InfName,Signer", "", "root/cimv2"),
        ["hardware.cpu"] = ("Win32_Processor", "DeviceID,Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed", "", "root/cimv2"),
        ["hardware.memory"] = ("Win32_PhysicalMemory", "DeviceLocator,Capacity,Speed,Manufacturer,PartNumber", "", "root/cimv2"),
        ["hardware.gpu"] = ("Win32_VideoController", "DeviceID,Name,DriverVersion,VideoModeDescription", "", "root/cimv2"),
        ["hardware.board"] = ("Win32_BaseBoard", "Tag,Manufacturer,Product,Version", "", "root/cimv2"),
        ["hardware.bios"] = ("Win32_BIOS", "Name,Manufacturer,SMBIOSBIOSVersion,ReleaseDate", "", "root/cimv2"),
        ["hardware.disks"] = ("Win32_DiskDrive", "DeviceID,Index,Model,InterfaceType,Size,Status", "", "root/cimv2"),
        ["hardware.usb"] = ("Win32_PnPEntity", "DeviceID,Name,Manufacturer,Status,PNPClass", "DeviceID LIKE 'USB%'", "root/cimv2"),
        ["storage.layout"] = ("Win32_DiskPartition", "DeviceID,DiskIndex,Index,Type,Size,StartingOffset,BootPartition", "", "root/cimv2"),
        ["storage.volumes"] = ("Win32_LogicalDisk", "DeviceID,VolumeName,FileSystem,DriveType", "", "root/cimv2"),
        ["storage.space"] = ("Win32_LogicalDisk", "DeviceID,Size,FreeSpace", "DriveType=3", "root/cimv2"),
        ["processes.startup"] = ("Win32_StartupCommand", "Name,Command,Location,User", "", "root/cimv2"),
        ["processes.stopped-auto-services"] = ("Win32_Service", "Name,DisplayName,State,StartMode,DelayedAutoStart,ExitCode", "StartMode='Auto' AND State<>'Running'", "root/cimv2"),
        ["security.users"] = ("Win32_UserAccount", "SID,Name,Disabled,Lockout,Status", "LocalAccount=True", "root/cimv2"),
        ["security.defender"] = ("MSFT_MpComputerStatus", "AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime,IsTamperProtected", "", "root/Microsoft/Windows/Defender"),
        ["security.firewall"] = ("MSFT_NetFirewallProfile", "Name,Enabled,DefaultInboundAction,DefaultOutboundAction", "", "root/standardcimv2"),
        ["troubleshooting.devices"] = ("Win32_PnPEntity", "DeviceID,Name,PNPClass,ConfigManagerErrorCode,Status", "ConfigManagerErrorCode<>0", "root/cimv2")
    };
    private static readonly Dictionary<string, string[]> Native = new()
    {
        ["network.ip"] = ["ipconfig.exe", "/all"], ["network.ping"] = ["ping.exe", "-n", "4", "-w", "1000"],
        ["network.trace"] = ["tracert.exe", "-d", "-h", "15", "-w", "1000"], ["network.loss"] = ["ping.exe", "-n", "20", "-w", "1000"],
        ["network.arp"] = ["arp.exe", "-a"], ["network.routes"] = ["route.exe", "print"], ["network.connections"] = ["netstat.exe", "-ano"],
        ["network.flush-dns"] = ["ipconfig.exe", "/flushdns"], ["repair.sfc-verify"] = ["sfc.exe", "/verifyonly"], ["repair.sfc"] = ["sfc.exe", "/scannow"],
        ["repair.dism-check"] = ["dism.exe", "/Online", "/Cleanup-Image", "/CheckHealth"], ["repair.dism-scan"] = ["dism.exe", "/Online", "/Cleanup-Image", "/ScanHealth"],
        ["repair.dism-restore"] = ["dism.exe", "/Online", "/Cleanup-Image", "/RestoreHealth", "/LimitAccess"], ["repair.chkdsk"] = ["chkdsk.exe"],
        ["repair.winsock"] = ["netsh.exe", "winsock", "reset"], ["repair.tcpip-reset"] = ["netsh.exe", "int", "ip", "reset"]
    };
    public static bool HasHandler(string id) => Queries.ContainsKey(id) || Native.ContainsKey(id) || OtherHandlers.Contains(id);
    private static readonly HashSet<string> OtherHandlers = new("system.uptime system.environment system.locale system.installed-apps system.power-plans system.full-specs network.dns network.port network.adapters network.listening-ports network.wifi network.hosts network.proxy network.dhcp-renew hardware.disk-health hardware.monitors hardware.tpm storage.hash storage.large-files storage.shares storage.management processes.list processes.top-resources processes.services processes.resource-monitor processes.task-manager processes.events processes.scheduled-tasks security.devices security.computer-management security.settings security.local-admins security.certificates troubleshooting.events troubleshooting.battery troubleshooting.updates troubleshooting.connectivity troubleshooting.bsod troubleshooting.boot-history troubleshooting.printers repair.temp repair.restart-spooler repair.icon-cache security.firewall-control security.firewall-restore security.defender-control security.defender-restore updates.suspend updates.resume power.countdown power.cancel power.status power.force-restart maintenance.managed-changes".Split(' '));
    public void Row(string key, params (string Key, object? Value)[] fields)
    {
        if (result.Rows.Count >= 2000) { result.Status = OperationStatus.Partial; result.Detail = "Result limit reached (2000 rows)."; return; }
        var row = new Dictionary<string, string> { ["_key"] = key };
        foreach (var (name, value) in fields) row[name] = Format(value);
        result.Rows.Add(row);
    }
    public static string Format(object? value) => value switch { null => "", Array array => string.Join(", ", array.Cast<object>().Select(Format)), IReadOnlyDictionary<string, string> fields => string.Join("; ", fields.Select(p => p.Key + "=" + p.Value)), DateTime time => time.ToUniversalTime().ToString("O"), _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? "" };
    public static List<Dictionary<string, string>> Query(string className, string fields = "*", string filter = "", string ns = "root/cimv2", CancellationToken cancellation = default)
    {
        var scope = new ManagementScope("\\\\.\\" + ns.Replace('/', '\\'), new ConnectionOptions { Timeout = TimeSpan.FromSeconds(10) });
        using var searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT " + fields + " FROM " + className + (filter == "" ? "" : " WHERE " + filter)), new System.Management.EnumerationOptions { Timeout = TimeSpan.FromSeconds(15), ReturnImmediately = true, Rewindable = false });
        using var objects = searcher.Get();
        var rows = new List<Dictionary<string, string>>();
        foreach (ManagementObject obj in objects)
        {
            using (obj)
            {
                cancellation.ThrowIfCancellationRequested();
                var row = obj.Properties.Cast<PropertyData>().ToDictionary(p => p.Name, p => className == "WmiMonitorID" && p.Name is "ManufacturerName" or "UserFriendlyName" or "SerialNumberID" && p.Value is Array codes ? new string(codes.Cast<object>().Select(Convert.ToUInt16).Where(c => c > 0).Select(c => (char)c).ToArray()).Trim() : Format(p.Value));
                row["_key"] = obj.Path.RelativePath;
                rows.Add(row);
                if (rows.Count >= 300) break;
            }
        }
        return rows;
    }
    private void Wmi(string id, string? section = null)
    {
        var q = Queries[id];
        foreach (var row in Query(q.Class, q.Fields, q.Filter, q.Namespace, token)) { if (section != null) { row["Section"] = section; row["_key"] = section + ":" + row["_key"]; } result.Rows.Add(row); }
    }
    private void Section(string name, Action action)
    {
        try { token.ThrowIfCancellationRequested(); action(); }
        catch (OperationCanceledException) { throw; }
        catch (Exception e) { result.Status = OperationStatus.Partial; Row("unavailable:" + name, ("Section", name), ("Status", "Unavailable"), ("Detail", e.Message)); }
    }
    private async Task RunNative(string exe, IEnumerable<string> args)
    {
        var arguments = args.ToArray(); var buffer = new System.Text.StringBuilder(); var gate = new object(); var truncated = false;
        var code = await NativeProcess.Run(Paths.WindowsExe(exe), arguments, text => { lock (gate) { var remaining = 262144 - buffer.Length; if (remaining > 0) buffer.Append(text.AsSpan(0, Math.Min(text.Length, remaining))); if (text.Length > remaining) truncated = true; } progress?.Report(new(result.CommandId, text)); }, token);
        Row("native:" + exe + ":" + string.Join('|', arguments), ("Output", buffer.ToString()));
        result.ExitCode = code;
        if (truncated) { result.Status = OperationStatus.Partial; result.Detail = "Output truncated at 256 KiB."; }
        if (code != 0) throw new IOException(exe + " exited with code " + code + ". Review the output.");
    }
    public async Task Execute(string id, Dictionary<string, string> v, CleanupItem[]? preview = null)
    {
        if (Queries.ContainsKey(id))
        {
            Wmi(id);
            if (id == "system.drivers" && v["scope"] == "ThirdParty") result.Rows.RemoveAll(r => r.GetValueOrDefault("DriverProviderName") == "Microsoft" || r.GetValueOrDefault("Signer", "").StartsWith("Microsoft Windows", StringComparison.OrdinalIgnoreCase));
            return;
        }
        if (Native.TryGetValue(id, out var command))
        {
            var args = command.Skip(1).ToList();
            if (id is "network.ping" or "network.trace" or "network.loss") args.Add(v["host"]);
            if (id == "repair.chkdsk") args.Add(v["drive"] + ":");
            if (id == "repair.dism-restore" && v.TryGetValue("source", out var source)) args.Add("/Source:" + source);
            await RunNative(command[0], args); return;
        }
        switch (id)
        {
            case "system.uptime": Row("uptime", ("LastBoot", BootId()), ("UptimeSeconds", Environment.TickCount64 / 1000)); break;
            case "system.environment": Row("environment", ("WindowsDirectory", Environment.GetFolderPath(Environment.SpecialFolder.Windows)), ("ProgramFiles", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)), ("LocalApplicationData", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)), ("RuntimeVersion", Environment.Version), ("Is64BitOS", Environment.Is64BitOperatingSystem), ("Is64BitProcess", Environment.Is64BitProcess)); break;
            case "system.locale": Row("locale", ("Culture", CultureInfo.CurrentCulture.Name), ("UICulture", CultureInfo.CurrentUICulture.Name), ("TimeZone", TimeZoneInfo.Local.Id)); break;
            case "system.installed-apps": InstalledApps(); break;
            case "system.power-plans": await RunNative("powercfg.exe", ["/list"]); await RunNative("powercfg.exe", ["/availablesleepstates"]); break;
            case "system.full-specs": FullSpecs(v["scope"]); break;
            case "network.dns": await RunNative("nslookup.exe", ["-type=" + v["recordType"], v["host"]]); break;
            case "network.port": using (var client = new TcpClient()) { await client.ConnectAsync(v["host"], int.Parse(v["port"]), token).AsTask().WaitAsync(TimeSpan.FromSeconds(10), token); Row("tcp", ("Host", v["host"]), ("Port", v["port"]), ("Connected", true)); } break;
            case "network.adapters": foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces()) Row(adapter.Id, ("Name", adapter.Name), ("Description", adapter.Description), ("Status", adapter.OperationalStatus), ("Speed", adapter.Speed), ("Addresses", adapter.GetIPProperties().UnicastAddresses.Select(a => a.Address.ToString()).ToArray())); break;
            case "network.listening-ports": result.Rows.AddRange(NativeNetwork.Listeners()); break;
            case "network.wifi": await RunNative("netsh.exe", ["wlan", "show", "interfaces"]); await RunNative("netsh.exe", ["wlan", "show", "profiles"]); break;
            case "network.hosts": var lines = await File.ReadAllLinesAsync(Path.Combine(Environment.SystemDirectory, "drivers", "etc", "hosts"), token); foreach (var line in lines.Where(l => l.Trim().Length > 0 && !l.TrimStart().StartsWith('#'))) Row("hosts:" + result.Rows.Count, ("Entry", line)); break;
            case "network.proxy": using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings")) Row("userproxy", ("Enabled", key?.GetValue("ProxyEnable")), ("Server", key?.GetValue("ProxyServer")), ("Override", key?.GetValue("ProxyOverride")), ("AutoConfigURL", key?.GetValue("AutoConfigURL"))); await RunNative("netsh.exe", ["winhttp", "show", "proxy"]); break;
            case "network.dhcp-renew": await RunNative("ipconfig.exe", ["/release"]); await RunNative("ipconfig.exe", ["/renew"]); break;
            case "hardware.disk-health": result.Rows.AddRange(Query("MSFT_PhysicalDisk", "DeviceID,FriendlyName,MediaType,HealthStatus,OperationalStatus,Size", ns: "root/Microsoft/Windows/Storage", cancellation: token)); Section("Reliability", () => result.Rows.AddRange(Query("MSFT_StorageReliabilityCounter", ns: "root/Microsoft/Windows/Storage", cancellation: token))); break;
            case "hardware.monitors": result.Rows.AddRange(Query("WmiMonitorID", ns: "root/wmi", cancellation: token)); result.Rows.AddRange(Query("Win32_VideoController", "DeviceID,Name,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate", cancellation: token)); break;
            case "hardware.tpm": Section("TPM", () => result.Rows.AddRange(Query("Win32_Tpm", "ManufacturerId,ManufacturerVersion,IsEnabled_InitialValue,IsActivated_InitialValue,IsOwned_InitialValue", ns: "root/CIMV2/Security/MicrosoftTpm", cancellation: token))); using (var secure = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\SecureBoot\State")) Row("secureboot", ("ReportedSecureBootEnabled", secure?.GetValue("UEFISecureBootEnabled") ?? "Unavailable"), ("Source", "Windows registry state")); break;
            case "storage.hash": using (var file = File.OpenRead(v["path"])) { var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, token)); Row("hash", ("Path", v["path"]), ("Algorithm", "SHA256"), ("Hash", hash)); if (v.TryGetValue("expected", out var expected) && !hash.Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Checksum mismatch."); } break;
            case "storage.large-files": LargeFiles(v["path"], int.Parse(v["top"])); break;
            case "storage.shares": result.Rows.AddRange(Query("Win32_Share", "Name,Path,Description,Type", cancellation: token)); result.Rows.AddRange(Query("Win32_MappedLogicalDisk", "DeviceID,ProviderName,Size,FreeSpace", cancellation: token)); break;
            case "processes.list": case "processes.top-resources": Processes(id == "processes.top-resources"); break;
            case "processes.services": foreach (var service in ServiceController.GetServices()) using (service) Row(service.ServiceName, ("Name", service.ServiceName), ("DisplayName", service.DisplayName), ("Status", service.Status)); break;
            case "processes.scheduled-tasks": result.Rows.AddRange(TaskSchedulerApi.List()); break;
            case "security.local-admins": LocalAdmins(); break;
            case "security.certificates": Certificates(int.Parse(v["days"])); break;
            case "troubleshooting.events": Events("System", int.Parse(v["hours"]) * 3600, "(Level=1 or Level=2)", 50); Events("Application", int.Parse(v["hours"]) * 3600, "(Level=1 or Level=2)", 50); break;
            case "troubleshooting.battery": Battery(); break;
            case "troubleshooting.updates": foreach (var name in new[] { "wuauserv", "BITS", "UsoSvc" }) Section(name, () => { using var service = new ServiceController(name); Row(name, ("Name", name), ("Status", service.Status)); }); foreach (var key in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending", @"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" }) using (var reg = Registry.LocalMachine.OpenSubKey(key)) Row(key, ("Indicator", key), ("Present", reg != null)); Row("updatepolicy", ("State", ManagedChanges.ReadSetting("Updates", "Automatic"))); result.Rows.AddRange(ManagedChanges.Summary()); break;
            case "troubleshooting.connectivity": foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces().Where(a => a.OperationalStatus == OperationalStatus.Up)) foreach (var gateway in adapter.GetIPProperties().GatewayAddresses.Where(g => !g.Address.Equals(IPAddress.Any))) { Row("gateway:" + adapter.Id, ("Gateway", gateway.Address)); using var ping = new Ping(); try { var reply = await ping.SendPingAsync(gateway.Address, TimeSpan.FromSeconds(1), cancellationToken: token); Row("gateway-ping:" + adapter.Id, ("Status", reply.Status)); } catch (PingException e) { Row("gateway-ping:" + adapter.Id, ("Detail", e.Message)); } } foreach (var address in await Dns.GetHostAddressesAsync(v["host"], token)) Row("dns:" + address, ("Host", v["host"]), ("Address", address)); await Execute("network.port", v); break;
            case "troubleshooting.boot-history": Events("System", int.Parse(v["days"]) * 86400, "(EventID=6005 or EventID=6006 or EventID=6008 or EventID=1074 or EventID=41 or EventID=42 or EventID=1)", 60); break;
            case "troubleshooting.bsod": Dumps(); Events("System", 30 * 86400, "(EventID=1001 or EventID=41)", 25); break;
            case "troubleshooting.printers": result.Rows.AddRange(Query("Win32_Printer", "Name,PortName,PrinterStatus,WorkOffline,Default", cancellation: token)); result.Rows.AddRange(Query("Win32_PrintJob", "JobId,Name,Document,JobStatus,TimeSubmitted", cancellation: token)); break;
            case "repair.temp": if (preview == null) throw new InvalidOperationException("Cleanup requires a confirmed preview."); foreach (var row in Cleanup.Delete(preview)) result.Rows.Add(row); break;
            case "repair.restart-spooler": await RestartSpooler(); break;
            case "repair.icon-cache": await RebuildIcons(); break;
            case "storage.management": case "security.devices": case "security.computer-management": case "processes.events": var snap = id switch { "storage.management" => "diskmgmt.msc", "security.devices" => "devmgmt.msc", "security.computer-management" => "compmgmt.msc", _ => "eventvwr.msc" }; Launch(Paths.WindowsExe("mmc.exe"), snap); break;
            case "processes.resource-monitor": Launch(Paths.WindowsExe("resmon.exe")); break;
            case "processes.task-manager": Launch(Paths.WindowsExe("taskmgr.exe")); break;
            case "security.settings": Process.Start(new ProcessStartInfo("windowsdefender:") { UseShellExecute = true }); Row("launched", ("Status", "Windows Security opened; changes there are outside TOOLX.")); break;
            case "security.firewall-control": case "security.firewall-restore": case "security.defender-control": case "security.defender-restore": case "updates.suspend": case "updates.resume": case "power.countdown": case "power.cancel": case "power.status": case "power.force-restart": case "maintenance.managed-changes": result.Rows.AddRange(await ManagedChanges.Execute(root, id, v, token)); break;
            default: throw new NotSupportedException("Unknown handler: " + id);
        }
    }
    private void Launch(string exe, params string[] args) { var start = new ProcessStartInfo(exe) { UseShellExecute = true }; foreach (var arg in args) start.ArgumentList.Add(arg); Process.Start(start); Row("launched", ("Status", "Launched; subsequent changes are outside TOOLX.")); }
    public static string BootId() => Query("Win32_OperatingSystem", "LastBootUpTime")[0]["LastBootUpTime"];
    private void FullSpecs(string scope)
    {
        var ids = scope switch
        {
            "Hardware" => new[] { "system.computer", "hardware.cpu", "hardware.memory", "hardware.gpu", "hardware.board", "hardware.disks", "network.adapters", "troubleshooting.battery" },
            "Firmware" => ["hardware.board", "hardware.bios"], "Windows" => ["system.os", "system.computer"], "Storage" => ["hardware.disks", "storage.layout", "storage.volumes", "storage.space"], "Network" => ["network.adapters"],
            _ => ["system.os", "system.computer", "hardware.cpu", "hardware.memory", "hardware.gpu", "hardware.board", "hardware.bios", "hardware.disks", "storage.layout", "storage.volumes", "storage.space", "network.adapters", "troubleshooting.battery"]
        };
        foreach (var id in ids) Section(id, () => { if (Queries.ContainsKey(id)) Wmi(id, id); else Execute(id, []).GetAwaiter().GetResult(); });
    }
    private void InstalledApps()
    {
        var seen = new HashSet<string>();
        foreach (var hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser }) foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            Section(hive + ":" + view, () => { using var baseKey = RegistryKey.OpenBaseKey(hive, view); using var uninstall = baseKey.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"); if (uninstall == null) return; foreach (var name in uninstall.GetSubKeyNames()) { token.ThrowIfCancellationRequested(); using var app = uninstall.OpenSubKey(name); var title = app?.GetValue("DisplayName") as string; var version = app?.GetValue("DisplayVersion") as string; if (string.IsNullOrWhiteSpace(title) || Equals(app?.GetValue("SystemComponent"), 1) || !seen.Add(title + "|" + version)) continue; Row(title + "|" + version, ("DisplayName", title), ("DisplayVersion", version), ("Publisher", app?.GetValue("Publisher")), ("InstallDate", app?.GetValue("InstallDate"))); } });
    }
    private void Processes(bool top)
    {
        var rows = new List<(int Id, string Name, long Memory, double Cpu)>();
        foreach (var p in Process.GetProcesses()) using (p) { token.ThrowIfCancellationRequested(); try { rows.Add((p.Id, p.ProcessName, p.WorkingSet64, p.TotalProcessorTime.TotalSeconds)); } catch (System.ComponentModel.Win32Exception) { } catch (InvalidOperationException) { } }
        if (top) rows = rows.OrderByDescending(p => p.Memory).Take(15).Concat(rows.OrderByDescending(p => p.Cpu).Take(15)).Distinct().ToList();
        foreach (var p in rows) Row(p.Id.ToString(), ("Id", p.Id), ("Name", p.Name), ("MemoryMiB", Math.Round(p.Memory / 1048576d, 2)), ("CpuSeconds", p.Cpu));
    }
    private void Events(string log, int seconds, string condition, int limit)
    {
        Section(log, () => { var query = new EventLogQuery(log, PathType.LogName, "*[System[" + condition + " and TimeCreated[timediff(@SystemTime) <= " + (seconds * 1000L) + "]]]") { ReverseDirection = true }; using var reader = new EventLogReader(query); for (var n = 0; n < limit; n++) { token.ThrowIfCancellationRequested(); using var item = reader.ReadEvent(); if (item == null) break; string text; try { text = item.FormatDescription(); } catch (EventLogException) { text = item.ToXml(); } Row(log + ":" + item.RecordId, ("Log", log), ("Id", item.Id), ("TimeCreated", item.TimeCreated), ("Provider", item.ProviderName), ("Message", text)); } });
    }
    private void Battery()
    {
        result.Rows.AddRange(Query("Win32_Battery", "DeviceID,Name,BatteryStatus,EstimatedChargeRemaining", cancellation: token));
        Section("Battery capacity", () => { var full = Query("BatteryFullChargedCapacity", ns: "root/wmi", cancellation: token); foreach (var battery in Query("BatteryStaticData", ns: "root/wmi", cancellation: token)) { var match = full.FirstOrDefault(r => r.GetValueOrDefault("InstanceName") == battery.GetValueOrDefault("InstanceName")); var designed = double.TryParse(battery.GetValueOrDefault("DesignedCapacity"), out var d) ? d : 0; var charged = double.TryParse(match?.GetValueOrDefault("FullChargedCapacity"), out var f) ? f : 0; Row("capacity:" + battery.GetValueOrDefault("InstanceName"), ("DesignCapacity", designed), ("FullChargeCapacity", charged), ("HealthPercent", designed > 0 ? Math.Round(charged * 100 / designed, 1) : "Unavailable"), ("Note", "Firmware reported; not a calibrated measurement.")); } });
    }
    private void Certificates(int days)
    {
        foreach (var location in new[] { StoreLocation.LocalMachine, StoreLocation.CurrentUser }) Section(location.ToString(), () => { using var store = new X509Store(StoreName.My, location); store.Open(OpenFlags.ReadOnly); foreach (var cert in store.Certificates) using (cert) if (cert.NotAfter <= DateTime.Now.AddDays(days)) Row(location + ":" + cert.Thumbprint, ("Store", location), ("Subject", cert.Subject), ("Thumbprint", cert.Thumbprint), ("NotAfter", cert.NotAfter), ("DaysRemaining", Math.Floor((cert.NotAfter - DateTime.Now).TotalDays))); });
    }
    private void LocalAdmins()
    {
        var groups = Query("Win32_Group", "Domain,Name,SID", "SID='S-1-5-32-544'");
        if (groups.Count == 0) throw new IOException("Administrators group unavailable.");
        var path = "Win32_Group.Domain='" + groups[0]["Domain"].Replace("'", "\\'") + "',Name='" + groups[0]["Name"].Replace("'", "\\'") + "'";
        using var group = new ManagementObject(path); using var members = group.GetRelated("Win32_Account");
        foreach (ManagementObject member in members) using (member) Row(Format(member["SID"]), ("Name", member["Name"]), ("Domain", member["Domain"]), ("SID", member["SID"]));
    }
    private void LargeFiles(string path, int top)
    {
        var stack = new Stack<string>(); stack.Push(path); var files = new List<FileInfo>(); var scanned = 0; var skipped = 0;
        while (stack.Count > 0 && scanned < 50000) { token.ThrowIfCancellationRequested(); var dir = stack.Pop(); try { foreach (var file in new DirectoryInfo(dir).EnumerateFiles()) { if (file.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue; files.Add(file); if (++scanned >= 50000) break; } foreach (var child in new DirectoryInfo(dir).EnumerateDirectories()) if (!child.Attributes.HasFlag(FileAttributes.ReparsePoint)) stack.Push(child.FullName); } catch (UnauthorizedAccessException) { skipped++; } catch (IOException) { skipped++; } }
        foreach (var file in files.OrderByDescending(f => f.Length).Take(top)) Row(file.FullName, ("Path", file.FullName), ("Length", file.Length), ("LastWriteTime", file.LastWriteTimeUtc));
        if (scanned >= 50000 || skipped > 0) { result.Status = OperationStatus.Partial; result.Detail = $"Scanned {scanned}; skipped directories {skipped}; limit 50000."; }
    }
    private void Dumps() { foreach (var path in new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Minidump"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "MEMORY.DMP") }) Section(path, () => { var files = Directory.Exists(path) ? new DirectoryInfo(path).EnumerateFiles("*.dmp").OrderByDescending(f => f.LastWriteTimeUtc).Take(20) : File.Exists(path) ? new[] { new FileInfo(path) } : Enumerable.Empty<FileInfo>(); foreach (var file in files) Row(file.Name, ("Name", file.Name), ("Size", file.Length), ("LastWriteTime", file.LastWriteTimeUtc)); }); }
    private async Task RestartSpooler()
    {
        var path = Paths.Local(Path.Combine(Environment.SystemDirectory, "spool", "PRINTERS"), true);
        using var service = new ServiceController("Spooler"); service.Stop(); service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20));
        try { foreach (var file in new DirectoryInfo(path).EnumerateFiles()) { Paths.NoReparse(file.FullName); file.Delete(); Row(file.Name, ("Status", "Deleted")); } }
        finally { service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20)); }
        await Task.CompletedTask;
    }
    private async Task RebuildIcons()
    {
        var path = Paths.Local(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Explorer"), true);
        var session = Process.GetCurrentProcess().SessionId;
        foreach (var p in Process.GetProcessesByName("explorer")) using (p) if (p.SessionId == session) p.Kill();
        try { await Task.Delay(500, token); foreach (var file in new DirectoryInfo(path).EnumerateFiles().Where(f => (f.Name.StartsWith("iconcache_") || f.Name.StartsWith("thumbcache_")) && f.Extension == ".db")) { Paths.NoReparse(file.FullName); file.Delete(); Row(file.Name, ("Status", "Deleted")); } }
        finally { Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = true }); }
    }
}
