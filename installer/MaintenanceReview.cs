namespace StarLux.Installer;

// One review surface for diagnosis, exact install changes and removal scope.
internal sealed class MaintenanceReview : Form
{
    readonly DataGridView grid = new() { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false,
        AllowUserToDeleteRows = false, AutoGenerateColumns = false, RowHeadersVisible = false,
        SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, BackgroundColor = Color.FromArgb(10,25,44),
        BorderStyle = BorderStyle.None, AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells };
    readonly TextBox detail = new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false };
    readonly CheckBox reports = new() { AutoSize = true, Text = U.T("同时删除飞行记录（含未完成录制及记录备份）", "Also delete flight records, incomplete recordings and record backups") };
    readonly Label count = new() { AutoSize = true, Dock = DockStyle.Fill };
    readonly Diagnosis diagnosis;
    readonly string target;
    readonly bool removal, complete;
    readonly Dictionary<string,string>? plan;
    public bool IncludeReports => reports.Checked;
    public List<string> SelectedFiles => Core.RemovalFiles(diagnosis, complete, reports.Checked);

    internal MaintenanceReview(string target, Diagnosis diagnosis, string title, bool removal = false, bool complete = false, Dictionary<string,string>? plan = null, string explanation = "")
    {
        this.target = target; this.diagnosis = diagnosis; this.removal = removal; this.complete = complete; this.plan = plan;
        Text = title; Font = new("Microsoft YaHei UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(1050, 740); MinimumSize = new(860, 620); StartPosition = FormStartPosition.CenterParent; ShowInTaskbar = false;
        BackColor = Color.FromArgb(14,34,57); ForeColor = Color.FromArgb(223,239,252); Padding = new(20);
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 6, ColumnCount = 1 };
        body.RowStyles.Add(new(SizeType.Absolute, 150)); body.RowStyles.Add(new(SizeType.AutoSize));
        body.RowStyles.Add(new(SizeType.AutoSize)); body.RowStyles.Add(new(SizeType.Percent,100));
        body.RowStyles.Add(new(SizeType.Absolute,115)); body.RowStyles.Add(new(SizeType.AutoSize));
        var intro = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.Vertical,
            BackColor = BackColor, ForeColor = ForeColor, Text = target + "\r\n\r\n" + (explanation != "" ? explanation : diagnosis.Details()).Replace("\n", "\r\n") };
        body.Controls.Add(intro,0,0); reports.Visible = removal && complete; reports.Margin = new(0,8,0,8); body.Controls.Add(reports,0,1);
        count.Margin = new(0,8,0,8); body.Controls.Add(count,0,2); body.Controls.Add(grid,0,3); body.Controls.Add(detail,0,4);
        grid.EnableHeadersVisualStyles = false; grid.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(28,66,104); grid.ColumnHeadersDefaultCellStyle.ForeColor = ForeColor;
        grid.DefaultCellStyle.BackColor = Color.FromArgb(18,42,67); grid.DefaultCellStyle.ForeColor = ForeColor;
        grid.DefaultCellStyle.SelectionBackColor = Color.FromArgb(40,89,130); grid.DefaultCellStyle.SelectionForeColor = Color.White;
        grid.DefaultCellStyle.WrapMode = DataGridViewTriState.True;
        foreach (var (header,width) in new[] { (U.T("处理 / 状态", "Action / status"),190), (U.T("分类", "Category"),150), (U.T("相对 X-Plane 的路径", "Path relative to X-Plane"),510), (U.T("大小", "Size"),90) })
            grid.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = header, Width = width, SortMode = DataGridViewColumnSortMode.NotSortable });
        grid.Columns[2].AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
        detail.BackColor = BackColor; detail.ForeColor = ForeColor; detail.BorderStyle = BorderStyle.None; detail.Margin = new(0,10,0,4);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Margin = new(0,12,0,0) };
        Button Button(string text, DialogResult result) => new() { Text = text, DialogResult = result, AutoSize = true, Padding = new(10,5,10,5), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(28,66,104), ForeColor = ForeColor };
        var cancel = Button(U.T(removal || plan != null ? "取消" : "关闭", removal || plan != null ? "Cancel" : "Close"), DialogResult.Cancel); buttons.Controls.Add(cancel); CancelButton = cancel;
        if (removal || plan != null)
        {
            var apply = Button(U.T(removal ? "确认卸载所列文件" : "确认安装所列文件", removal ? "Remove listed files" : "Install listed files"), DialogResult.OK);
            buttons.Controls.Add(apply); // No Enter/default destructive action.
        }
        var copy = Button(U.T("复制清单与原因", "Copy list and reasons"), DialogResult.None); buttons.Controls.Add(copy);
        copy.Click += (_,_) => { try { Clipboard.SetText(intro.Text + "\r\n\r\n" + count.Text + "\r\n" + string.Join("\r\n", grid.Rows.Cast<DataGridViewRow>().Select(r => string.Join(" | ",r.Cells.Cast<DataGridViewCell>().Select(c=>c.Value)))) + "\r\n\r\n" + detail.Text); } catch(Exception e) { MessageBox.Show(this,e.Message,Text); } };
        body.Controls.Add(buttons,0,5); Controls.Add(body);
        reports.CheckedChanged += (_,_) => Populate(); grid.CurrentCellChanged += (_,_) => ShowDetail(); Populate();
        Shown += (_,_) => BeginInvoke(() => { intro.Select(0,0); ActiveControl=grid; if(!removal && plan==null) { var issue=grid.Rows.Cast<DataGridViewRow>().FirstOrDefault(r=>r.Tag is InstalledFile f && f.Expected!="" && f.Actual!=f.Expected); if(issue!=null)grid.CurrentCell=issue.Cells[0]; } ShowDetail(); });
    }
    void Populate()
    {
        grid.Rows.Clear(); var removed = SelectedFiles.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var rows = diagnosis.Files.ToDictionary(f=>f.Path, StringComparer.OrdinalIgnoreCase);
        if (plan != null) foreach(var p in plan.Keys) if(!rows.ContainsKey(p)) rows[p] = new InstalledFile { Path = p, Status = U.T("新增", "New") };
        foreach (var file in rows.Values.OrderBy(f=>f.Category == "unknown").ThenBy(f=>f.Path))
        {
            var action = removal ? removed.Contains(file.Path) ? U.T("删除（先备份）", "Remove (backed up)") : U.T("保留", "Keep") :
                plan != null ? plan.TryGetValue(file.Path,out var src) ? src == "" ? U.T("移除 / 重置", "Remove / reset") : file.Exists ? U.T("替换", "Replace") : U.T("新增", "Add") : U.T("保留", "Keep") : file.Status;
            var index = grid.Rows.Add(action, file.CategoryName, file.Path, file.Exists ? file.Bytes.ToString("N0") + " B" : "—"); grid.Rows[index].Tag = file;
        }
        var selected = rows.Values.Where(f=>removed.Contains(f.Path)).ToList();
        count.Text = removal ? U.T("将删除：", "To remove: ") + selected.Count + U.T(" 个文件 · ", " files · ") + (selected.Sum(f=>f.Bytes)/1048576.0).ToString("N1") + " MB" :
            U.T("相关文件：", "Related files: ") + rows.Values.Count(f=>f.Exists) + U.T(" · 缺失：", " · Missing: ") + rows.Values.Count(f=>!f.Exists) + U.T(" · 检查项：", " · Findings: ") + diagnosis.Issues.Count;
        ShowDetail();
    }
    void ShowDetail()
    {
        if(grid.CurrentRow?.Tag is not InstalledFile f) { detail.Text = ""; return; }
        detail.Text = (System.IO.Path.Combine(target,f.Path.Replace('/',System.IO.Path.DirectorySeparatorChar)) + "\n" + f.Status +
            (f.Expected != "" ? "\n" + U.T("清单 SHA-256：", "Receipt SHA-256: ") + f.Expected + "\n" + U.T("实际 SHA-256：", "Actual SHA-256: ") + (f.Actual == "" ? U.T("不可用", "Unavailable") : f.Actual) : "") +
            (!f.Removable ? "\n" + U.T("受保护：归属无法安全确认或属于共享文件，不会删除。", "Protected: shared file or ownership not safely established; not removed.") : "")).Replace("\n","\r\n");
    }
}

public sealed partial class MainForm
{
    async Task ShowInventory()
    {
        if (busy) return; SetBusy(true);
        try { var xp = target.Text.Trim(); Core.ValidateTarget(xp); var d = await Task.Run(()=>Core.Diagnose(xp)); using var review = new MaintenanceReview(xp,d,U.T("安装详情 / 文件清单", "Installation details / files")); review.ShowDialog(this); }
        catch(Exception e) { Error("Inspect installation files",e); }
        finally { SetBusy(false); }
    }
}
