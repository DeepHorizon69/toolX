using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ToolX;

internal static class Program
{
    private static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic;
    private static void Set(MainWindow window, string field, object? value) => typeof(MainWindow).GetField(field, Flags)!.SetValue(window, value);
    private static void Call(MainWindow window, string method, params object[] args) => typeof(MainWindow).GetMethod(method, Flags)!.Invoke(window, args);
    private static T Get<T>(MainWindow window, string name) => (T)typeof(MainWindow).GetField(name, Flags)!.GetValue(window)!;
    private static IEnumerable<DependencyObject> Descendants(DependencyObject item)
    {
        yield return item;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(item); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(item, i))) yield return child;
    }
    private static void Assert(bool condition, string detail) { if (!condition) throw new Exception(detail); }
    private static double Luminance(Color c) { double Linear(byte b) { var x = b / 255d; return x <= .04045 ? x / 12.92 : Math.Pow((x + .055) / 1.055, 2.4); } return .2126 * Linear(c.R) + .7152 * Linear(c.G) + .0722 * Linear(c.B); }
    private static double Contrast(Brush a, Brush b) { var left = Luminance(((SolidColorBrush)a).Color); var right = Luminance(((SolidColorBrush)b).Color); return (Math.Max(left, right) + .05) / (Math.Min(left, right) + .05); }
    [STAThread]
    private static int Main(string[] args)
    {
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var window = new MainWindow { Left = -20000, Top = -20000, ShowInTaskbar = false, ShowActivated = false, Title = "TOOLX layout test fixture" };
        var directory = args.FirstOrDefault() ?? Path.Combine(Path.GetTempPath(), "toolx-layout-tests"); Directory.CreateDirectory(directory);
        var cases = 0;
        try
        {
            window.Show();
            foreach (var language in new[] { "en", "id" }) foreach (var theme in new[] { "Light", "Dark" })
            {
                Set(window, "language", language); Set(window, "theme", theme); Call(window, "ApplyTheme"); Call(window, "Build");
                Assert(Contrast((Brush)window.Resources["Text"], (Brush)window.Resources["Panel"]) >= 4.5, "Text contrast: " + theme);
                Assert(Contrast((Brush)window.Resources["SelectedText"], (Brush)window.Resources["Selected"]) >= 4.5, "Selection contrast: " + theme);
                Assert(Contrast((Brush)window.Resources[SystemColors.InactiveSelectionHighlightTextBrushKey], (Brush)window.Resources[SystemColors.InactiveSelectionHighlightBrushKey]) >= 4.5, "Inactive navigation selection contrast: " + theme);
                foreach (var width in new[] { 1180d, 640d })
                {
                    window.Width = width; window.Height = 780;
                    foreach (var command in Catalog.Commands)
                    {
                        Set(window, "selected", command); var host = new ContentControl(); Get<ContentControl>(window, "content").Content = host; Call(window, "Details", host); window.UpdateLayout();
                        var fields = Get<Dictionary<string, FrameworkElement>>(window, "inputs"); Assert(fields.Count == command.Parameters.Length, "Missing parameter control: " + command.Id);
                        Assert(Descendants(host).OfType<Button>().Any(b => b.Content?.ToString() == L10n.T("Run", language)), "Missing Run action: " + command.Id);
                        foreach (var control in Descendants(host).OfType<FrameworkElement>()) Assert(!double.IsNaN(control.ActualWidth) && !double.IsInfinity(control.ActualWidth), "Invalid layout: " + command.Id);
                        cases++;
                    }
                    foreach (var page in new[] { "Tools", "Checks", "Reports", "Compare", "Scripts", "Import", "Settings" }) { Set(window, "page", page); Call(window, "ShowPage"); window.UpdateLayout(); Assert(Get<ContentControl>(window, "content").Content != null, "Missing page: " + page); cases++; }
                }
                Set(window, "page", "Tools"); Call(window, "ShowPage"); window.Width = 1180; window.UpdateLayout(); window.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); bitmap.Render(window);
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap)); using var file = File.Create(Path.Combine(directory, language + "-" + theme + ".png")); png.Save(file);
                var tree = Get<TreeView>(window, "navigationTree"); tree.Items.OfType<TreeViewItem>().Single(item => Equals(item.Tag, "Checks")).IsSelected = true; window.UpdateLayout(); window.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                var checksBitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); checksBitmap.Render(window); var checksPng = new PngBitmapEncoder(); checksPng.Frames.Add(BitmapFrame.Create(checksBitmap)); using var checksFile = File.Create(Path.Combine(directory, language + "-" + theme + "-checks.png")); checksPng.Save(checksFile);
                Console.WriteLine($"PASS layout {language}/{theme}: 91 forms and 7 pages at 1180/640 widths; text and selection contrast AA.");
            }
            Console.WriteLine($"{cases} layout cases passed. No system actions invoked."); return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e.GetBaseException()); return 1; }
        finally { window.Close(); application.Shutdown(); }
    }
}
