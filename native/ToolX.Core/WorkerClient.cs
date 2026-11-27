using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Security.Principal;
using System.Security.AccessControl;

namespace ToolX;

public sealed record WorkerEnvelope(string Kind, string Payload);
public static class Wire
{
    public static readonly JsonSerializerOptions Options = new(Json.Options) { WriteIndented = false };
    public static async Task Write<T>(StreamWriter writer, T value) => await writer.WriteLineAsync(JsonSerializer.Serialize(value, Options));
    public static async Task<string?> Read(StreamReader reader, CancellationToken token, int limit = 16777216)
    {
        var text = new System.Text.StringBuilder(); var buffer = new char[1];
        while (await reader.ReadAsync(buffer.AsMemory(), token) != 0)
        {
            if (buffer[0] == '\n') return text.ToString().TrimEnd('\r');
            if (text.Length >= limit) throw new InvalidDataException("Worker message too large.");
            text.Append(buffer[0]);
        }
        return text.Length == 0 ? null : throw new EndOfStreamException("Incomplete worker message.");
    }
}
public static class WorkerClient
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint pid);
    public static async Task<OperationResult> Run(string root, OperationRequest request, CancellationToken token, IProgress<OperationProgress>? progress)
    {
        var pipeName = "toolx-" + Guid.NewGuid().ToString("N");
        var acl = new PipeSecurity(); acl.SetAccessRuleProtection(true, false);
        acl.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(Security.Sid), PipeAccessRights.FullControl, AccessControlType.Allow));
        using var pipe = NamedPipeServerStreamAcl.Create(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 65536, 65536, acl);
        var exe = Path.Combine(root, "Toolkit.Worker.exe"); Paths.Local(exe, false);
        Process? process;
        try { process = Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, Verb = "runas", Arguments = "--pipe " + pipeName + " --parent " + Environment.ProcessId, WindowStyle = ProcessWindowStyle.Hidden, WorkingDirectory = root }); }
        catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223) { throw new OperationCanceledException("UAC cancelled."); }
        using (process)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(60));
            await pipe.WaitForConnectionAsync(timeout.Token);
            if (process == null || !GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid) || pid != process.Id) throw new UnauthorizedAccessException("Worker identity mismatch.");
            using var reader = new StreamReader(pipe, leaveOpen: true); using var writer = new StreamWriter(pipe, leaveOpen: true) { AutoFlush = true };
            await Wire.Write(writer, request);
            while (await Wire.Read(reader, token) is { } line)
            {
                var message = Json.Read<WorkerEnvelope>(line);
                if (message.Kind == "progress") progress?.Report(Json.Read<OperationProgress>(message.Payload));
                else if (message.Kind == "result") return Json.Read<OperationResult>(message.Payload);
                else throw new InvalidDataException("Invalid worker response.");
            }
            throw new IOException("Worker disconnected. Inspect restoration status before retrying a change.");
        }
    }
}
