using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using ToolX;

internal static class Program
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint pid);
    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (!Security.IsAdmin) throw new UnauthorizedAccessException("Worker requires elevation.");
            if (args.Length == 4 && args[0] == "--job" && args[2] == "--mode") { await ManagedChanges.RunJob(args[1], args[3], Environment.ProcessPath!); return 0; }
            if (args.Length != 4 || args[0] != "--pipe" || args[2] != "--parent" || !System.Text.RegularExpressions.Regex.IsMatch(args[1], "\\Atoolx-[a-f0-9]{32}\\z") || !int.TryParse(args[3], out var parent)) throw new ArgumentException("Invalid worker arguments.");
            using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(30000);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid) || pid != parent) throw new UnauthorizedAccessException("Parent identity mismatch.");
            using var process = Process.GetProcessById(parent);
            var expectedRoot = Path.GetFullPath(AppContext.BaseDirectory);
            if (!Path.GetDirectoryName(process.MainModule!.FileName)!.Equals(expectedRoot.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) || !new[] { "Toolkit", "Toolkit.CLI", "ToolX.Tests" }.Contains(process.ProcessName)) throw new UnauthorizedAccessException("Unexpected parent application.");
            using var reader = new StreamReader(pipe, leaveOpen: true); using var writer = new StreamWriter(pipe, leaveOpen: true) { AutoFlush = true };
            using var readTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var line = await Wire.Read(reader, readTimeout.Token, 131072) ?? throw new EndOfStreamException();
            var request = Json.Read<OperationRequest>(line); var command = Catalog.Get(request.CommandId);
            if (!command.RequiresAdmin) throw new UnauthorizedAccessException("This operation does not need the elevated worker.");
            var progress = new WorkerProgress(value => { try { Wire.Write(writer, new WorkerEnvelope("progress", Json.Write(value))).GetAwaiter().GetResult(); } catch (IOException) { } });
            var result = await new Engine(AppContext.BaseDirectory).Run(request, progress: progress);
            await Wire.Write(writer, new WorkerEnvelope("result", Json.Write(result)));
            return result.Status == OperationStatus.Succeeded ? 0 : 1;
        }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }
    private sealed class WorkerProgress(Action<OperationProgress> callback) : IProgress<OperationProgress> { private readonly object gate = new(); public void Report(OperationProgress value) { lock (gate) callback(value); } }
}
