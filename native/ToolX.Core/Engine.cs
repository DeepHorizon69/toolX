using System.Diagnostics;

namespace ToolX;

public sealed class Engine(string appRoot)
{
    public string AppRoot { get; } = Path.GetFullPath(appRoot);
    public async Task<OperationResult> Run(OperationRequest request, CancellationToken token = default, IProgress<OperationProgress>? progress = null)
    {
        var result = new OperationResult { CommandId = request.CommandId };
        var watch = Stopwatch.StartNew();
        try
        {
            var command = Catalog.Get(request.CommandId);
            var values = Catalog.Validate(command, request.Parameters);
            if (Environment.OSVersion.Version.Build < 14393) throw new PlatformNotSupportedException("Windows 10 1607 or later is required.");
            if ((!command.ReadOnly || command.RequiresAdmin) && !request.Confirmed) throw new InvalidOperationException("Explicit confirmation is required.");
            if (command.Risk == "HighRisk" && request.Confirmation != command.Id) throw new InvalidOperationException("Type the command ID to confirm.");
            if (command.RequiresAdmin && !Security.IsAdmin) return await WorkerClient.Run(AppRoot, request with { Parameters = values }, command.ReadOnly ? token : CancellationToken.None, progress);
            token.ThrowIfCancellationRequested();
            progress?.Report(new(command.Id, "Running"));
            var executionToken = !command.ReadOnly || command.Cancellation == "Unavailable" ? CancellationToken.None : token;
            await new WindowsProviders(AppRoot, result, executionToken, progress).Execute(command.Id, values, request.CleanupPreview);
            if (result.Status == default) result.Status = OperationStatus.Succeeded;
        }
        catch (OperationCanceledException) { result.Status = OperationStatus.Cancelled; result.Detail = "Cancelled."; }
        catch (UnauthorizedAccessException e) { result.Status = OperationStatus.PermissionDenied; result.Detail = e.Message; }
        catch (System.Management.ManagementException e) when (e.ErrorCode == System.Management.ManagementStatus.AccessDenied) { result.Status = OperationStatus.PermissionDenied; result.Detail = e.Message; }
        catch (System.Management.ManagementException e) when (e.ErrorCode is System.Management.ManagementStatus.InvalidClass or System.Management.ManagementStatus.InvalidNamespace or System.Management.ManagementStatus.NotSupported) { result.Status = OperationStatus.Unavailable; result.Detail = e.Message; }
        catch (PlatformNotSupportedException e) { result.Status = OperationStatus.Unavailable; result.Detail = e.Message; }
        catch (Exception e) { result.Status = result.Rows.Count > 0 ? OperationStatus.Partial : OperationStatus.Failed; result.Detail = e.Message; }
        finally { result.DurationMs = watch.ElapsedMilliseconds; }
        return result;
    }
}
