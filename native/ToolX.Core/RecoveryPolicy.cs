namespace ToolX;

public enum RestorationDecision { AlreadyOriginal, RestoreOwnedChange, Conflict }
public enum PowerDecision { Wait, Expire, Execute }
public static class RecoveryPolicy
{
    public static RestorationDecision Restoration(IReadOnlyDictionary<string, string> original, IReadOnlyDictionary<string, string> applied, IReadOnlyDictionary<string, string> current)
    {
        if (original.Count != applied.Count || original.Count != current.Count || original.Any(p => !applied.ContainsKey(p.Key) || !current.ContainsKey(p.Key))) return RestorationDecision.Conflict;
        if (original.All(p => current[p.Key] == p.Value)) return RestorationDecision.AlreadyOriginal;
        return original.All(p => current[p.Key] == p.Value || current[p.Key] == applied[p.Key]) ? RestorationDecision.RestoreOwnedChange : RestorationDecision.Conflict;
    }
    public static PowerDecision Power(ManagedJob job, DateTimeOffset now, string bootId)
    {
        if (job.Kind != "Power" || job.ExpiresUtc == null || now < job.ExpiresUtc || job.Status is "Executed" or "Cancelled" or "Expired") return PowerDecision.Wait;
        if (job.Status != "Active" || (now - job.ExpiresUtc.Value).TotalSeconds > 60 || job.BootId != bootId) return PowerDecision.Expire;
        return PowerDecision.Execute;
    }
}
