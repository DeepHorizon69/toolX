using System.Windows;
using System.Diagnostics;
using ToolX;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("ToolX.Gui.Tests")]

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            if (args.Any(a => a.Equals("-Terminal", StringComparison.OrdinalIgnoreCase) || a.Equals("-Cli", StringComparison.OrdinalIgnoreCase) || a.Equals("-Basic", StringComparison.OrdinalIgnoreCase))) { var start = new ProcessStartInfo(System.IO.Path.Combine(AppContext.BaseDirectory, "Toolkit.CLI.exe")) { UseShellExecute = true }; if (args.Contains("-Basic", StringComparer.OrdinalIgnoreCase)) start.ArgumentList.Add("-Basic"); Process.Start(start); return; }
            if (Environment.OSVersion.Version.Build < 14393) { MessageBox.Show("TOOLX requires Windows 10 1607 or later.", "TOOLX"); return; }
            var application = new Application(); application.DispatcherUnhandledException += (_, e) => { MessageBox.Show(e.Exception.Message, "TOOLX"); e.Handled = true; };
            application.Run(new MainWindow());
        }
        catch (Exception e) { MessageBox.Show(e.Message, "TOOLX startup"); }
    }
}
