using System.Text.RegularExpressions;

namespace StarLux.Installer;

public sealed class InstalledFile
{
    public string Path { get; set; } = "";
    public string Category { get; set; } = "program";
    public string Status { get; set; } = "";
    public string Expected { get; set; } = "";
    public string Actual { get; set; } = "";
    public long Bytes { get; set; }
    public bool Exists { get; set; }
    public bool Removable { get; set; } = true;
    public string CategoryName => Category switch {
        "settings" => U.T("插件设置", "Settings"), "cache" => U.T("缓存 / 诊断", "Cache / diagnostics"),
        "reports" => U.T("飞行记录", "Flight records"), "metadata" => U.T("安装记录", "Install metadata"),
        "unknown" => U.T("未知 / 受保护", "Unknown / protected"), _ => U.T("程序 / 分析器", "Program / analyzer") };
}

public static partial class Core
{
    public const string Pending = "Resources/plugins/StarLux_LMM.install.pending.json";
    // Dedicated names, not broad LMM* deletion in the shared Scripts directory.
    static string DataCategory(string relative) => relative switch {
        "LMM_Settings.cfg" => "settings",
        "LMM_Apt_Index_v1.cache" or "LMM_Startup_Diagnostic.txt" => "cache",
        "LMM_Log/LMM_Viewer.html" or "LMM_Log/LMM_Viewer_Data.js" or "LMM_Log/LMM_Trends_Analyzer.html" => "program",
        "LMM_Log/.lmm_index.tmp" or "LMM_Log/.lmm_index" or "LMM_Log/.lmm-update-standard.txt" or "LMM_Log/.lmm-update-compatibility.txt" or
        "LMM_Log/.lmm-update-standard.txt.tmp" or "LMM_Log/.lmm-update-compatibility.txt.tmp" => "cache",
        _ => Regex.IsMatch(relative, @"^LMM_Log/LMM_[\w.\-]+\.txt(?:\.recording\.tmp|\.previous)?$", RegexOptions.IgnoreCase) ||
             Regex.IsMatch(relative, @"^LMM_Log/\.LMM_Recording_\d{8}_\d{6}_\d+\.part$", RegexOptions.IgnoreCase) ? "reports" : "unknown"
    };

    public static List<InstalledFile> Inventory(string target, PackageManifest? receipt = null)
    {
        var rows = new Dictionary<string, InstalledFile>(StringComparer.OrdinalIgnoreCase);
        void Add(string relative, string category, bool removable = true, string expected = "")
        {
            relative = relative.Replace('\\', '/');
            var path = SafePath(target, relative);
            var exists = File.Exists(path);
            var row = new InstalledFile { Path = relative, Category = category, Removable = removable, Exists = exists, Expected = expected,
                Bytes = exists ? new FileInfo(path).Length : 0, Status = exists ? U.T("存在", "Present") : U.T("缺失", "Missing") };
            if (exists && expected != "")
            {
                try { row.Actual = Hash(path); row.Status = row.Actual.Equals(expected, StringComparison.OrdinalIgnoreCase) ? U.T("校验通过", "Verified") : U.T("内容与安装清单不一致", "Contents differ from receipt"); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { row.Status = U.T("无法读取：", "Cannot read: ") + e.Message; }
            }
            if (exists && (File.GetAttributes(path) & FileAttributes.ReadOnly) != 0) row.Status += U.T(" · 只读", " · Read-only");
            rows[relative] = row;
        }
        foreach (var f in OwnedFiles(target)) Add(f, "program");
        var scripts = SafePath(target, Scripts);
        if (Directory.Exists(scripts))
        {
            foreach (var file in Directory.EnumerateFiles(scripts))
            {
                var name = Path.GetFileName(file); var category = DataCategory(name);
                if (category != "unknown") Add(Scripts + "/" + name, category);
            }
            // Show unknown files in LMM-owned folders too, but never authorize their deletion.
            foreach (var dir in Directory.EnumerateDirectories(scripts).Where(p => Path.GetFileName(p) == "LMM_Log" || Regex.IsMatch(Path.GetFileName(p), "^LMM_UI_[0-9]+$")))
                foreach (var f in Files(dir))
                {
                    var rel = Path.GetRelativePath(scripts, f).Replace('\\', '/'); var key = Scripts + "/" + rel;
                    if (rows.ContainsKey(key)) continue;
                    var category = DataCategory(rel);
                    if (rel == "LMM_Log/README.txt")
                    {
                        using var reader = new StreamReader(f); var buffer = new char[2048]; var size = reader.Read(buffer,0,buffer.Length);
                        if (new string(buffer,0,size).Contains("StarLux Landing Meter",StringComparison.OrdinalIgnoreCase)) category = "program";
                    }
                    Add(key, category, category != "unknown");
                }
        }
        if (receipt != null)
        {
            var prefix = receipt.Kind == "native" ? "Resources/plugins/StarLux_LMM" : Scripts;
            foreach (var f in receipt.Files)
            {
                var rel = prefix + "/" + f.Path.Replace('\\', '/');
                // Shared generic documentation is visible for integrity checks, protected on removal.
                Add(rel, "program", rows.ContainsKey(rel), f.Sha256);
            }
        }
        if (File.Exists(SafePath(target, Receipt))) Add(Receipt, "metadata");
        if (File.Exists(SafePath(target, Pending))) Add(Pending, "metadata", false);
        return rows.Values.OrderBy(f => f.Category == "unknown").ThenBy(f => f.Category).ThenBy(f => f.Path, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public static List<string> RemovalFiles(Diagnosis diagnosis, bool complete, bool reports) => diagnosis.Files
        .Where(f => f.Exists && f.Removable && (f.Category is "program" or "metadata" || complete && (f.Category is "settings" or "cache" || reports && f.Category == "reports")))
        .Select(f => f.Path).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    public static string RemoveReviewed(string baseDir, string target, IReadOnlyCollection<string> reviewed, bool complete, bool reports,
        Action<string> log, Action<int> progress, bool checkRunning = true, int failAfter = -1)
    {
        ValidateTarget(target); if (checkRunning) CheckNotRunning(); target = NormalizeDirectory(target);
        using var lease = new TargetLease(target); CheckPending(target);
        var allowed = RemovalFiles(Diagnose(target), complete, reports).ToHashSet(StringComparer.OrdinalIgnoreCase);
        // Never silently expand deletion beyond the preview approved in the UI.
        if (reviewed.Any(p => !allowed.Contains(p))) throw new IOException(U.T("文件清单已变化，请重新查看卸载范围。", "The file inventory changed. Review the removal scope again."));
        if (File.Exists(SafePath(target, Receipt)) && !reviewed.Contains(Receipt, StringComparer.OrdinalIgnoreCase))
            throw new IOException(U.T("安装记录在确认后发生变化，请重新查看卸载范围。", "The receipt changed after review. Review removal again."));
        return ExecutePlan(baseDir, target, reviewed.ToDictionary(p => p, _ => "", StringComparer.OrdinalIgnoreCase), null, log, progress, checkRunning, failAfter);
    }

    static void PreflightTargets(string target, IEnumerable<string> paths, Action<string> log)
    {
        foreach (var relative in paths.Append(Receipt).Append(Pending).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var path = SafePath(target, relative);
            InstallerTrace.Step(U.T("预检目标文件访问", "Preflight target access"), path, () => {
                if (Directory.Exists(path)) throw new DiagnosticFailure("TARGET_IS_DIRECTORY", U.T("目标文件路径被同名文件夹占用。", "A directory occupies the target file path."), U.T("检查此路径的内容，移开冲突目录后重试。", "Inspect and relocate the conflicting directory, then retry."), path);
                if (!File.Exists(path)) return;
                var attributes = File.GetAttributes(path); InstallerTrace.Event("TARGET_ATTRIBUTES", new { path, attributes = attributes.ToString() });
                if ((attributes & FileAttributes.ReadOnly) != 0) throw new DiagnosticFailure("TARGET_READ_ONLY", U.T("文件为只读；尚未改动插件文件。", "The file is read-only; plugin files have not been changed."), U.T("打开该文件的属性，确认并取消只读后重试。安装器不会自动更改权限。", "Check this file's Properties and clear Read-only before retrying. Permissions are not changed automatically."), path);
                using var probe = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            }, log);
        }
    }
}
