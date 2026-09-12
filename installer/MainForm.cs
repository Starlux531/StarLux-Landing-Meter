using System.Diagnostics;
using System.Text.Json;

namespace StarLux.Installer;

public sealed class MainForm : Form
{
    readonly string baseDir = AppContext.BaseDirectory;
    readonly ComboBox target = new() { DropDownStyle = ComboBoxStyle.DropDown, Dock = DockStyle.Fill };
    readonly ComboBox releases = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, DropDownWidth = 950 };
    readonly ComboBox sources = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 250 };
    readonly Label status = new() { AutoSize = true, MaximumSize = new(870, 0), ForeColor = Color.FromArgb(26, 68, 78) };
    readonly Label details = new() { AutoSize = true, MaximumSize = new(870, 0) };
    readonly Label update = new() { AutoSize = true, ForeColor = Color.FromArgb(28, 100, 102), Text = "启动后自动检查；离线可用本地版本 / Checks online; bundled version works offline" };
    readonly TextBox logBox = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BackColor = Color.FromArgb(241, 245, 248), BorderStyle = BorderStyle.FixedSingle };
    readonly ProgressBar progress = new() { Dock = DockStyle.Fill };
    readonly Label stage = new() { AutoSize = true, Text = "就绪 / Ready" };
    readonly Button install = Button("安装所选版本 / Install", true);
    readonly Button browse = Button("选择目录 / Browse");
    readonly Button detect = Button("重新检测 / Detect");
    readonly Button refresh = Button("检查更新 / Check updates");
    readonly Button restore = Button("恢复备份 / Restore");
    readonly Button cancel = Button("取消下载 / Cancel");
    CancellationTokenSource? operation;
    CancellationTokenSource? catalogCancellation;
    bool busy, applying, onlineChecking;
    readonly List<Release> local;
    List<Release> online = [];
    readonly string preferenceFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StarLux_LMM_Installer", "preferences.json");
    static Button Button(string text, bool primary = false) => new()
    {
        Text = text, AutoSize = true, MinimumSize = new(145, 40), Padding = new(9, 4, 9, 4),
        FlatStyle = FlatStyle.Flat, BackColor = primary ? Color.FromArgb(25, 99, 106) : Color.White,
        ForeColor = primary ? Color.White : Color.FromArgb(25, 49, 67), Cursor = Cursors.Hand
    };
    static FlowLayoutPanel Flow(params Control[] controls)
    {
        var flow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new(0, 4, 0, 6), WrapContents = true };
        flow.Controls.AddRange(controls); return flow;
    }
    static Label Heading(string text) => new() { Text = text, AutoSize = true, Font = new("Microsoft YaHei UI", 11, FontStyle.Bold), Margin = new(0, 10, 0, 8) };
    public MainForm()
    {
        Text = "StarLux LMM · 安装与更新 / Installer 1.1.8";
        Font = new("Microsoft YaHei UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(980, 810); MinimumSize = new(820, 760); StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(249, 251, 252); Padding = new(24, 15, 24, 18);
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 13 };
        for (int i = 0; i < 13; i++) body.RowStyles.Add(new(i == 11 ? SizeType.Percent : SizeType.AutoSize, i == 11 ? 100 : 0));
        body.Controls.Add(new Label { Text = "STARLUX  /  LANDING METRICS MONITOR", AutoSize = true, ForeColor = Color.FromArgb(25, 99, 106), Font = new("Segoe UI", 19, FontStyle.Bold) }, 0, 0);
        body.Controls.Add(new Label { Text = "便携安装 · 自动识别 · 双源下载 · 安全备份  /  Portable, backed-up installation", AutoSize = true, Margin = new(0, 6, 0, 10) }, 0, 1);
        body.Controls.Add(Heading("01  X-Plane 12 安装位置 / Simulator folder"), 0, 2);
        var pathRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, AutoSize = true };
        pathRow.ColumnStyles.Add(new(SizeType.Percent, 100)); pathRow.ColumnStyles.Add(new(SizeType.AutoSize)); pathRow.ColumnStyles.Add(new(SizeType.AutoSize));
        target.Margin = new(0, 9, 8, 0); pathRow.Controls.Add(target, 0, 0); pathRow.Controls.Add(browse, 1, 0); pathRow.Controls.Add(detect, 2, 0); body.Controls.Add(pathRow, 0, 3);
        body.Controls.Add(status, 0, 4);
        body.Controls.Add(Heading("02  即将安装的版本 / Version to install"), 0, 5);
        body.Controls.Add(releases, 0, 6);
        sources.Items.AddRange(["自动切换 / Auto", "Gitee 优先 / Prefer Gitee", "GitHub 优先 / Prefer GitHub"]); sources.SelectedIndex = 0;
        body.Controls.Add(Flow(sources, refresh, update), 0, 7);
        body.Controls.Add(details, 0, 8);
        var actions = Flow(install, restore, cancel, stage); body.Controls.Add(actions, 0, 9);
        body.Controls.Add(progress, 0, 10); body.Controls.Add(logBox, 0, 11);
        body.Controls.Add(new Label { Text = "不会更改飞行算法；保留设置、日志及机场缓存。安装前请退出 X-Plane。\nPreserves settings, logs and airport caches. Close X-Plane before installation.", AutoSize = true, ForeColor = Color.DimGray, Margin = new(0, 12, 0, 0) }, 0, 12);
        Controls.Add(body);
        foreach (var combo in new[] { releases, sources })
        {
            combo.DrawMode = DrawMode.OwnerDrawFixed; combo.ItemHeight = 26;
            combo.DrawItem += (_, e) =>
            {
                e.DrawBackground();
                var label = e.Index >= 0 ? combo.Items[e.Index]?.ToString() ?? "" : combo.Text;
                TextRenderer.DrawText(e.Graphics, label, combo.Font, Rectangle.Inflate(e.Bounds, -4, 0), e.ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                e.DrawFocusRectangle();
            };
        }
        cancel.Enabled = false;
        local = Core.LocalReleases(baseDir, Log); LoadReleaseList();
        try { if (File.Exists(preferenceFile)) target.Text = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(preferenceFile))?.GetValueOrDefault("target") ?? ""; } catch { }
        target.TextChanged += (_, _) => ShowStatus(); releases.SelectedIndexChanged += (_, _) => ShowRelease();
        browse.Click += (_, _) => { using var d = new FolderBrowserDialog { Description = "选择 X-Plane 根目录（不是 Scripts） / Select X-Plane root", UseDescriptionForTitle = true, SelectedPath = target.Text }; if (d.ShowDialog(this) == DialogResult.OK) { target.Text = d.SelectedPath; SavePreference(); } };
        detect.Click += async (_, _) => await Detect(); refresh.Click += async (_, _) => await CheckOnline();
        install.Click += async (_, _) => await Install(); restore.Click += async (_, _) => await Restore();
        cancel.Click += (_, _) => { operation?.Cancel(); catalogCancellation?.Cancel(); };
        Shown += async (_, _) => { if (Environment.GetCommandLineArgs().Contains("--render")) { ShowStatus(); ShowRelease(); return; } await Detect(); await CheckOnline(); };
        FormClosing += (_, e) => { if (busy) { e.Cancel = true; MessageBox.Show(this, applying ? "正在写入或回滚，请等待完成。 / Wait for file operations to finish." : "请先取消下载，等待结束后关闭。 / Cancel the download first."); } else catalogCancellation?.Cancel(); };
        ShowStatus(); ShowRelease();
    }
    void Log(string text)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke(() => Log(text)); return; }
        logBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {text}\r\n");
    }
    void Percent(int value)
    {
        if (InvokeRequired) { BeginInvoke(() => Percent(value)); return; }
        progress.Value = Math.Clamp(value, 0, 100); stage.Text = $"{(applying ? "安装 / Install" : "下载 / Download")} {value}%";
    }
    void SavePreference() { try { Directory.CreateDirectory(Path.GetDirectoryName(preferenceFile)!); File.WriteAllText(preferenceFile, JsonSerializer.Serialize(new { target = target.Text })); } catch { } }
    async Task Detect()
    {
        detect.Enabled = false;
        try
        {
            var found = await Task.Run(() => Core.Discover(baseDir)); var current = target.Text;
            if (busy) return;
            target.Items.Clear(); target.Items.AddRange(found.Cast<object>().ToArray());
            target.Text = Core.IsXPlane(current) ? current : found.Count == 1 ? found[0] : "";
            Log(found.Count switch { 0 => "未自动找到 X-Plane，请手动选择根目录。 / Select the root manually.", 1 => "已找到 X-Plane / Detected: " + found[0], _ => "找到多个 X-Plane，请在下拉列表中选择。 / Multiple installations found; select one." });
        }
        catch (Exception e) { Log(e.Message); }
        finally { detect.Enabled = !busy; ShowStatus(); }
    }
    void LoadReleaseList()
    {
        var selected = releases.SelectedItem as Release;
        releases.Items.Clear(); releases.Items.AddRange(Core.LabelReleases(local.Concat(online)).Cast<object>().ToArray());
        if (selected != null && releases.Items.Contains(selected)) releases.SelectedItem = selected;
        else if (releases.Items.Count > 0) releases.SelectedIndex = 0;
        ShowRelease();
    }
    void ShowStatus()
    {
        InstalledState s;
        try { s = Core.Inspect(target.Text); }
        catch (Exception e) { status.Text = "无法读取目录 / Cannot read folder: " + e.Message; return; }
        status.Text = s.Details + "\nFlyWithLua: " + (s.HasFlyWithLua ? "已检测到运行库文件 / Runtime files detected (not a live load check)" : "未安装或文件不完整 / Missing or incomplete");
        if (online.Count > 0)
        {
            var latest = online[0].Version;
            update.Text = s.Version.Length == 0 ? "线上最新 / Online: " + latest : Core.CompareVersion(latest, s.Version) > 0 ? "有更新 / Update: " + latest : "线上最新 / Online: " + latest + " · 无更高版本 / No newer version";
        }
    }
    void ShowRelease()
    {
        if (releases.SelectedItem is not Release r) { details.Text = "没有本地版本；请检查更新或将发行包放入 version。 / No package; check online or add version folder."; install.Enabled = false; return; }
        details.Text = $"将安装 / Will install: {r.Version} · {r.CompatibilityLabel}\n{r.LanguageLabel} · " + (r.LocalDirectory != "" ? "本地离线包 / Offline package" : "联网下载，自动切换备用源 / Online with fallback");
        install.Enabled = !busy;
    }
    async Task CheckOnline()
    {
        if (onlineChecking || busy) return; onlineChecking = true; refresh.Enabled = false;
        catalogCancellation = new(); update.Text = "正在检查两个源 / Checking both sources…";
        try
        {
            using var net = new Network(Log); online = await net.Catalog(catalogCancellation.Token);
            if (!busy) LoadReleaseList();
            if (online.Count == 0) update.Text = "在线状态未知；本地仍可安装 / Online unavailable; local works";
            ShowStatus();
        }
        catch (OperationCanceledException) { update.Text = "检查已取消 / Check cancelled"; }
        finally { onlineChecking = false; refresh.Enabled = !busy; catalogCancellation.Dispose(); catalogCancellation = null; }
    }
    void SetBusy(bool value)
    {
        busy = value; install.Enabled = !value && releases.SelectedItem != null; browse.Enabled = detect.Enabled = restore.Enabled = target.Enabled = releases.Enabled = sources.Enabled = !value; refresh.Enabled = !value && !onlineChecking; cancel.Enabled = value && !applying;
    }
    string Preferred => sources.SelectedIndex switch { 1 => "Gitee", 2 => "GitHub", _ => "Auto" };
    async Task Install()
    {
        if (releases.SelectedItem is not Release selected) return;
        var xp = target.Text.Trim(); string? temp = null;
        try
        {
            Core.ValidateTarget(xp); Core.CheckNotRunning();
            var pending = PendingBackup(xp);
            if (pending != null) throw new IOException("发现上次未完成的安装，请先使用“恢复备份”选择此目录的 transaction.json：\nIncomplete install; restore first:\n" + pending);
            var marker = Core.SafePath(xp, "Resources/plugins/StarLux_LMM.install.pending.json");
            if (File.Exists(marker)) throw new IOException("上次安装未完成，请根据此标记中的 backup 路径恢复备份：\nRestore the backup referenced by this pending installation:\n" + File.ReadAllText(marker));
            var current = Core.Inspect(xp);
            string warning = current.Version.Length > 0 && Core.CompareVersion(selected.Version, current.Version) < 0 ? "警告：所选版本较旧，将降级。 / Warning: this is a downgrade.\n\n" : "";
            if (selected.LocalDirectory == "" && !selected.Sources.Any(s => s.Sha256.Length == 64)) warning += "此历史包没有发布方 SHA256，依靠官方 HTTPS 来源。 / No publisher SHA256 for this legacy archive.\n\n";
            if (MessageBox.Show(this, warning + $"版本 / Version: {selected.Version} {selected.Build}\n{selected.CompatibilityLabel}\n{selected.LanguageLabel}\nX-Plane: {xp}\n备份 / Backup: {Path.Combine(baseDir, "backup")}\n\n保留已有设置与落地记录。确认安装？ / Preserve settings and logs. Install?", "确认安装 / Confirm installation", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return;
            catalogCancellation?.Cancel(); operation = new(); SetBusy(true); SavePreference();
            temp = Directory.CreateTempSubdirectory("StarLux-LMM-install-").FullName;
            using var net = new Network(Log);
            PreparedPackage package;
            if (selected.LocalDirectory != "")
            {
                // Snapshot local files into private staging; never install straight from an editable release folder.
                package = await Task.Run(() => Core.Prepare(selected.LocalDirectory));
                var staged = Path.Combine(temp, "payload");
                await Task.Run(() => { foreach (var f in package.Manifest.Files) { var dest = Core.SafePath(staged, f.Path); Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(Core.SafePath(package.Root, f.Path), dest); } });
                package = new(package.Manifest, staged); Core.ValidatePackage(package);
            }
            else
            {
                var zip = await net.Download(selected.Sources, Path.Combine(temp, "lmm.zip"), Preferred, Percent, operation.Token);
                var unpack = Path.Combine(temp, "lmm"); await Task.Run(() => Core.ExtractZip(zip, unpack));
                package = await Task.Run(() => Core.Prepare(unpack, selected.Version));
            }
            string? fwlRoot = null;
            if (package.Manifest.Kind == "flywithlua" && !Core.HasFwl(xp))
            {
                var answer = MessageBox.Show(this, "缺少 FlyWithLua NG+。\n是：自动下载官方固定版本 2.8.14（Windows 运行库）。\n否：选择你已下载的 XP12 NG+ ZIP。\n取消：退出安装，不修改 X-Plane。\n\nFlyWithLua is missing. Yes: download official 2.8.14. No: import a local NG+ ZIP. Cancel: stop.", "安装依赖 / FlyWithLua dependency", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
                if (answer == DialogResult.Cancel) return;
                string zip;
                if (answer == DialogResult.Yes) zip = await net.Download(DependencySources(), Path.Combine(temp, "fwl.zip"), Preferred, Percent, operation.Token);
                else
                {
                    using var file = new OpenFileDialog { Title = "FlyWithLua NG+ for XP12 ZIP", Filter = "ZIP files|*.zip" };
                    if (file.ShowDialog(this) != DialogResult.OK) return; zip = file.FileName;
                }
                var unpack = Path.Combine(temp, "fwl"); await Task.Run(() => Core.ExtractZip(zip, unpack)); fwlRoot = Core.FindFwl(unpack);
                // Source repository stores MIT license one level above the distribution directory.
                var license = Path.Combine(Path.GetDirectoryName(fwlRoot)!, "LICENSE");
                if (File.Exists(license) && !File.Exists(Path.Combine(fwlRoot, "LICENSE"))) File.Copy(license, Path.Combine(fwlRoot, "LICENSE"));
            }
            operation.Token.ThrowIfCancellationRequested();
            applying = true; cancel.Enabled = false; progress.Value = 0;
            var backup = await Task.Run(() => Core.Install(baseDir, xp, package, fwlRoot, Log, Percent));
            stage.Text = "安装完成 / Complete"; Log("安装成功；请启动 X-Plane 验证插件加载。 / Installed; launch X-Plane to verify loading.");
            try { File.WriteAllText(Path.Combine(backup, "installer.log"), logBox.Text); } catch (Exception e) { Log("日志未保存（安装已成功） / Log not saved: " + e.Message); }
            MessageBox.Show(this, $"已安装 / Installed: {package.Manifest.Version} {package.Manifest.Build}\n备份 / Backup: {backup}\n\n现有设置与记录已保留。 / Existing settings and reports preserved.", "StarLux LMM", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (OperationCanceledException) { stage.Text = "已取消 / Cancelled"; Log("下载已取消，未开始安装。 / Cancelled before file installation."); }
        catch (Exception e) { stage.Text = "未完成 / Not completed"; Log(e.Message); MessageBox.Show(this, e.Message + "\n\n若目录不可写，请把安装器移到可写文件夹；不要关闭安全软件。\nUse a writable folder; do not disable security software.", "安装未完成 / Installation not completed", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally
        {
            applying = false; SetBusy(false); operation?.Dispose(); operation = null; ShowStatus();
            if (temp != null) { try { Core.NoLinks(temp); if (Path.GetFileName(temp).StartsWith("StarLux-LMM-install-") && Path.GetDirectoryName(temp) == Path.GetTempPath().TrimEnd('\\')) Directory.Delete(temp, true); } catch (Exception e) { Log("临时文件保留 / Temporary files retained: " + e.Message); } }
        }
    }
    IEnumerable<DownloadSource> DependencySources()
    {
        // Publisher may add same-byte Gitee release mirrors here without rebuilding the EXE.
        var file = Path.Combine(baseDir, "version", "flywithlua-mirrors.json");
        var list = new List<DownloadSource>();
        if (File.Exists(file))
        {
            var mirrors = JsonSerializer.Deserialize<List<DownloadSource>>(File.ReadAllText(file), Core.Json) ?? [];
            foreach (var mirror in mirrors)
                if (mirror.Sha256.Equals(Network.OfficialFwl.Sha256, StringComparison.OrdinalIgnoreCase) && Uri.TryCreate(mirror.Url, UriKind.Absolute, out var u) && Network.TrustedInitial(u)) list.Add(mirror);
        }
        list.Add(Network.OfficialFwl); return list;
    }
    string? PendingBackup(string xp)
    {
        var folder = Path.Combine(baseDir, "backup"); if (!Directory.Exists(folder)) return null;
        foreach (var dir in Directory.GetDirectories(folder))
        {
            var f = Path.Combine(dir, "transaction.json"); if (!File.Exists(f)) continue;
            var j = JsonSerializer.Deserialize<Journal>(File.ReadAllText(f), Core.Json);
            if (j != null && j.Status is "prepared" or "installing" && Core.NormalizeDirectory(j.Target).Equals(Core.NormalizeDirectory(xp), StringComparison.OrdinalIgnoreCase)) return f;
        }
        return null;
    }
    async Task Restore()
    {
        try
        {
            Core.ValidateTarget(target.Text); Core.CheckNotRunning();
            using var file = new OpenFileDialog { Title = "选择备份 transaction.json / Select backup journal", Filter = "Backup transaction|transaction.json", InitialDirectory = Path.Combine(baseDir, "backup") };
            if (file.ShowDialog(this) != DialogResult.OK) return;
            if (MessageBox.Show(this, "恢复将替换此次安装涉及的文件，不恢复用户设置或飞行日志。\n请优先选择最近一次备份。继续？\nRestore files touched by this install. Prefer the latest backup. Continue?", "恢复备份 / Restore", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
            var xp = target.Text; applying = true; SetBusy(true);
            await Task.Run(() => Core.Restore(Path.GetDirectoryName(file.FileName)!, xp)); Log("备份已恢复 / Backup restored"); stage.Text = "已恢复 / Restored";
        }
        catch (Exception e) { MessageBox.Show(this, e.Message, "恢复未完成 / Restore failed"); }
        finally { applying = false; SetBusy(false); ShowStatus(); }
    }
}
