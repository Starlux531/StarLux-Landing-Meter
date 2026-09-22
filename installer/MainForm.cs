using System.Drawing.Drawing2D;
using System.Text.Json;

namespace StarLux.Installer;

public class BluePanel : Panel
{
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Color TopColor { get; set; } = Color.FromArgb(22, 56, 91);
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Color BottomColor { get; set; } = Color.FromArgb(13, 32, 58);
    public BluePanel() { DoubleBuffered = true; }
    protected override void OnPaintBackground(PaintEventArgs e)
    { if (Width < 1 || Height < 1) return; using var b = new LinearGradientBrush(ClientRectangle, TopColor, BottomColor, 30f); e.Graphics.FillRectangle(b, ClientRectangle); }
}
public sealed class StateCard : BluePanel
{
    readonly Label heading = new() { Dock = DockStyle.Top, Height = 28, ForeColor = Color.FromArgb(157, 193, 226), BackColor = Color.Transparent };
    readonly Label value = new() { Dock = DockStyle.Top, Height = 37, Font = new("Microsoft YaHei UI", 13, FontStyle.Bold), AutoEllipsis = true, BackColor = Color.Transparent };
    readonly Label caption = new() { Dock = DockStyle.Fill, ForeColor = Color.FromArgb(190, 216, 241), BackColor = Color.Transparent };
    public bool Flash { get; private set; }
    Color tone;
    public StateCard() { Dock = DockStyle.Fill; Padding = new(16, 13, 16, 10); Margin = new(0, 0, 10, 0); Controls.Add(caption); Controls.Add(value); Controls.Add(heading); }
    public void Set(string title, string text, string detail, Color color, bool flash = false) { heading.Text = title; value.Text = text; caption.Text = detail; tone = color; Flash = flash; value.ForeColor = color; }
    public void Pulse(bool bright) { value.ForeColor = Flash ? (bright ? Color.FromArgb(255, 87, 107) : Color.FromArgb(168, 47, 69)) : tone; }
    internal string VisibleText => heading.Text + " " + value.Text + " " + caption.Text;
}
public sealed partial class MainForm : Form
{
    readonly string baseDir = AppContext.BaseDirectory;
    readonly string preferenceFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StarLux_LMM_Installer", "preferences.json");
    readonly ComboBox target = Combo(false), releases = Combo(true), sources = Combo(true);
    readonly Button language = MakeButton(), browse = MakeButton(), detect = MakeButton(), refresh = MakeButton(), install = MakeButton(true), repair = MakeButton(), uninstall = MakeButton(), restore = MakeButton(), cancel = MakeButton(), selfUpdate = MakeButton();
    readonly Label title = Label(22, true), subtitle = Label(10), pathTitle = Label(11, true), versionTitle = Label(11, true), status = Label(10), selection = Label(10), stage = Label(10), foot = Label(9);
    readonly StateCard pluginCard = new(), healthCard = new(), installerCard = new();
    readonly TextBox logBox = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, BackColor = Color.FromArgb(10, 25, 44), ForeColor = Color.FromArgb(158, 197, 230), Margin = new(0, 10, 0, 0) };
    readonly ProgressBar progress = new() { Dock = DockStyle.Fill, Height = 8, Margin = new(0, 8, 0, 6) };
    readonly System.Windows.Forms.Timer blink = new() { Interval = 600 }, inspectDelay = new() { Interval = 400 };
    readonly List<Release> local;
    List<Release> online = [];
    InstallerCatalog? installerCatalog;
    Diagnosis diagnosis = new();
    CancellationTokenSource? operation, catalogCancellation;
    bool busy, applying, checking, pulse, closingForUpdate, pluginOnlineVerified;
    int inspectGeneration;
    readonly bool preview;
    public static readonly Color Good = Color.FromArgb(87, 224, 171), Warning = Color.FromArgb(255, 197, 104), Neutral = Color.FromArgb(138, 201, 255), Alert = Color.FromArgb(255, 87, 107);
    static ComboBox Combo(bool list) => new() { DropDownStyle = list ? ComboBoxStyle.DropDownList : ComboBoxStyle.DropDown, Dock = DockStyle.Fill, BackColor = Color.FromArgb(21, 47, 76), ForeColor = Color.FromArgb(222, 239, 255), FlatStyle = FlatStyle.Flat, Margin = new(0, 7, 8, 4), DropDownWidth = 920 };
    static Label Label(float size, bool bold = false) => new() { AutoSize = true, BackColor = Color.Transparent, ForeColor = Color.FromArgb(208, 229, 249), Font = new("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular), Margin = new(0, 5, 0, 5) };
    static Button MakeButton(bool primary = false)
    {
        var b = new Button { AutoSize = true, MinimumSize = new(116, 39), Padding = new(9, 3, 9, 3), FlatStyle = FlatStyle.Flat, BackColor = primary ? Color.FromArgb(67, 156, 231) : Color.FromArgb(28, 66, 104), ForeColor = Color.FromArgb(238, 247, 255), Cursor = Cursors.Hand, Margin = new(0, 0, 8, 0) };
        b.FlatAppearance.BorderColor = Color.FromArgb(70, 118, 163); b.FlatAppearance.MouseOverBackColor = Color.FromArgb(48, 111, 167); return b;
    }
    static FlowLayoutPanel Flow(params Control[] items) { var f = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = new(0, 8, 0, 8) }; f.Controls.AddRange(items); return f; }
    public MainForm(bool preview = false)
    {
        this.preview = preview; Font = new("Microsoft YaHei UI", 10); AutoScaleMode = AutoScaleMode.Dpi; DoubleBuffered = true;
        ClientSize = new(1120, 870); MinimumSize = new(1030, 810); StartPosition = FormStartPosition.CenterScreen;
        var background = new BluePanel { Dock = DockStyle.Fill, Padding = new(28, 22, 28, 20), TopColor = Color.FromArgb(8, 22, 42), BottomColor = Color.FromArgb(44, 103, 155) };
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 1, RowCount = 13 };
        for (int i = 0; i < 13; i++) body.RowStyles.Add(new(i == 11 ? SizeType.Percent : SizeType.AutoSize, i == 11 ? 100 : 0));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, BackColor = Color.Transparent, Margin = Padding.Empty };
        header.ColumnStyles.Add(new(SizeType.Percent, 100)); header.ColumnStyles.Add(new(SizeType.AutoSize)); header.Controls.Add(title, 0, 0); header.Controls.Add(language, 1, 0);
        body.Controls.Add(header, 0, 0); body.Controls.Add(subtitle, 0, 1);
        var cards = new TableLayoutPanel { Dock = DockStyle.Fill, Height = 143, ColumnCount = 3, Margin = new(0, 17, 0, 13), BackColor = Color.Transparent };
        for (int i = 0; i < 3; i++) cards.ColumnStyles.Add(new(SizeType.Percent, 33.333f)); cards.Controls.Add(pluginCard, 0, 0); cards.Controls.Add(healthCard, 1, 0); cards.Controls.Add(installerCard, 2, 0); installerCard.Margin = Padding.Empty;
        body.Controls.Add(cards, 0, 2); body.Controls.Add(pathTitle, 0, 3);
        var paths = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3, BackColor = Color.Transparent, Margin = Padding.Empty };
        paths.ColumnStyles.Add(new(SizeType.Percent, 100)); paths.ColumnStyles.Add(new(SizeType.AutoSize)); paths.ColumnStyles.Add(new(SizeType.AutoSize)); paths.Controls.Add(target, 0, 0); paths.Controls.Add(browse, 1, 0); paths.Controls.Add(detect, 2, 0); body.Controls.Add(paths, 0, 4);
        status.MaximumSize = new(1010, 70); body.Controls.Add(status, 0, 5); body.Controls.Add(versionTitle, 0, 6); body.Controls.Add(releases, 0, 7);
        sources.Dock = DockStyle.None; sources.Width = 173; sources.DropDownWidth = 200; body.Controls.Add(Flow(sources, refresh, selfUpdate, selection), 0, 8);
        body.Controls.Add(Flow(install, repair, uninstall, restore, cancel), 0, 9); body.Controls.Add(progress, 0, 10); body.Controls.Add(logBox, 0, 11); body.Controls.Add(Flow(stage, foot), 0, 12); background.Controls.Add(body); Controls.Add(background);
        foreach (var combo in new[] { releases, sources })
        {
            combo.DrawMode = DrawMode.OwnerDrawFixed; combo.ItemHeight = 29;
            combo.DrawItem += (_, e) => { using var brush = new SolidBrush((e.State & DrawItemState.Selected) != 0 ? Color.FromArgb(39, 88, 136) : combo.BackColor); e.Graphics.FillRectangle(brush, e.Bounds); var item = e.Index >= 0 ? combo.Items[e.Index] : null; TextRenderer.DrawText(e.Graphics, item is Release r ? U.ReleaseName(r) : item?.ToString() ?? "", combo.Font, Rectangle.Inflate(e.Bounds, -6, 0), combo.ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis); };
        }
        if (!preview) LoadPreferences(); local = Core.LocalReleases(baseDir, Log); ApplyLanguage(); LoadReleases();
        target.TextChanged += (_, _) => { inspectGeneration++; inspectDelay.Stop(); inspectDelay.Start(); };
        inspectDelay.Tick += async (_, _) => { inspectDelay.Stop(); await InspectTarget(); };
        releases.SelectedIndexChanged += (_, _) => ShowSelection();
        language.Click += async (_, _) => { U.Language = U.Language == "zh" ? "en" : "zh"; logBox.Clear(); ApplyLanguage(); SavePreferences(); await InspectTarget(); };
        browse.Click += async (_, _) => { using var d = new FolderBrowserDialog { Description = U.T("选择包含 X-Plane.exe 的根目录", "Select the folder containing X-Plane.exe"), UseDescriptionForTitle = true, SelectedPath = target.Text }; if (d.ShowDialog(this) == DialogResult.OK) { target.Text = d.SelectedPath; SavePreferences(); await InspectTarget(); } };
        detect.Click += async (_, _) => await Detect(); refresh.Click += async (_, _) => await CheckOnline(); install.Click += async (_, _) => await Install(false); repair.Click += async (_, _) => await Install(true);
        uninstall.Click += async (_, _) => await Uninstall(); restore.Click += async (_, _) => await Restore(); selfUpdate.Click += async (_, _) => await UpdateInstaller(); cancel.Click += (_, _) => operation?.Cancel();
        blink.Tick += (_, _) => { pulse = !pulse; pluginCard.Pulse(pulse); installerCard.Pulse(pulse); }; blink.Start();
        Shown += async (_, _) => { if (!preview) { await Detect(); await CheckOnline(); } };
        FormClosing += (_, e) => { if (busy && !closingForUpdate) { e.Cancel = true; Prompt(U.T("请等待", "Please wait"), applying ? U.T("正在写入或恢复文件，请等待操作完成。", "Files are being applied or restored. Wait for completion.") : U.T("请先取消下载并等待结束。", "Cancel the download and wait for it to stop.")); } else catalogCancellation?.Cancel(); };
        FormClosed += (_, _) => { blink.Dispose(); inspectDelay.Dispose(); };
    }
    void ApplyLanguage()
    {
        Text = U.T("StarLux LMM 安装器 v", "StarLux LMM Installer v") + SelfUpdater.DisplayVersion; title.Text = U.T("STARLUX  安装器", "STARLUX  INSTALLER"); subtitle.Text = "v" + SelfUpdater.DisplayVersion + U.T("  /  安装、更新与维护，一处完成", "  /  Install, update and maintain in one place"); language.Text = U.Language == "zh" ? "English" : "简体中文";
        pathTitle.Text = U.T("01   选择模拟器", "01   YOUR SIMULATOR"); versionTitle.Text = U.T("02   选择插件版本", "02   PLUGIN VERSION"); browse.Text = U.T("浏览目录", "Browse"); detect.Text = U.T("重新检测", "Detect"); refresh.Text = U.T("检查全部更新", "Check updates"); selfUpdate.Text = U.T("更新安装器", "Update installer"); install.Text = U.T("安装 / 更新插件", "Install / update"); repair.Text = U.T("修复插件", "Repair plugin"); uninstall.Text = U.T("卸载插件", "Uninstall"); restore.Text = U.T("恢复备份", "Restore backup"); cancel.Text = U.T("取消下载", "Cancel download");
        var index = sources.SelectedIndex; sources.Items.Clear(); sources.Items.AddRange([U.T("自动切换下载源", "Automatic source"), U.T("优先 Gitee", "Prefer Gitee"), U.T("优先 GitHub", "Prefer GitHub")]); sources.SelectedIndex = Math.Max(0, index);
        stage.Text = U.T("就绪", "Ready"); foot.Text = U.T("操作前请退出 X-Plane · 飞行记录始终保留", "Close X-Plane before changes · Flight reports are always preserved"); releases.Invalidate(); UpdateCards(); ShowSelection();
    }
    void LoadPreferences() { try { if (File.Exists(preferenceFile)) { var p = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(preferenceFile)); target.Text = p?.GetValueOrDefault("target") ?? ""; var lang = p?.GetValueOrDefault("language"); if (lang is "zh" or "en") U.Language = lang; } } catch { } }
    void SavePreferences() { if (preview) return; try { Directory.CreateDirectory(Path.GetDirectoryName(preferenceFile)!); File.WriteAllText(preferenceFile, JsonSerializer.Serialize(new { target = target.Text, language = U.Language })); } catch { } }
    void Log(string text) { if (IsDisposed) return; if (InvokeRequired) { BeginInvoke(() => Log(text)); return; } logBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {text}\r\n"); }
    void Percent(int value) { if (InvokeRequired) { BeginInvoke(() => Percent(value)); return; } progress.Value = Math.Clamp(value, 0, 100); stage.Text = U.T(applying ? "正在应用 " : "正在下载 ", applying ? "Applying " : "Downloading ") + value + "%"; }
    async Task Detect()
    {
        detect.Enabled = false;
        try { var found = await Task.Run(() => Core.Discover(baseDir)); if (busy || IsDisposed) return; var previous = target.Text; target.Items.Clear(); target.Items.AddRange(found.Cast<object>().ToArray()); target.Text = Core.IsXPlane(previous) ? previous : found.Count == 1 ? found[0] : ""; Log(U.T("检测到模拟器目录：", "Simulator folders detected: ") + found.Count); await InspectTarget(); }
        catch (Exception e) { Log(e.Message); }
        finally { if (!IsDisposed) detect.Enabled = !busy; }
    }
    async Task InspectTarget()
    {
        var generation = ++inspectGeneration; var path = target.Text.Trim();
        try { var result = await Task.Run(() => Core.Diagnose(path)); if (generation != inspectGeneration || IsDisposed) return; diagnosis = result; if(diagnosis.Issues.Count > 2) Log(diagnosis.Describe()); }
        catch (Exception e) { if (generation != inspectGeneration || IsDisposed) return; diagnosis = new(); Log(e.Message); }
        UpdateCards(); SetBusy(busy);
    }
    void LoadReleases() { var selected = releases.SelectedItem as Release; releases.Items.Clear(); releases.Items.AddRange(Core.LabelReleases(local.Concat(online)).Cast<object>().ToArray()); if (selected != null && releases.Items.Contains(selected)) releases.SelectedItem = selected; else if (releases.Items.Count > 0) releases.SelectedItem = Core.RepairRelease(releases.Items.Cast<Release>(), diagnosis) ?? releases.Items[0]; ShowSelection(); }
    internal void UpdateCards()
    {
        var latest = online.FirstOrDefault(); var hasUpdate = latest != null && diagnosis.Version != "" && Core.CompareVersion(latest.Version, diagnosis.Version) > 0; var isLatest = pluginOnlineVerified && latest != null && diagnosis.Version != "" && Core.CompareVersion(latest.Version, diagnosis.Version) == 0;
        pluginCard.Set(U.T("插件更新", "PLUGIN UPDATE"), hasUpdate ? U.T("有新版本  ", "Update available  ") + latest!.Version : isLatest ? U.T("已是最新版本", "Up to date") : diagnosis.HasPlugin ? U.T("已安装  ", "Installed  ") + diagnosis.Version : U.T("尚未安装", "Not installed"), checking ? U.T("正在检查在线版本…", "Checking online releases…") : latest != null ? U.T("线上版本：", "Online version: ") + latest.Version : U.T("在线状态未知，仍可使用本地包", "Online status unknown; local packages work"), hasUpdate ? Alert : isLatest ? Good : Neutral, hasUpdate);
        healthCard.Set(U.T("插件状态", "PLUGIN HEALTH"), diagnosis.Verified ? U.T("文件完整 · 兼容", "Verified & compatible") : diagnosis.HasPlugin ? U.T("需要检查 / 修复", "Check / repair needed") : U.T("等待安装", "Ready to install"), diagnosis.SimulatorVersion == "" ? U.T("等待识别 X-Plane 版本", "X-Plane version not identified") : "X-Plane " + diagnosis.SimulatorVersion + " · " + (diagnosis.HasFlyWithLua ? "FlyWithLua ✓" : U.T("缺少 FlyWithLua", "FlyWithLua missing")), diagnosis.Verified ? Good : diagnosis.HasPlugin ? Warning : Neutral);
        var updateRelease = installerCatalog?.Releases.FirstOrDefault(); var newer = updateRelease != null && Core.CompareVersion(updateRelease.Version, SelfUpdater.Version) > 0; var current = installerCatalog?.Available == true && updateRelease != null && Core.CompareVersion(updateRelease.Version, SelfUpdater.Version) == 0;
        installerCard.Set(U.T("安装器更新", "INSTALLER UPDATE"), newer ? U.T("有新版本  ", "Update available  ") + updateRelease!.Version : current ? U.T("已是最新版本", "Up to date") : "v" + SelfUpdater.DisplayVersion, checking ? U.T("正在检查独立更新通道…", "Checking installer release channel…") : updateRelease != null ? U.T("当前版本：", "Current version: ") + SelfUpdater.Version : installerCatalog?.Available == true ? U.T("尚无正式更新包", "No installer release package published") : U.T("更新状态待确认", "Update status unconfirmed"), newer ? Alert : current ? Good : Neutral, newer);
        status.Text = diagnosis.Describe(); if (diagnosis.Issues.Count > 2) status.Text = string.Join("\n", diagnosis.Describe().Split('\n').Take(3)) + U.T("（完整诊断见日志）", " (see log for full diagnosis)");
        selfUpdate.Enabled = !busy && newer; uninstall.Enabled = !busy && diagnosis.HasPlugin; repair.Enabled = !busy && diagnosis.HasPlugin && releases.Items.Count > 0;
    }
    void ShowSelection() { selection.Text = releases.SelectedItem is Release r ? U.Compatibility(r) : U.T("无安装包，请检查更新", "No package; check updates"); install.Enabled = !busy && releases.SelectedItem != null; }
    async Task CheckOnline()
    {
        if (checking || busy) return; checking = true; refresh.Enabled = false; catalogCancellation = new(); UpdateCards();
        try { using var net = new Network(Log); var plugin = net.Catalog(catalogCancellation.Token); var updater = net.InstallerCatalog(catalogCancellation.Token); await Task.WhenAll(plugin, updater); if (IsDisposed) return; pluginOnlineVerified = net.PluginCatalogAvailable; if(pluginOnlineVerified) online = await plugin; var result = await updater; installerCatalog = !result.Available && installerCatalog != null ? new(false, installerCatalog.Releases) : result; if (!busy) LoadReleases(); }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log(e.Message); }
        finally { checking = false; catalogCancellation?.Dispose(); catalogCancellation = null; if (!IsDisposed) { refresh.Enabled = !busy; UpdateCards(); } }
    }
    void SetBusy(bool value) { busy = value; foreach (var c in new Control[] { browse, detect, restore, target, releases, sources, language }) c.Enabled = !value; refresh.Enabled = !value && !checking; cancel.Enabled = value && !applying; UpdateCards(); ShowSelection(); }
    string Preferred => sources.SelectedIndex switch { 1 => "Gitee", 2 => "GitHub", _ => "Auto" };
    DialogResult Prompt(string heading, string text, params (string, DialogResult)[] choices)
    {
        using var d = new Form { Text = heading, Font = Font, ClientSize = new(680, 385), MinimumSize = new(680, 385), StartPosition = FormStartPosition.CenterParent, ShowInTaskbar = false, BackColor = Color.FromArgb(14, 34, 57), ForeColor = Color.FromArgb(223, 239, 252), Padding = new(22) };
        var content = new TextBox { Text = text, Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, BackColor = d.BackColor, ForeColor = d.ForeColor, ScrollBars = ScrollBars.Vertical };
        var row = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Padding = new(0, 16, 0, 0) };
        if (choices.Length == 0) choices = [(U.T("确定", "OK"), DialogResult.OK)]; foreach (var (label, result) in choices.Reverse()) { var b = MakeButton(); b.Text = label; b.DialogResult = result; row.Controls.Add(b); if (result == DialogResult.Cancel) d.CancelButton = b; }
        d.Controls.Add(content); d.Controls.Add(row); return d.ShowDialog(this);
    }
    (string, DialogResult) Yes => (U.T("继续", "Continue"), DialogResult.OK);
    (string, DialogResult) No => (U.T("取消", "Cancel"), DialogResult.Cancel);
    internal void PreviewState(bool updates)
    {
        pluginOnlineVerified = true;
        diagnosis = new() { ValidTarget = true, HasPlugin = true, HasFlyWithLua = true, Verified = true, Version = "1.1.8", SimulatorVersion = "12.4.4" };
        online = [new() { Version = updates ? "1.1.9" : "1.1.8", UiVariant = "sdk440", DefaultLanguage = U.Language, Sources = [new("GitHub", Network.GithubRepo + "/preview")] }];
        installerCatalog = new(true, [new() { Version = updates ? "1.1.0" : SelfUpdater.Version }]); target.Text = @"D:\Games\X-Plane 12"; inspectDelay.Stop(); LoadReleases(); UpdateCards();
    }
    internal string[] CardText => [pluginCard.VisibleText, healthCard.VisibleText, installerCard.VisibleText];
    internal bool[] FlashStates => [pluginCard.Flash, installerCard.Flash];
    internal void PreviewOffline() { pluginOnlineVerified = false; if(installerCatalog != null) installerCatalog = new(false,installerCatalog.Releases); UpdateCards(); }
}
