namespace ToolX;

public sealed record CleanupItem(string Path, long Length, DateTime LastWriteTimeUtc);
public static class Cleanup
{
    public static string Root => Paths.Local(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp"), true);
    public static CleanupItem[] Preview() => new DirectoryInfo(Root).EnumerateFiles().Where(f => !f.Attributes.HasFlag(FileAttributes.ReparsePoint) && f.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-7)).Take(200).Select(f => new CleanupItem(f.FullName, f.Length, f.LastWriteTimeUtc)).ToArray();
    public static IEnumerable<Dictionary<string, string>> Delete(CleanupItem[] preview)
    {
        if (preview.Length > 200) throw new InvalidDataException("Cleanup limit exceeded.");
        var root = Root;
        foreach (var item in preview)
        {
            var row = new Dictionary<string, string> { ["_key"] = item.Path, ["Path"] = item.Path };
            try
            {
                var full = Paths.Contained(root, item.Path);
                if (!string.Equals(Path.GetDirectoryName(full), root, StringComparison.OrdinalIgnoreCase)) throw new IOException("Only immediate Temp files are eligible.");
                var file = new FileInfo(full);
                if (!file.Exists || file.Length != item.Length || file.LastWriteTimeUtc != item.LastWriteTimeUtc || file.LastWriteTimeUtc >= DateTime.UtcNow.AddDays(-7)) throw new IOException("File changed after preview.");
                file.Delete(); row["Status"] = "Deleted";
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { row["Status"] = "Skipped"; row["Detail"] = e.Message; }
            yield return row;
        }
    }
}
