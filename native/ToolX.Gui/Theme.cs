using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;

internal static class Theme
{
    private static readonly string Ns = "xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'";
    private static Setter Resource(DependencyProperty property, string key) => new(property, new DynamicResourceExtension(key));
    public static void Apply(Window window, bool dark)
    {
        Brush B(string color) => new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        var high = SystemParameters.HighContrast; var resources = window.Resources;
        resources["Background"] = high ? SystemColors.WindowBrush : B(dark ? "#202428" : "#ECEFF2");
        resources["Panel"] = high ? SystemColors.WindowBrush : B(dark ? "#292E33" : "#FFFFFF");
        resources["Text"] = high ? SystemColors.WindowTextBrush : B(dark ? "#F0F2F4" : "#20262C");
        resources["Line"] = high ? SystemColors.WindowTextBrush : B(dark ? "#929DA6" : "#78838E");
        resources["Accent"] = high ? SystemColors.HighlightBrush : B(dark ? "#9CCAFF" : "#174F82");
        resources["Selected"] = high ? SystemColors.HighlightBrush : B(dark ? "#385878" : "#D3E5F6");
        resources["SelectedText"] = high ? SystemColors.HighlightTextBrush : resources["Text"];
        resources[SystemColors.HighlightBrushKey] = resources["Selected"];
        resources[SystemColors.HighlightTextBrushKey] = resources["SelectedText"];
        resources[SystemColors.InactiveSelectionHighlightBrushKey] = resources["Selected"];
        resources[SystemColors.InactiveSelectionHighlightTextBrushKey] = resources["SelectedText"];
        resources[SystemColors.ControlBrushKey] = resources["Panel"];
        resources[SystemColors.ControlTextBrushKey] = resources["Text"];
        resources[SystemColors.WindowBrushKey] = resources["Panel"];
        resources[SystemColors.WindowTextBrushKey] = resources["Text"];
        window.SetResourceReference(Control.BackgroundProperty, "Background"); window.SetResourceReference(Control.ForegroundProperty, "Text");
        foreach (var type in new[] { typeof(TextBox), typeof(ComboBox), typeof(ComboBoxItem), typeof(ListBox), typeof(ListBoxItem), typeof(TreeView), typeof(TreeViewItem), typeof(DataGrid), typeof(DataGridRow), typeof(DataGridCell), typeof(DataGridColumnHeader), typeof(Button), typeof(CheckBox), typeof(Label), typeof(StatusBar) })
        {
            var style = new Style(type); style.Setters.Add(Resource(Control.ForegroundProperty, "Text")); style.Setters.Add(Resource(Control.BackgroundProperty, "Panel")); style.Setters.Add(Resource(Control.BorderBrushProperty, "Line")); style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(7, 4, 7, 4)));
            if (type == typeof(TreeViewItem)) style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(2)));
            if (type == typeof(DataGrid)) { style.Setters.Add(Resource(DataGrid.RowBackgroundProperty, "Panel")); style.Setters.Add(Resource(DataGrid.AlternatingRowBackgroundProperty, "Background")); style.Setters.Add(Resource(DataGrid.HorizontalGridLinesBrushProperty, "Line")); style.Setters.Add(Resource(DataGrid.VerticalGridLinesBrushProperty, "Line")); }
            if (type == typeof(Button))
            {
                style.Setters.Add(new Setter(Control.MinHeightProperty, 32d)); style.Setters.Add(new Setter(Control.CursorProperty, Cursors.Hand));
                style.Setters.Add(new Setter(Control.TemplateProperty, XamlReader.Parse("<ControlTemplate " + Ns + " TargetType='Button'><Border x:Name='frame' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' Padding='{TemplateBinding Padding}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='frame' Property='Background' Value='{DynamicResource Selected}'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='frame' Property='BorderThickness' Value='2'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='frame' Property='BorderBrush' Value='{DynamicResource Accent}'/><Setter TargetName='frame' Property='BorderThickness' Value='2'/></Trigger></ControlTemplate.Triggers></ControlTemplate>")));
            }
            if (type == typeof(ComboBox)) style.Setters.Add(new Setter(Control.TemplateProperty, XamlReader.Parse("<ControlTemplate " + Ns + " TargetType='ComboBox'><Grid><ToggleButton Focusable='False' IsChecked='{Binding IsDropDownOpen,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}'><ToggleButton.Template><ControlTemplate TargetType='ToggleButton'><Border Background='{DynamicResource Panel}' BorderBrush='{DynamicResource Line}' BorderThickness='1'><TextBlock Text='▾' HorizontalAlignment='Right' Margin='4' Foreground='{DynamicResource Text}'/></Border></ControlTemplate></ToggleButton.Template></ToggleButton><ContentPresenter Margin='7,4,22,4' IsHitTestVisible='False' Content='{TemplateBinding SelectionBoxItem}'/><Popup x:Name='PART_Popup' IsOpen='{TemplateBinding IsDropDownOpen}' Placement='Bottom' AllowsTransparency='True' Focusable='False'><Border Background='{DynamicResource Panel}' BorderBrush='{DynamicResource Line}' BorderThickness='1' MinWidth='100'><ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation='Contained'/></ScrollViewer></Border></Popup></Grid></ControlTemplate>")));
            var property = type == typeof(DataGridRow) ? DataGridRow.IsSelectedProperty : type == typeof(DataGridCell) ? DataGridCell.IsSelectedProperty : type == typeof(TreeViewItem) ? TreeViewItem.IsSelectedProperty : typeof(ListBoxItem).IsAssignableFrom(type) ? ListBoxItem.IsSelectedProperty : null;
            if (property != null) { var trigger = new Trigger { Property = property, Value = true }; trigger.Setters.Add(Resource(Control.BackgroundProperty, "Selected")); trigger.Setters.Add(Resource(Control.ForegroundProperty, "SelectedText")); style.Triggers.Add(trigger); }
            var focus = new Trigger { Property = UIElement.IsKeyboardFocusWithinProperty, Value = true }; focus.Setters.Add(Resource(Control.BorderBrushProperty, "Accent")); focus.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(2))); style.Triggers.Add(focus);
            var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false }; disabled.Setters.Add(new Setter(UIElement.OpacityProperty, .55)); style.Triggers.Add(disabled); resources[type] = style;
        }
    }
}
