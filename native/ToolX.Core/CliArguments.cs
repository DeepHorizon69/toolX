namespace ToolX;

public static class CliArguments
{
    public static void Validate(string[] args)
    {
        var switches = new HashSet<string>(new[] { "-Basic", "-ListCommands", "-Check", "-Version", "-Gui", "-ImportOverwrite", "-Help", "--help", "-h", "-ScriptConfirmed" }, StringComparer.OrdinalIgnoreCase);
        var values = new HashSet<string>(new[] { "-Language", "-Run", "-Param", "-RunCheck", "-Target", "-Extra", "-Export", "-Format", "-ImportLocal", "-ImportUrl", "-ImportFolder", "-ImportSha256", "-RunScript" }, StringComparer.OrdinalIgnoreCase);
        var primary = new HashSet<string>(new[] { "-ListCommands", "-Check", "-Version", "-Gui", "-Run", "-RunCheck", "-Compare", "-ImportLocal", "-ImportUrl", "-RunScript", "-Help", "--help", "-h" }, StringComparer.OrdinalIgnoreCase);
        var modes = 0; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            var option = args[i]; if (!seen.Add(option) && !option.Equals("-Param", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Repeated option: " + option);
            if (primary.Contains(option)) modes++;
            var count = option.Equals("-Compare", StringComparison.OrdinalIgnoreCase) ? 2 : values.Contains(option) ? 1 : switches.Contains(option) ? 0 : throw new ArgumentException("Unsupported option: " + option);
            if (i + count >= args.Length) throw new ArgumentException("Missing value: " + option); i += count;
        }
        if (modes > 1) throw new ArgumentException("Choose one operation mode. Use -Help.");
        if (seen.Contains("-ScriptConfirmed") && !seen.Contains("-RunScript")) throw new ArgumentException("Script confirmation applies only to the custom-script console.");
    }
}
