using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;

var repo = Path.GetFullPath(args.FirstOrDefault() ?? Path.Combine(AppContext.BaseDirectory, "../../../../../"));
var dotnet = Path.Combine(repo, ".tools", "dotnet", "dotnet.exe"); if (!File.Exists(dotnet)) dotnet = "dotnet";
async Task Run(string exe, params string[] arguments)
{
    var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = repo }; foreach (var arg in arguments) start.ArgumentList.Add(arg);
    start.Environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"; start.Environment["DOTNET_CLI_HOME"] = Path.Combine(repo, ".tools", "dotnet-home");
    using var p = Process.Start(start)!; await p.WaitForExitAsync(); if (p.ExitCode != 0) throw new IOException(exe + " failed: " + p.ExitCode);
}
try
{
    foreach (var rid in args.Skip(1).DefaultIfEmpty("win-x64"))
    {
        if (rid is not ("win-x64" or "win-x86")) throw new ArgumentException("RID must be win-x64 or win-x86.");
        var artifacts = Path.Combine(repo, "artifacts"); Directory.CreateDirectory(artifacts);
        var destination = Path.Combine(artifacts, "TOOLX-0.2.3-" + rid); Directory.CreateDirectory(destination);
        foreach (var (project, name) in new[] { ("Gui", "Toolkit"), ("Cli", "Toolkit.CLI"), ("Worker", "Toolkit.Worker") })
        {
            var stage = Path.Combine(repo, ".build", "native-publish", rid, project);
            await Run(dotnet, "publish", Path.Combine("native", "ToolX." + project, "ToolX." + project + ".csproj"), "-c", "Release", "-r", rid, "--self-contained", "true", "-p:PublishSingleFile=false", "-p:PublishTrimmed=false", "-o", stage);
            if (project == "Gui") foreach (var file in Directory.EnumerateFiles(stage, "*", SearchOption.AllDirectories).Where(p => !p.EndsWith(".pdb"))) { var target = Path.Combine(destination, Path.GetRelativePath(stage, file)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target, true); }
            else foreach (var suffix in new[] { ".exe", ".dll", ".deps.json", ".runtimeconfig.json" }) File.Copy(Path.Combine(stage, name + suffix), Path.Combine(destination, name + suffix), true);
        }
        foreach (var file in Directory.EnumerateFiles(Path.Combine(repo, "Scripts"), "*", SearchOption.AllDirectories)) { var target = Path.Combine(destination, "Scripts", Path.GetRelativePath(Path.Combine(repo, "Scripts"), file)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target, true); }
        File.Copy(Path.Combine(repo, "docs", "Native-Rewrite.md"), Path.Combine(destination, "README.md"), true);
        File.Copy(Path.Combine(repo, "docs", "Native-Verification.md"), Path.Combine(destination, "VERIFICATION.md"), true);
        var cert = Environment.GetEnvironmentVariable("TOOLX_SIGN_CERT_SHA1");
        if (!string.IsNullOrWhiteSpace(cert)) { var signtool = Environment.GetEnvironmentVariable("TOOLX_SIGNTOOL") ?? "signtool.exe"; foreach (var name in new[] { "Toolkit.exe", "Toolkit.CLI.exe", "Toolkit.Worker.exe", "Toolkit.dll", "Toolkit.CLI.dll", "Toolkit.Worker.dll", "ToolX.Core.dll" }) await Run(signtool, "sign", "/sha1", cert, "/fd", "SHA256", "/tr", "http://timestamp.digicert.com", "/td", "SHA256", Path.Combine(destination, name)); }
        var hashes = Directory.EnumerateFiles(destination, "*", SearchOption.AllDirectories).Where(p => !p.EndsWith("SHA256SUMS.txt")).Order().Select(p => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p))) + "  " + Path.GetRelativePath(destination, p)); File.WriteAllLines(Path.Combine(destination, "SHA256SUMS.txt"), hashes);
        var archive = destination + ".zip"; if (File.Exists(archive)) File.Delete(archive); ZipFile.CreateFromDirectory(destination, archive, CompressionLevel.Optimal, true);
        File.WriteAllText(archive + ".sha256", Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(archive))) + "  " + Path.GetFileName(archive) + Environment.NewLine);
        Console.WriteLine("Portable package: " + archive);
    }
    return 0;
}
catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
