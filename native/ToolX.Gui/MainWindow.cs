using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Data;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using ToolX;

internal sealed class MainWindow : Window
{
    private readonly Engine engine = new(AppContext.BaseDirectory);
    private readonly ScriptImporter scripts = new(AppContext.BaseDirectory);
    private string language = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "id" ? "id" : "en";
    private string theme = "System";
    private string page = "Tools";
    private string category = "";
    private string searchText = "";
    private bool confirmations = true;
    private CancellationTokenSource? operation;
    private SupportReport? report;
    private SupportReport? before;
    private SupportReport? after;
    private CommandDefinition? selected;
    private Grid shell = null!;
    private ContentControl content = null!;
    private TextBlock status = null!;
    private TextBlock banner = null!;
    private TextBox search = null!;
    private TreeView navigationTree = null!;
    private DataGrid? commandList;
    private readonly Dictionary<string, FrameworkElement> inputs = [];
    private readonly List<Button> runButtons = [];
    private readonly Dictionary<Button, bool> cancelButtons = [];
    private TextBox? output;
    private string T(string key) => L10n.T(key, language);
    public MainWindow()
    {
        Title = "TOOLX Windows Edition | Alpha 0.2.3 | by ALSA";
        Width = Math.Min(1180, SystemParameters.WorkArea.Width - 24); Height = Math.Min(780, SystemParameters.WorkArea.Height - 24); MinWidth = 640; MinHeight = 400;
        FontFamily = new FontFamily("Segoe UI"); FontSize = 13;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ApplyTheme(); Build();
        Closing += (_, e) => { if (operation != null) { e.Cancel = true; if (selected?.ReadOnly != false) operation.Cancel(); status.Text = language == "id" ? "Tunggu operasi selesai sebelum menutup." : "Wait for the operation to finish before closing."; } };
        SystemParameters.StaticPropertyChanged += SystemChanged;
        Closed += (_, _) => SystemParameters.StaticPropertyChanged -= SystemChanged;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { search.Focus(); search.SelectAll(); e.Handled = true; } if (e.Key == Key.Escape && operation != null && selected?.ReadOnly != false) operation.Cancel(); };
    }
    private void SystemChanged(object? sender, PropertyChangedEventArgs e) { if (theme == "System" || e.PropertyName == "HighContrast") Dispatcher.Invoke(ApplyTheme); }
    private void ApplyTheme()
    {
        var dark = theme == "Dark" || (theme == "System" && Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int n && n == 0);
        Theme.Apply(this, dark);
    }
    private Button Button(string label, Action action, bool run = false)
    {
        var button = new Button { Content = T(label), Margin = new Thickness(0, 0, 6, 0), MinWidth = 80 };
        AutomationProperties.SetName(button, T(label)); button.Click += (_, _) => { try { action(); } catch (Exception e) { Error(e); } };
        if (run) { runButtons.Add(button); button.IsEnabled = operation == null; } return button;
    }
    private TextBlock Label(string label, bool heading = false) => new() { Text = T(label), FontSize = heading ? 19 : 13, FontWeight = heading ? FontWeights.SemiBold : FontWeights.Normal, Margin = new Thickness(0, heading ? 0 : 8, 0, 8), TextWrapping = TextWrapping.Wrap };
    private Button CancelButton(bool allowed = true) { var button = Button("Cancel", () => operation?.Cancel()); button.IsEnabled = false; cancelButtons.Add(button, allowed); return button; }
    private void Build()
    {
        runButtons.Clear(); inputs.Clear();
        shell = new Grid(); shell.RowDefinitions.Add(new() { Height = GridLength.Auto }); shell.RowDefinitions.Add(new() { Height = GridLength.Auto }); shell.RowDefinitions.Add(new()); shell.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var toolbar = new DockPanel { Margin = new Thickness(12, 8, 12, 8) };
        var wordmark = new TextBlock { Text = "TOOLX", FontSize = 20, FontWeight = FontWeights.Bold, Width = 120, VerticalAlignment = VerticalAlignment.Center }; wordmark.SetResourceReference(TextBlock.ForegroundProperty, "Accent"); toolbar.Children.Add(wordmark);
        toolbar.Children.Add(Button("Refresh", () => ShowPage())); toolbar.Children.Add(Button("Terminal", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Toolkit.CLI.exe")) { UseShellExecute = true })));
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right }; DockPanel.SetDock(right, Dock.Right);
        var languages = new ComboBox { ItemsSource = new[] { "Indonesia", "English" }, SelectedIndex = language == "id" ? 0 : 1, Width = 105, Margin = new Thickness(8, 0, 6, 0) }; AutomationProperties.SetName(languages, "Language / Bahasa"); languages.SelectionChanged += (_, _) => { if (operation != null) { languages.SelectedIndex = language == "id" ? 0 : 1; return; } language = languages.SelectedIndex == 0 ? "id" : "en"; Build(); }; right.Children.Add(languages);
        var themes = new ComboBox { ItemsSource = new[] { T("System"), T("Light"), T("Dark") }, SelectedIndex = Array.IndexOf(new[] { "System", "Light", "Dark" }, theme), Width = 90 }; AutomationProperties.SetName(themes, T("Theme")); themes.SelectionChanged += (_, _) => { theme = new[] { "System", "Light", "Dark" }[themes.SelectedIndex]; ApplyTheme(); }; right.Children.Add(themes); toolbar.Children.Add(right); shell.Children.Add(toolbar);
        banner = new TextBlock { Text = T(confirmations ? "Confirmations are ON" : "Confirmations are OFF") + (Security.IsAdmin ? " | " + T("Administrator") : ""), Margin = new Thickness(12, 0, 12, 8), FontWeight = FontWeights.SemiBold }; Grid.SetRow(banner, 1); shell.Children.Add(banner);
        var body = new Grid(); body.ColumnDefinitions.Add(new() { Width = new GridLength(220), MinWidth = 180 }); body.ColumnDefinitions.Add(new() { Width = new GridLength(5) }); body.ColumnDefinitions.Add(new()); Grid.SetRow(body, 2);
        var tree = new TreeView { Margin = new Thickness(12, 0, 0, 0) }; navigationTree = tree; AutomationProperties.SetName(tree, T("Tools"));
        var tools = new TreeViewItem { Header = T("Tools"), Tag = "Tools", IsExpanded = true }; tree.Items.Add(tools);
        foreach (var group in Catalog.Commands.Select(c => c.Category).Distinct()) tools.Items.Add(new TreeViewItem { Header = T(group), Tag = group });
        foreach (var name in new[] { "Checks", "Reports", "Compare", "Scripts", "Import", "Settings" }) tree.Items.Add(new TreeViewItem { Header = T(name), Tag = name });
        tree.SelectedItemChanged += (_, e) => { if (operation != null) return; var tag = ((TreeViewItem)e.NewValue).Tag.ToString()!; page = Catalog.Commands.Any(c => c.Category == tag) ? "Tools" : tag; category = page == "Tools" && tag != "Tools" ? tag : ""; ShowPage(); };
        body.Children.Add(tree); var splitter = new GridSplitter { Width = 5, HorizontalAlignment = HorizontalAlignment.Stretch }; Grid.SetColumn(splitter, 1); body.Children.Add(splitter);
        content = new ContentControl { Margin = new Thickness(12, 0, 12, 0) }; Grid.SetColumn(content, 2); body.Children.Add(content); shell.Children.Add(body);
        var bar = new StatusBar { Margin = new Thickness(8, 5, 8, 5) }; status = new TextBlock { Text = T("Ready") }; bar.Items.Add(status); bar.Items.Add(new Separator()); bar.Items.Add(new TextBlock { Text = "91 built-ins | C#/.NET | 0.2.3" }); Grid.SetRow(bar, 3); shell.Children.Add(bar);
        Content = shell; ShowPage();
    }
    private void ShowPage()
    {
        if (operation != null) return;
        runButtons.Clear(); cancelButtons.Clear(); inputs.Clear(); output = null; if (page != "Tools") selected = null;
        switch (page) { case "Tools": Tools(); break; case "Checks": Checks(); break; case "Reports": ReportPage(); break; case "Compare": ComparePage(); break; case "Scripts": ScriptsPage(); break; case "Import": ImportPage(); break; case "Settings": SettingsPage(); break; }
    }
    private StackPanel Page(string title) { var panel = new StackPanel { Margin = new Thickness(4) }; panel.Children.Add(Label(title, true)); content.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; return panel; }
    private TextBox TextField(StackPanel panel, string label, string value = "") { var box = new TextBox { Text = value, Margin = new Thickness(0, 0, 0, 8), MinHeight = 30 }; var text = new Label { Content = T(label), Target = box, Padding = new Thickness(0, 8, 0, 4) }; panel.Children.Add(text); panel.Children.Add(box); AutomationProperties.SetName(box, T(label)); return box; }
    private void Tools()
    {
        var grid = new Grid(); grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new() { Height = new GridLength(2, GridUnitType.Star), MinHeight = 120 }); grid.RowDefinitions.Add(new() { Height = new GridLength(5) }); grid.RowDefinitions.Add(new() { Height = new GridLength(3, GridUnitType.Star), MinHeight = 180 });
        search = new TextBox { Text = searchText, Margin = new Thickness(0, 0, 0, 8), ToolTip = T("Search") + " (Ctrl+F)", MinHeight = 32 }; AutomationProperties.SetName(search, T("Search")); grid.Children.Add(search);
        var list = new DataGrid { AutoGenerateColumns = false, IsReadOnly = true, SelectionMode = DataGridSelectionMode.Single, CanUserAddRows = false, HeadersVisibility = DataGridHeadersVisibility.Column, RowHeaderWidth = 0, EnableRowVirtualization = true }; commandList = list; AutomationProperties.SetName(list, T("Tools"));
        foreach (var (header, binding, width) in new[] { ("Tools", "Name", 3d), ("Risk", "Risk", 1.2), ("Administrator", "Admin", 1.2) }) list.Columns.Add(new DataGridTextColumn { Header = T(header), Binding = new System.Windows.Data.Binding(binding), MinWidth = binding == "Name" ? 180 : 110, Width = new DataGridLength(width, DataGridLengthUnitType.Star) });
        void Filter() { searchText = search.Text; list.ItemsSource = Catalog.Commands.Where(c => (category == "" || c.Category == category) && (searchText == "" || (c.Id + " " + c.Name + " " + L10n.CommandName(c, language) + " " + string.Join(' ', c.Keywords)).Contains(searchText, StringComparison.OrdinalIgnoreCase))).Select(c => new { c.Id, Name = L10n.CommandName(c, language), Risk = T(c.Risk), Admin = T(c.RequiresAdmin ? "Required" : "Not required") }).ToArray(); }
        var details = new ContentControl(); Grid.SetRow(details, 3); grid.Children.Add(details);
        list.SelectionChanged += (_, _) => { if (operation != null || list.SelectedItem == null) return; string id = (string)list.SelectedItem.GetType().GetProperty("Id")!.GetValue(list.SelectedItem)!; selected = Catalog.Get(id); Details(details); };
        search.TextChanged += (_, _) => Filter(); Filter(); Grid.SetRow(list, 1); grid.Children.Add(list); var splitter = new GridSplitter { Height = 5, HorizontalAlignment = HorizontalAlignment.Stretch }; Grid.SetRow(splitter, 2); grid.Children.Add(splitter);
        details.Content = Label("Choose a command"); content.Content = grid;
    }
    private void Details(ContentControl host)
    {
        if (selected == null) return; inputs.Clear(); runButtons.Clear(); cancelButtons.Clear(); var command = selected;
        var panel = new StackPanel(); panel.Children.Add(Label(L10n.CommandName(command, language), true)); panel.Children.Add(new TextBlock { Text = command.Description + "\n" + L10n.Consequence(command, language), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        foreach (var p in command.Parameters)
        {
            if (p.Type == "Choice") { var box = new ComboBox { ItemsSource = p.AllowedValues, SelectedItem = p.Default.ToString(), Margin = new Thickness(0, 0, 0, 8), MinHeight = 30 }; panel.Children.Add(new Label { Content = p.Name, Target = box }); panel.Children.Add(box); inputs[p.Name] = box; }
            else { var box = TextField(panel, p.Name, p.Default.ValueKind is System.Text.Json.JsonValueKind.Undefined or System.Text.Json.JsonValueKind.Null ? "" : p.Default.ToString()); inputs[p.Name] = box; if (p.Type is "LocalFile" or "LocalDirectory") panel.Children.Add(Button("Browse", () => { if (p.Type == "LocalDirectory") { var dialog = new OpenFolderDialog(); if (dialog.ShowDialog() == true) box.Text = dialog.FolderName; } else { var dialog = new OpenFileDialog(); if (dialog.ShowDialog() == true) box.Text = dialog.FileName; } })); }
        }
        var actions = new WrapPanel { Margin = new Thickness(0, 8, 0, 8) }; actions.Children.Add(Button("Run", () => _ = RunCommand(command), true)); actions.Children.Add(CancelButton(command.ReadOnly && command.Cancellation != "Unavailable")); panel.Children.Add(actions); output = OutputBox(); panel.Children.Add(output); host.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
    private TextBox OutputBox() { var box = new TextBox { Text = T("No results yet"), FontFamily = new FontFamily("Consolas"), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MinHeight = 180, MaxHeight = 500 }; AutomationProperties.SetName(box, T("Results")); return box; }
    private async Task RunCommand(CommandDefinition command)
    {
        try
        {
            var values = inputs.ToDictionary(p => p.Key, p => p.Value is ComboBox combo ? combo.SelectedItem?.ToString() ?? "" : ((TextBox)p.Value).Text); Catalog.Validate(command, values);
            CleanupItem[]? preview = null; if (command.Id == "repair.temp") preview = Cleanup.Preview();
            var details = L10n.Consequence(command, language) + (preview == null ? "" : "\n\n" + Json.Write(preview));
            if ((!command.ReadOnly || command.RequiresAdmin) && confirmations && !Confirm(details, command.Risk == "HighRisk" ? command.Id : null)) return;
            var result = await Busy(async token => await engine.Run(new(command.Id, values, true, command.Id, preview), token, Progress()));
            if (result != null) { output!.Text = Render(result); report = new() { Check = command.Id, Language = language, Parameters = values, Results = [result] }; }
        }
        catch (Exception e) { Error(e); }
    }
    private string Render(OperationResult result) => L10n.Status(result.Status, language) + " | " + result.DurationMs + " ms\n" + result.Detail + "\n\n" + string.Join("\n\n", result.Rows.Select(row => string.Join("\n", row.Where(p => p.Key != "_key").Select(p => p.Key + ": " + p.Value))));
    private sealed class UiProgress(Action<OperationProgress> report) : IProgress<OperationProgress> { public void Report(OperationProgress value) => report(value); }
    private IProgress<OperationProgress> Progress() => new UiProgress(p => Dispatcher.BeginInvoke(() => { if (operation == null) return; status.Text = p.CommandId + " | " + T("Running"); if (output != null && p.Message != "Running") { if (output.Text.Length > 200000) output.Text = output.Text[^100000..]; output.AppendText(p.Message); output.ScrollToEnd(); } }));
    private async Task<TValue?> Busy<TValue>(Func<CancellationToken, Task<TValue>> work) where TValue : class
    {
        if (operation != null) return null; operation = new(); navigationTree.IsEnabled = false; if (commandList != null) commandList.IsEnabled = false; search.IsEnabled = false; var enabled = runButtons.ToDictionary(b => b, b => b.IsEnabled); foreach (var button in runButtons) button.IsEnabled = false; foreach (var pair in cancelButtons) pair.Key.IsEnabled = pair.Value; status.Text = T("Running");
        try { return await Task.Run(() => work(operation.Token)); }
        catch (OperationCanceledException) { status.Text = T("Cancelled"); return null; }
        catch (Exception e) { Error(e); return null; }
        finally { operation.Dispose(); operation = null; navigationTree.IsEnabled = true; if (commandList != null) commandList.IsEnabled = true; search.IsEnabled = true; foreach (var pair in enabled) pair.Key.IsEnabled = pair.Value; foreach (var button in cancelButtons.Keys) button.IsEnabled = false; if (status.Text.Contains(T("Running"))) status.Text = T("Ready"); }
    }
    private async Task CompleteOperation(Func<CancellationToken, Task<OperationResult>> work) { var result = await Busy(work); if (result != null) status.Text = L10n.Status(result.Status, language) + (result.ExitCode.HasValue ? " | Exit code: " + result.ExitCode : ""); }
    private bool Confirm(string message, string? typed)
    {
        var dialog = new Window { Owner = this, Title = T("Confirmation"), Width = 620, Height = 430, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Background, Foreground = Foreground, FontFamily = FontFamily };
        foreach (var key in Resources.Keys) dialog.Resources[key] = Resources[key];
        var panel = new StackPanel { Margin = new Thickness(16) }; panel.Children.Add(new ScrollViewer { Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, MaxHeight = 230, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }); TextBox? entry = null;
        if (typed != null) entry = TextField(panel, "Type command ID to confirm");
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) }; buttons.Children.Add(Button("Run", () => { if (typed == null || entry!.Text == typed) dialog.DialogResult = true; else { entry!.BorderBrush = Brushes.Red; entry.Focus(); } })); buttons.Children.Add(Button("Cancel", () => dialog.DialogResult = false)); panel.Children.Add(buttons); dialog.Content = panel; dialog.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) dialog.DialogResult = false; }; return dialog.ShowDialog() == true;
    }
    private void Checks()
    {
        selected = null; var panel = Page("Checks"); panel.Children.Add(Label("Batch checks run read-only diagnostics. Reports are saved only when you export."));
        var target = TextField(panel, "Target host"); panel.Children.Add(Label("Select additional read-only diagnostics")); var extras = new ListBox { SelectionMode = SelectionMode.Multiple, MaxHeight = 170, ItemsSource = Catalog.Commands.Where(c => c.ReadOnly).Select(c => c.Id).ToArray() }; panel.Children.Add(extras);
        var actions = new WrapPanel { Margin = new Thickness(0, 12, 0, 12) };
        async Task Run(string check) { var host = target.Text; var additional = extras.SelectedItems.Cast<string>().ToArray(); var completed = await Busy(token => Reports.Run(engine, check, host == "" ? null : host, additional, language, token, Progress())); if (completed != null) { report = completed; output!.Text = string.Join("\n\n", report.Results.Select(Render)); } }
        actions.Children.Add(Button("General check", () => _ = Run("general"), true)); actions.Children.Add(Button("Network check", () => _ = Run("network"), true)); actions.Children.Add(CancelButton()); panel.Children.Add(actions); AddExports(panel); output = OutputBox(); panel.Children.Add(output);
    }
    private void AddExports(StackPanel panel) { var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 12) }; foreach (var format in new[] { "json", "html" }) actions.Children.Add(Button("Export " + format.ToUpperInvariant(), () => { if (report == null) throw new InvalidOperationException(T("No report loaded")); var dialog = new SaveFileDialog { Filter = format.ToUpperInvariant() + "|*." + format, FileName = "TOOLX-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "." + format }; if (dialog.ShowDialog() == true) { Reports.Export(report, dialog.FileName, format); status.Text = dialog.FileName; } })); panel.Children.Add(actions); }
    private void ReportPage()
    {
        var panel = Page("Reports");
        panel.Children.Add(Button("Open report", () => { var path = PickJson(); if (path != null) { report = Reports.Load(path); ReportPage(); } }));
        AddExports(panel);
        panel.Children.Add(new TextBox { IsReadOnly = true, Text = report == null ? T("No report loaded") : string.Join("\n\n", report.Results.Select(Render)), TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), MinHeight = 220, MaxHeight = 500, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }
    private string? PickJson() { var dialog = new OpenFileDialog { Filter = "JSON|*.json" }; return dialog.ShowDialog() == true ? dialog.FileName : null; }
    private void ComparePage()
    {
        var panel = Page("Compare"); panel.Children.Add(Button("Before", () => { var path = PickJson(); if (path != null) { before = Reports.Load(path); ComparePage(); } })); panel.Children.Add(Label(before?.CreatedUtc.ToString("O") ?? "No report loaded")); panel.Children.Add(Button("After", () => { var path = PickJson(); if (path != null) { after = Reports.Load(path); ComparePage(); } })); panel.Children.Add(Label(after?.CreatedUtc.ToString("O") ?? "No report loaded"));
        var grid = new DataGrid { AutoGenerateColumns = true, IsReadOnly = true, CanUserAddRows = false, MinHeight = 200, MaxHeight = 450 }; panel.Children.Add(Button("Compare", () => { if (before == null || after == null) throw new InvalidOperationException(T("No report loaded")); grid.ItemsSource = Reports.Compare(before, after); })); panel.Children.Add(grid);
    }
    private void ScriptsPage()
    {
        var panel = Page("Scripts"); panel.Children.Add(Label(language == "id" ? "Skrip memakai izin Windows prosesnya, termasuk administrator bila diwariskan. Skrip bukan sandbox. Policy tetap berlaku." : "Scripts use their Windows process permissions, including inherited elevation. They are not sandboxed. Policy still applies."));
        foreach (var script in scripts.Discover()) { var row = new StackPanel { Margin = new Thickness(0, 8, 0, 8) }; row.Children.Add(Label(script.Metadata.Name ?? Path.GetFileName(script.Path))); row.Children.Add(Label(script.UnavailableReason ?? script.Metadata.Description ?? script.Path)); var button = Button("Run", () => { if (confirmations && !Confirm(script.Path + "\n" + (script.Metadata.Description ?? "") + "\nAdministrator: " + (script.Metadata.RequiresAdmin || Security.IsAdmin), "yes")) return; _ = CompleteOperation(async token => { var code = await scripts.Run(script, true, token); return new OperationResult { CommandId = script.Path, ExitCode = code, Status = code == 0 ? OperationStatus.Succeeded : OperationStatus.Failed }; }); }, true); button.IsEnabled = script.UnavailableReason == null; row.Children.Add(button); panel.Children.Add(row); }
    }
    private void ImportPage()
    {
        var panel = Page("Import"); var source = TextField(panel, "File / HTTPS URL"); panel.Children.Add(Button("Import local file", () => { var dialog = new OpenFileDialog { Filter = "Scripts / ZIP|*.ps1;*.bat;*.cmd;*.zip" }; if (dialog.ShowDialog() == true) source.Text = dialog.FileName; })); var folder = TextField(panel, "Destination folder"); var hash = TextField(panel, "Optional SHA256"); var overwrite = new CheckBox { Content = T("Overwrite existing"), Margin = new Thickness(0, 12, 0, 12) }; panel.Children.Add(overwrite);
        panel.Children.Add(Button("Import", () => { var path = source.Text; var destination = folder.Text; var sha = hash.Text; var replace = overwrite.IsChecked == true; _ = CompleteOperation(async token => { await scripts.Import(path, destination, sha == "" ? null : sha, replace, token); return new OperationResult { Status = OperationStatus.Succeeded }; }); }, true));
    }
    private void SettingsPage() { var panel = Page("Settings"); panel.Children.Add(Label("Action confirmations")); panel.Children.Add(Label(confirmations ? "Confirmations are ON" : "Confirmations are OFF")); panel.Children.Add(Button(confirmations ? "Disable confirmations" : "Enable confirmations", () => { if (confirmations && !Confirm(T("Type OFF to disable confirmations for this session. Actions may delete files, change security settings, or restart Windows."), "OFF")) return; confirmations = !confirmations; Build(); })); }
    private void Error(Exception e) { status.Text = T("Operation failed"); MessageBox.Show(this, e.Message, "TOOLX", MessageBoxButton.OK, MessageBoxImage.Error); }
}
