using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class ToolkitGuiLauncher
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Toolkit.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("Toolkit.ps1 is missing. Keep Toolkit.GUI.exe and Toolkit.ps1 in the same folder.");

            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
            string powershell = Path.Combine(windows, system, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                throw new FileNotFoundException("Windows PowerShell 5.1 could not be found on this computer.");

            var info = new ProcessStartInfo(powershell);
            info.Arguments = "-NoLogo -NoProfile -STA -File \"" + script + "\" -Gui";
            info.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            var errors = new StringBuilder();
            object gate = new object();
            using (var process = new Process())
            {
                process.StartInfo = info;
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
                {
                    if (args.Data == null) return;
                    lock (gate)
                    {
                        int remaining = 8192 - errors.Length;
                        if (remaining > 0) errors.AppendLine(args.Data.Substring(0, Math.Min(remaining, args.Data.Length)));
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
                    MessageBox.Show(detail + "\r\n\r\nWindows policy must permit the local PowerShell script to run.",
                        "Toolkit could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Toolkit could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
