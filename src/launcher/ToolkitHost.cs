using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
#if !CONSOLE_HOST
using System.Windows.Forms;
#endif

internal static class ToolkitHost
{
    private static string QuoteArg(string value)
    {
        if (value == null) return "\"\"";
        var sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\\')
            {
                backslashes++;
            }
            else if (c == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
            }
            else
            {
                if (backslashes > 0) { sb.Append('\\', backslashes); backslashes = 0; }
                sb.Append(c);
            }
        }
        if (backslashes > 0) sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    private static string ResolvePowerShellPath()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
        string powershell = Path.Combine(windows, system, @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell))
            throw new FileNotFoundException("Windows PowerShell 5.1 could not be found on this computer.");
        return powershell;
    }

    private static string ExtractVerifiedScript(string sessionDir)
    {
        Directory.CreateDirectory(sessionDir);
        string scriptPath = Path.Combine(sessionDir, "Toolkit.ps1");
        Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("Toolkit.ps1.gz");
        if (resource == null)
            throw new InvalidOperationException("Embedded toolkit payload is missing.");

        using (resource)
        using (var gzip = new GZipStream(resource, CompressionMode.Decompress))
        using (var output = File.Create(scriptPath))
        {
            gzip.CopyTo(output);
        }

        using (var sha = SHA256.Create())
        using (var fs = File.OpenRead(scriptPath))
        {
            byte[] hashBytes = sha.ComputeHash(fs);
            string actual = BitConverter.ToString(hashBytes).Replace("-", string.Empty);
            if (!string.Equals(actual, ToolkitEmbeddedMeta.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Extracted toolkit payload failed integrity verification.");
        }
        return scriptPath;
    }

    private static void CleanupSessionDirectory(string sessionDir)
    {
        if (string.IsNullOrEmpty(sessionDir) || !Directory.Exists(sessionDir)) return;
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Directory.Delete(sessionDir, true);
                return;
            }
            catch (IOException) { Thread.Sleep(100); }
            catch (UnauthorizedAccessException) { Thread.Sleep(100); }
        }
    }

    private static void ShowFailure(string message)
    {
#if CONSOLE_HOST
        Console.Error.WriteLine(message);
#else
        MessageBox.Show(message, ToolkitEmbeddedMeta.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
#endif
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string sessionDir = null;
        try
        {
            string appRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
            var psArgs = new List<string>();
            bool hiddenGui = false;

#if CONSOLE_HOST
            bool guiFlag = false;
            var valueFlags = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "-ImportLocal", "-ImportUrl", "-ImportFolder", "-ImportSha256" };
            var switchFlags = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "-Basic", "-ListCommands", "-Check", "-Version", "-Gui", "-ImportOverwrite" };
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                if (string.Equals(arg, "-Help", StringComparison.OrdinalIgnoreCase) || string.Equals(arg, "--help", StringComparison.OrdinalIgnoreCase) || string.Equals(arg, "-h", StringComparison.OrdinalIgnoreCase))
                {
                    Console.WriteLine(ToolkitEmbeddedMeta.DisplayTitle);
                    Console.WriteLine("Usage: Toolkit.CLI.exe [-Basic | -ListCommands | -Check | -Version | -Gui | -ImportLocal <path> | -ImportUrl <https-url>] [-ImportFolder <name>] [-ImportSha256 <hex>] [-ImportOverwrite]");
                    return 0;
                }
                if (switchFlags.Contains(arg))
                {
                    if (string.Equals(arg, "-Gui", StringComparison.OrdinalIgnoreCase)) guiFlag = true;
                    psArgs.Add(arg);
                }
                else if (valueFlags.Contains(arg))
                {
                    if (i + 1 >= args.Length) throw new ArgumentException("Missing value for " + arg + ".");
                    psArgs.Add(arg);
                    psArgs.Add(args[++i]);
                }
                else
                {
                    throw new ArgumentException("Unsupported argument: " + arg + ". Use -Help for supported options.");
                }
            }
            hiddenGui = guiFlag;
#else
            if (args.Length == 0 || (args.Length == 1 && string.Equals(args[0], "-Gui", StringComparison.OrdinalIgnoreCase)))
            {
                hiddenGui = true;
                psArgs.Add("-Gui");
            }
            else if (args.Length == 1 && (string.Equals(args[0], "-Terminal", StringComparison.OrdinalIgnoreCase) || string.Equals(args[0], "-Cli", StringComparison.OrdinalIgnoreCase)))
            {
                hiddenGui = false;
            }
            else if ((args.Length == 1 && string.Equals(args[0], "-Basic", StringComparison.OrdinalIgnoreCase)) ||
                     (args.Length == 2 && string.Equals(args[0], "-Terminal", StringComparison.OrdinalIgnoreCase) && string.Equals(args[1], "-Basic", StringComparison.OrdinalIgnoreCase)))
            {
                hiddenGui = false;
                psArgs.Add("-Basic");
            }
            else
            {
                throw new ArgumentException("Unsupported arguments. Run Toolkit.exe for GUI, Toolkit.exe -Terminal for terminal mode, or use Toolkit.CLI.exe for console commands.");
            }
#endif

            string powershell = ResolvePowerShellPath();
            sessionDir = Path.Combine(Path.GetTempPath(), "toolX-" + Process.GetCurrentProcess().Id + "-" + Guid.NewGuid().ToString("N"));
            string scriptPath = ExtractVerifiedScript(sessionDir);

            var fullArgs = new List<string> { "-NoLogo", "-NoProfile", "-STA", "-File", scriptPath, "-AppRoot", appRoot };
            fullArgs.AddRange(psArgs);

            var encodedArgs = new StringBuilder();
            for (int i = 0; i < fullArgs.Count; i++)
            {
                if (i > 0) encodedArgs.Append(' ');
                encodedArgs.Append(QuoteArg(fullArgs[i]));
            }

            var info = new ProcessStartInfo(powershell);
            info.Arguments = encodedArgs.ToString();
            info.WorkingDirectory = appRoot;
            info.UseShellExecute = false;

            if (hiddenGui)
            {
                info.CreateNoWindow = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                var errors = new StringBuilder();
                object gate = new object();
                using (var process = new Process())
                {
                    process.StartInfo = info;
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs dataArgs)
                    {
                        if (dataArgs.Data == null) return;
                        lock (gate)
                        {
                            int remaining = 8192 - errors.Length;
                            if (remaining > 0) errors.AppendLine(dataArgs.Data.Substring(0, Math.Min(remaining, dataArgs.Data.Length)));
                        }
                    };
                    process.OutputDataReceived += delegate { };
                    process.Start();
                    process.BeginErrorReadLine();
                    process.BeginOutputReadLine();
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        string detail;
                        lock (gate) detail = errors.ToString().Trim();
                        if (detail.Length == 0) detail = "The toolkit stopped with exit code " + process.ExitCode + ".";
                        ShowFailure(detail + "\r\n\r\nWindows policy must permit PowerShell scripts to run.");
                    }
                    return process.ExitCode;
                }
            }
            else
            {
                info.CreateNoWindow = false;
                using (var process = new Process())
                {
                    process.StartInfo = info;
                    process.Start();
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
        }
        catch (Exception error)
        {
            ShowFailure(error.Message);
            return 1;
        }
        finally
        {
            CleanupSessionDirectory(sessionDir);
        }
    }
}
