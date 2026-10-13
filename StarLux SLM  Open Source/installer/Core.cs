using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace StarLux.Installer;

public record PayloadFile(string Path, string Sha256);
public sealed class PackageManifest
{
    public int Schema { get; set; } = 1;
    public string Product { get; set; } = "StarLux_LMM";
    public string Version { get; set; } = "";
    public string Build { get; set; } = "";
    // Closed set of install roots. Never accept arbitrary paths from a remote manifest.
    public string Kind { get; set; } = "flywithlua";
    public string Notes { get; set; } = "";
    public string UiVariant { get; set; } = "";
    public string DefaultLanguage { get; set; } = "";
    public string AnalyzerResetToken { get; set; } = "";
    public List<PayloadFile> Files { get; set; } = [];
}
public sealed class Release
{
    public string Version { get; set; } = "";
    public string Build { get; set; } = "";
    public string Variant { get; set; } = "";
    public string UiVariant { get; set; } = "";
    public string DefaultLanguage { get; set; } = "";
    public bool IsLatest { get; set; }
    public string CompatibilityLabel => (UiVariant == "legacy" || Variant.Contains("Compatibility", StringComparison.OrdinalIgnoreCase))
        ? "旧版 UI 兼容 / Legacy UI · XP 12 < 12.4.4"
        : (UiVariant == "sdk440" || Variant.Contains("Standard", StringComparison.OrdinalIgnoreCase))
            ? "标准版 / Standard · XP 12.4.4+" : "历史版本 / Historical";
    public string LanguageLabel => DefaultLanguage == "en" || Variant.Contains("International", StringComparison.OrdinalIgnoreCase)
        ? "默认英文 / English default" : DefaultLanguage == "zh" || Variant.Contains("-CN", StringComparison.OrdinalIgnoreCase) ? "默认中文 / Chinese default" : "";
    public string LocalDirectory { get; set; } = "";
    public List<DownloadSource> Sources { get; set; } = [];
    public override string ToString() => $"{(IsLatest ? "【最新 / Latest】 " : "")}{Version} · {CompatibilityLabel} · {LanguageLabel} [{(LocalDirectory.Length > 0 ? "本地 / Local" : string.Join(" + ", Sources.Select(s => s.Name).Distinct()))}]";
}
public record DownloadSource(string Name, string Url, string Sha256 = "");
public record PreparedPackage(PackageManifest Manifest, string Root);
public record InstalledState(string Version, string Details, bool HasFlyWithLua);
public sealed class Journal
{
    public string Id { get; set; } = "";
    public List<JournalEntry> ResultFiles { get; set; } = [];
    public string PreviousPending { get; set; } = "";
    public string Target { get; set; } = "";
    public string Status { get; set; } = "prepared";
    public string Version { get; set; } = "";
    public List<JournalEntry> Entries { get; set; } = [];
    public string Failure { get; set; } = "";
    public string RollbackFailure { get; set; } = "";
}
public record JournalEntry(string Path, bool Existed, string Sha256 = "");

public static partial class Core
{
    sealed class TargetLease : IDisposable
    {
        readonly Mutex mutex;
        bool acquired;
        public TargetLease(string target)
        {
            var key = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(target).TrimEnd('\\').ToUpperInvariant())));
            mutex = new Mutex(false, "Local\\StarLuxLMM-" + key);
            try { acquired = mutex.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) { mutex.Dispose(); throw new IOException(U.T("此 X-Plane 正在被其他安装器修改，请稍后重试。","Another installer is modifying this simulator.")); }
        }
        public void Dispose() { if (acquired) mutex.ReleaseMutex(); mutex.Dispose(); }
    }
    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public const string Scripts = "Resources/plugins/FlyWithLua/Scripts";
    public const string Fwl = "Resources/plugins/FlyWithLua";
    public const string Receipt = "Resources/plugins/StarLux_LMM.install.json";
    public static string NormalizeDirectory(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    public static string Hash(string file) { using var s = File.OpenRead(file); return Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant(); }
    public static bool MainLua(string name) => Regex.IsMatch(name, @"^StarLux[_ -](?:LMM|Landing[_ -]Meter)(?:[_ -]v?[0-9][\w.\-]*)?\.lua$", RegexOptions.IgnoreCase);
    public static string ExtractVersion(string name)
    {
        var m = Regex.Match(name, @"(?i)(\d+\.\d+(?:\.\d+)?(?:[-.]?(?:alpha|beta|rc)\d*)?)");
        return m.Success ? m.Value : "";
    }
    public static int CompareVersion(string a, string b)
    {
        (int[], int, int) Parse(string s)
        {
            var m = Regex.Match(ExtractVersion(s), @"(?i)^(\d+)\.(\d+)(?:\.(\d+))?(?:[-.]?(alpha|beta|rc)(\d*))?$");
            if (!m.Success) return ([0, 0, 0], -1, 0);
            int N(int i) => int.TryParse(m.Groups[i].Value, out var n) ? n : 0;
            // Historical project naming: bare 1.1.9rc2+ is a maintenance revision
            // after 1.1.9; ordinary -rc prerelease ordering remains unchanged.
            int rank=m.Groups[4].Value.ToLowerInvariant() switch { "alpha" => 0, "beta" => 1, "rc" => 2, _ => 3 };
            if(Regex.IsMatch(ExtractVersion(s),@"^(1\.1\.9|1\.0\.2)rc\d+$",RegexOptions.IgnoreCase) && N(5)>=2) rank=4;
            return ([N(1), N(2), N(3)], rank, N(5));
        }
        var x = Parse(a); var y = Parse(b);
        for (int i = 0; i < 3; i++) { int c = x.Item1[i].CompareTo(y.Item1[i]); if (c != 0) return c; }
        int rank = x.Item2.CompareTo(y.Item2); return rank != 0 ? rank : x.Item3.CompareTo(y.Item3);
    }
    public static List<Release> LabelReleases(IEnumerable<Release> releases)
    {
        var list = releases.OrderByDescending(r => r.Version, Comparer<string>.Create(CompareVersion))
            .ThenBy(r => r.UiVariant == "legacy" || r.Variant.Contains("Compatibility", StringComparison.OrdinalIgnoreCase))
            .ThenBy(r => r.DefaultLanguage == "en" || r.Variant.Contains("International", StringComparison.OrdinalIgnoreCase))
            .ThenBy(r => r.LocalDirectory.Length == 0).ToList();
        foreach (var release in list) release.IsLatest = CompareVersion(release.Version, list[0].Version) == 0;
        return list;
    }
    public static string SafePath(string root, string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains(':')) throw new IOException(U.T("非法路径","Invalid relative path: ") + relative);
        var parts = relative.Replace('\\', '/').Split('/');
        if (parts.Any(p => p is ".." or "." or "" || p.EndsWith(' ') || p.EndsWith('.') || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Regex.IsMatch(p, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase)))
            throw new IOException(U.T("非法路径","Invalid relative path: ") + relative);
        var full = Path.GetFullPath(Path.Combine(root, relative));
        var prefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException(U.T("路径超出目标","Path escapes target"));
        NoLinks(full);
        return full;
    }
    public static void NoLinks(string path)
    {
        for (var p = Path.GetFullPath(path); p != null; p = Path.GetDirectoryName(p))
            if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new IOException(U.T("为保证备份安全，不支持符号链接或目录联接","Reparse point: ") + p);
    }
    public static IEnumerable<string> Files(string root)
    {
        NoLinks(root);
        foreach (var f in Directory.EnumerateFiles(root)) { NoLinks(f); yield return f; }
        foreach (var dir in Directory.EnumerateDirectories(root)) foreach (var f in Files(dir)) yield return f;
    }
    public static bool IsXPlane(string path) => File.Exists(Path.Combine(path, "X-Plane.exe")) && Directory.Exists(Path.Combine(path, "Resources", "plugins"));
    public static void ValidateTarget(string path)
    {
        if (!IsXPlane(path)) throw new IOException(U.T("请选择含 X-Plane.exe 和 Resources/plugins 的 X-Plane 根目录。","Select the X-Plane root."));
        NoLinks(path);
        // Avoid interpreting an XP11 installation as an XP12 target. Missing metadata remains user-confirmed.
        var version = FileVersionInfo.GetVersionInfo(Path.Combine(path, "X-Plane.exe")).ProductMajorPart;
        if (version > 0 && version < 12) throw new IOException(U.T("本安装器面向 X-Plane 12，不支持 X-Plane 11。","X-Plane 12 required."));
    }
    public static void CheckNotRunning()
    {
        if (Process.GetProcessesByName("X-Plane").Length > 0) throw new IOException(U.T("请完全退出 X-Plane 后再安装或恢复。","Exit X-Plane before installing or restoring."));
    }
    public static bool HasFwl(string root) => new[] { "win_x64/FlyWithLua.xpl", "64/win.xpl" }.Any(p => File.Exists(Path.Combine(root, Fwl, p)))
        && File.Exists(Path.Combine(root, Fwl, "Internals/FlyWithLua.ini"));
    public static InstalledState Inspect(string root)
    {
        var diagnosis = Diagnose(root);
        return new(diagnosis.Version, diagnosis.Describe(), diagnosis.HasFlyWithLua);
    }
    public static List<string> Discover(string baseDir)
    {
        var candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Add(string? p) { try { if (!string.IsNullOrWhiteSpace(p) && IsXPlane(p)) candidates.Add(NormalizeDirectory(p)); } catch { } }
        for (var p = baseDir; p != null; p = Path.GetDirectoryName(p)) Add(p);
        foreach (var dir in new[] { Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) })
        {
            try { var f = Path.Combine(dir, "x-plane_install_12.txt"); if (File.Exists(f)) foreach (var line in File.ReadLines(f)) Add(line.Trim()); } catch { }
        }
        var steam = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in new[] { @"HKEY_CURRENT_USER\Software\Valve\Steam", @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam" })
            foreach (var value in new[] { "SteamPath", "InstallPath" }) try { if (Registry.GetValue(key, value, null) is string s) steam.Add(s); } catch { }
        steam.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam"));
        foreach (var dir in steam.ToArray())
        {
            try
            {
                var vdf = Path.Combine(dir, "steamapps/libraryfolders.vdf");
                if (File.Exists(vdf)) foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\"")) steam.Add(m.Groups[1].Value.Replace("\\\\", "\\"));
            }
            catch { }
        }
        foreach (var dir in steam)
        {
            Add(Path.Combine(dir, "steamapps/common/X-Plane 12"));
            try
            {
                var f = Path.Combine(dir, "steamapps/appmanifest_2014780.acf");
                if (File.Exists(f)) { var m = Regex.Match(File.ReadAllText(f), "\"installdir\"\\s+\"([^\"]+)\""); if (m.Success) Add(Path.Combine(dir, "steamapps/common", m.Groups[1].Value)); }
            }
            catch { }
        }
        foreach (var drive in DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady))
            foreach (var suffix in new[] { "X-Plane 12", "Games/X-Plane 12", "Steam/steamapps/common/X-Plane 12", "SteamLibrary/steamapps/common/X-Plane 12" }) Add(Path.Combine(drive.RootDirectory.FullName, suffix));
        Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "X-Plane 12"));
        return candidates.Order().ToList();
    }
    public static List<Release> LocalReleases(string baseDir, Action<string> log)
    {
        var folder = Path.Combine(baseDir, "version");
        if (!Directory.Exists(folder)) return [];
        var result = new List<Release>();
        foreach (var dir in Directory.GetDirectories(folder).Prepend(folder))
        {
            var f = Path.Combine(dir, "manifest.json"); if (!File.Exists(f)) continue;
            try
            {
                var m = JsonSerializer.Deserialize<PackageManifest>(File.ReadAllText(f), Json)!;
                if (m.Product != "StarLux_LMM" || m.Schema != 1 || ExtractVersion(m.Version) == "") throw new IOException(U.T("无效清单","Invalid manifest"));
                result.Add(new Release { Version = m.Version, Build = m.Build, UiVariant = m.UiVariant, DefaultLanguage = m.DefaultLanguage, LocalDirectory = dir });
            }
            catch (Exception e) { InstallerTrace.Fault("Read local manifest "+f,e);log(U.T("本地版本忽略：", "Local package skipped: ") + f + ": " + e.Message); }
        }
        return result.OrderByDescending(r => r.Version, Comparer<string>.Create(CompareVersion)).ToList();
    }
    public static void ExtractZip(string zip, string destination)
    {
        InstallerTrace.Event("EXTRACT_ARCHIVE",new {zip,destination});
        using var archive = ZipFile.OpenRead(zip);
        long total = 0; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (archive.Entries.Count > 20000) throw new IOException(U.T("ZIP 文件过多","Too many ZIP entries"));
        foreach (var entry in archive.Entries)
        {
            // Reject Unix symlinks, Windows reparse points, traversal, duplicate Windows paths and zip bombs.
            if (((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000 || (entry.ExternalAttributes & 0x400) != 0) throw new IOException(U.T("ZIP 不允许链接","ZIP links forbidden"));
            var relative = entry.FullName.Replace('\\', '/').TrimEnd('/'); if (relative == "") continue;
            var target = SafePath(destination, relative);
            if (!seen.Add(relative)) throw new IOException(U.T("ZIP 重复路径","Duplicate ZIP path: ") + relative);
            if (entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\')) { Directory.CreateDirectory(target); continue; }
            total += entry.Length;
            if (entry.Length > 256L * 1024 * 1024 || total > 512L * 1024 * 1024) throw new IOException(U.T("ZIP 超出大小限制","ZIP size limit"));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            InstallerTrace.Step(U.T("提取文件","Extract file"),entry.FullName+" -> "+target,()=>entry.ExtractToFile(target,false));
        }
    }
    public static PreparedPackage Prepare(string directory, string version = "")
    {
        var manifestFile = Path.Combine(directory, "manifest.json");
        if (File.Exists(manifestFile))
        {
            InstallerTrace.Session?.Snapshot("package-manifest.json",manifestFile);
            var manifest = JsonSerializer.Deserialize<PackageManifest>(File.ReadAllText(manifestFile), Json) ?? throw new IOException(U.T("空清单","Empty manifest"));
            var prepared = new PreparedPackage(manifest, Path.Combine(directory, "payload")); ValidatePackage(prepared);
            if (version.Length > 0 && CompareVersion(version, manifest.Version) != 0) throw new IOException(U.T("所选版本与清单不一致","Manifest version mismatch"));
            return prepared;
        }
        // Historic release ZIPs are not repository snapshots. Only a unique active payload is accepted.
        var all = Files(directory).ToArray();
        var manifests = all.Where(f => Path.GetFileName(f) == "manifest.json" && !f.Contains(Path.DirectorySeparatorChar + "fonts" + Path.DirectorySeparatorChar)).ToArray();
        if (manifests.Length == 1) return Prepare(Path.GetDirectoryName(manifests[0])!, version);
        var mains = all.Where(f => MainLua(Path.GetFileName(f))).ToArray();
        if (mains.Length != 1) throw new IOException(U.T("发布包应只有一个 LMM 主脚本；不接受含历史备份的仓库快照。","Ambiguous package; use release ZIP."));
        var root = Path.GetDirectoryName(mains[0])!;
        var m = new PackageManifest { Version = ExtractVersion(Path.GetFileName(mains[0])), Build = "legacy-release", Notes = U.T("历史发布包","Legacy release") };
        if (version.Length > 0 && CompareVersion(version, m.Version) != 0) throw new IOException(U.T("所选版本与主脚本不一致","Release version mismatch"));
        m.Files = Files(root).Select(f => new PayloadFile(Path.GetRelativePath(root, f).Replace('\\', '/'), Hash(f))).Where(f => Allowed(m.Kind, f.Path)).ToList();
        var p = new PreparedPackage(m, root); ValidatePackage(p); return p;
    }
    public static bool Allowed(string kind, string relative)
    {
        var p = relative.Replace('\\', '/');
        if (kind == "native") return p != "manifest.json" && !p.StartsWith("../") && !p.StartsWith("logs/", StringComparison.OrdinalIgnoreCase) && !p.EndsWith(".cfg", StringComparison.OrdinalIgnoreCase);
        if (kind != "flywithlua") return false;
        return MainLua(p) || p is "LMM_Report_Reader.html" or "LICENSE" || Regex.IsMatch(p, @"^README[^/]*\.(md|txt)$", RegexOptions.IgnoreCase)
            || Regex.IsMatch(p, @"^LMM_UI_[0-9]+/(?:[\w.-]+\.lua|fonts/[\w.-]+\.(?:otf|ttf|txt|json))$", RegexOptions.IgnoreCase);
    }
    public static void ValidatePackage(PreparedPackage package)
    {
        var m = package.Manifest;
        if (m.Schema != 1 || m.Product != "StarLux_LMM" || string.IsNullOrWhiteSpace(m.Version) || ExtractVersion(m.Version) == "" || m.Kind is not ("flywithlua" or "native") || m.UiVariant is not ("" or "sdk440" or "legacy") || m.Files == null || m.Files.Count == 0 || m.Files.Count > 2000) throw new IOException(U.T("不支持的安装清单","Unsupported manifest"));
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in m.Files)
        {
            if (f == null || string.IsNullOrEmpty(f.Path) || string.IsNullOrEmpty(f.Sha256) || !seen.Add(f.Path.Replace('\\', '/')) || !Allowed(m.Kind, f.Path)) throw new IOException(U.T("不允许的载荷文件","Disallowed payload: ") + f?.Path);
            var path = SafePath(package.Root, f.Path);
            InstallerTrace.Step(U.T("校验载荷文件","Verify payload file"),path,()=>{
                if(!File.Exists(path))throw new FileNotFoundException(U.T("安装包缺少文件。","Package file missing."),path);
                var actual=Hash(path);
                if(!Regex.IsMatch(f.Sha256,"^[a-fA-F0-9]{64}$") || !actual.Equals(f.Sha256,StringComparison.OrdinalIgnoreCase))
                    throw new DiagnosticFailure("PACKAGE_HASH_MISMATCH",U.T("安装包文件校验失败。","Package checksum mismatch.")+$"\nExpected: {f.Sha256}\nActual: {actual}",U.T("重新完整解压或重新下载对应发行包；不会应用校验失败的载荷。","Re-extract or re-download the complete release; an invalid payload will not be applied."),path);
            });
        }
        if (m.Kind == "flywithlua" && m.Files.Count(f => MainLua(f.Path)) != 1) throw new IOException(U.T("必须只有一个主脚本","Exactly one main script required"));
        if (m.Kind == "flywithlua")
        {
            var fileVersion = ExtractVersion(m.Files.Single(f => MainLua(f.Path)).Path);
            if (fileVersion.Length > 0 && CompareVersion(fileVersion, m.Version) != 0) throw new IOException(U.T("主脚本文件名版本与清单不同","Main script version differs from manifest"));
        }
        if (m.Kind == "native" && !m.Files.Any(f => f.Path.Replace('\\', '/').Equals("win_x64/StarLux_LMM.xpl", StringComparison.OrdinalIgnoreCase))) throw new IOException(U.T("缺少原生插件","Missing native plugin"));
    }
    public static string FindFwl(string extracted)
    {
        var binaries = Files(extracted).Where(f => Path.GetFileName(f).Equals("FlyWithLua.xpl", StringComparison.OrdinalIgnoreCase) && Path.GetFileName(Path.GetDirectoryName(f)) == "win_x64").ToArray();
        if (binaries.Length != 1) throw new IOException(U.T("请选择 XP12 NG+ Windows 版 ZIP（win_x64/FlyWithLua.xpl）。","XP12 NG+ ZIP required."));
        var root = Path.GetDirectoryName(Path.GetDirectoryName(binaries[0]))!;
        if (!File.Exists(Path.Combine(root, "Internals/FlyWithLua.ini")) || !Directory.Exists(Path.Combine(root, "Modules"))) throw new IOException(U.T("FlyWithLua ZIP 不完整","Incomplete FlyWithLua ZIP"));
        return root;
    }
    public static Dictionary<string, string> Plan(string target, PreparedPackage package, string? fwlRoot)
    {
        ValidateTarget(target); ValidatePackage(package);
        var plan = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var prefix = package.Manifest.Kind == "native" ? "Resources/plugins/StarLux_LMM" : Scripts;
        foreach (var file in package.Manifest.Files) plan.Add(prefix + "/" + file.Path.Replace('\\', '/'), SafePath(package.Root, file.Path));
        if (package.Manifest.Kind == "flywithlua" && !HasFwl(target))
        {
            if (fwlRoot == null) throw new IOException(U.T("缺少 FlyWithLua，未授权安装依赖","FlyWithLua required"));
            // Never replace another installation's user scripts/preferences; deploy only runtime essentials.
            foreach (var f in Files(fwlRoot))
            {
                var rel = Path.GetRelativePath(fwlRoot, f).Replace('\\', '/');
                if (!(rel.StartsWith("win_x64/") || rel.StartsWith("Internals/") || rel.StartsWith("Modules/") || rel.StartsWith("Documentation/") || rel.StartsWith("Custom_Fonts/") || rel is "README.txt" or "LICENSE" or "user.ini" or "user.exit" or "fwl_prefs.ini")) continue;
                if ((rel is "user.ini" or "user.exit" or "fwl_prefs.ini") && File.Exists(SafePath(target, Fwl + "/" + rel))) continue;
                plan.Add(Fwl + "/" + rel, f);
            }
        }
        // Old LMM scripts only; leave all other scripts, reports, settings and airport caches untouched.
        var scripts = Path.Combine(target, Scripts);
        if (Directory.Exists(scripts)) foreach (var old in Directory.GetFiles(scripts, "*.lua").Where(f => MainLua(Path.GetFileName(f)))) plan.TryAdd(Scripts + "/" + Path.GetFileName(old), "");
        foreach (var old in OwnedFiles(target)) plan.TryAdd(old, "");
        if (package.Manifest.Kind == "flywithlua")
        {
            var native = Path.Combine(target, "Resources/plugins/StarLux_LMM");
            if (Directory.Exists(native) && Files(native).Any(f => f.EndsWith(".xpl", StringComparison.OrdinalIgnoreCase)))
                throw new IOException(U.T("检测到原生 StarLux_LMM 插件，请先手动移出其目录，避免双重记录。","Remove native LMM before switching to Lua."));
        }
        foreach (var path in plan.Keys) SafePath(target, path);
        return plan;
    }
    public static string Install(string baseDir, string target, PreparedPackage package, string? fwlRoot, Action<string> log, Action<int> progress, bool checkRunning = true, int failAfter = -1, bool clean = false, IReadOnlyCollection<string>? reviewedPaths = null, string rebuildPendingHash = "")
    {
        if (checkRunning) CheckNotRunning();
        target = NormalizeDirectory(target);
        using var targetLease = new TargetLease(target);
        if(rebuildPendingHash!="")ValidateRebuild(target,rebuildPendingHash);
        else { FinalizePending(target,baseDir,log); CheckPending(target,baseDir); }
        ValidateCompatibility(target, package.Manifest);
        var originalRoot = package.Root;
        package = PreparePreferences(target, package, clean);
        try
        {
            var plan = InstallerTrace.Step(U.T("计算安装与清理计划","Build install and cleanup plan"),target,()=>Plan(target, package, fwlRoot),log);
            if (clean) { plan[Scripts + "/LMM_Settings.cfg"] = ""; plan[Scripts + "/LMM_Log/LMM_Viewer.html"] = ""; plan[Scripts + "/LMM_Log/LMM_Viewer_Data.js"] = ""; }
            if (reviewedPaths != null && !reviewedPaths.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(plan.Keys.Append(Receipt)))
                throw new IOException(U.T("安装范围在确认后发生变化，请重新检查文件清单。", "The installation scope changed after approval. Review the file list again."));
            return ExecutePlan(baseDir, target, plan, package.Manifest, log, progress, checkRunning, failAfter, rebuildPendingHash);
        }
        finally { if (package.Root != originalRoot) { NoLinks(package.Root); Directory.Delete(package.Root, true); } }
    }

    public static void CheckPending(string target, string? installerDirectory = null)
    {
        var marker=SafePath(target,"Resources/plugins/StarLux_LMM.install.pending.json");
        if(!File.Exists(marker))return;
        InstallerTrace.CaptureTarget(target);
        string backup="";
        try
        {
            using var json=JsonDocument.Parse(File.ReadAllText(marker));
            backup=json.RootElement.GetProperty("backup").GetString()??"";
            if(string.IsNullOrWhiteSpace(backup))throw new JsonException("Empty backup path");
        }
        catch(Exception e)
        {
            throw new DiagnosticFailure("PENDING_INVALID",U.T("未完成安装标记无法解析。","Cannot parse the pending installation marker."),
                U.T("保留标记和备份，导出诊断包；不要删除标记后强行安装。","Keep the marker/backups and export diagnostics; do not bypass recovery by deleting the marker."),marker,e);
        }
        var found=FindPendingBackup(target,installerDirectory ?? AppContext.BaseDirectory);
        var exists=found!=""; if(exists)backup=found;
        throw new DiagnosticFailure(exists?"RECOVERY_REQUIRED":"RECOVERY_BACKUP_MISSING",
            U.T("上次操作未完成，需要先恢复对应备份。","An unfinished operation requires recovery.")+"\n"+
            U.T("备份目录：","Backup directory: ")+backup+"\n"+U.T("事务清单：","Transaction: ")+Path.Combine(backup,"transaction.json")+"\n"+
            (exists?U.T("事务清单存在；恢复时还会校验备份文件。","Transaction exists; recovery will also verify backup files."):U.T("该路径下的备份目录或事务清单不存在。","The backup directory or transaction file is missing at this path.")),
            exists?U.T("点击“恢复备份”，选择上述 transaction.json，恢复成功后重新安装。","Choose Restore backup and select the transaction.json above, then reinstall after recovery."):
            U.T("如果移动或重新解压过安装器，请找回原 backup 文件夹；保留现状并导出诊断包。","If the installer was moved/re-extracted, locate its original backup folder. Preserve the current state and export diagnostics."),marker);
    }
    static string ExecutePlan(string baseDir, string target, Dictionary<string,string> plan, PackageManifest? manifest, Action<string> log, Action<int> progress, bool checkRunning, int failAfter, string rebuildPendingHash = "")
    {
        var backupRoot = Path.Combine(baseDir, "backup"); NoLinks(backupRoot);
        if (Path.GetFullPath(backupRoot).StartsWith(target.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) throw new IOException(U.T("请将安装器移到 X-Plane 文件夹外，再安装。","Keep installer/backup outside X-Plane."));
        if(rebuildPendingHash!="")ValidateRebuild(target,rebuildPendingHash);
        else { FinalizePending(target,baseDir,log); CheckPending(target,baseDir); }
        var backup = Path.Combine(backupRoot, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8]);
        PreflightTargets(target, plan.Keys, log);
        var marker = SafePath(target, "Resources/plugins/StarLux_LMM.install.pending.json");
        InstallerTrace.Step(U.T("创建备份目录","Create backup directory"),backup,()=>Directory.CreateDirectory(backup),log);
        if (manifest != null) { var receiptSource = Path.Combine(backup, "new-receipt.json"); InstallerTrace.Step(U.T("生成安装清单","Generate installation receipt"),receiptSource,()=>File.WriteAllText(receiptSource, JsonSerializer.Serialize(manifest, Json)),log); plan[Receipt] = receiptSource; }
        else plan[Receipt] = "";
        var journal = new Journal { Id=Guid.NewGuid().ToString("N"), Target = target, Version = manifest?.Version ?? "uninstall", PreviousPending=rebuildPendingHash!=""?File.ReadAllText(marker):"" };
        if(journal.PreviousPending!="")File.WriteAllText(Path.Combine(backup,"superseded-pending.json"),journal.PreviousPending);
        journal.ResultFiles=plan.Select(p=>new JournalEntry(p.Key,p.Value!="",p.Value!=""?Hash(p.Value):"")).ToList();
        var journalPath = Path.Combine(backup, "transaction.json");
        void Save() => InstallerTrace.Step(U.T("保存事务记录","Save transaction"),journalPath,()=>{File.WriteAllText(journalPath + ".tmp", JsonSerializer.Serialize(journal, Json));File.Move(journalPath + ".tmp", journalPath, true);},log);
        InstallerTrace.Event("PLAN",new {target,backup,version=journal.Version,count=plan.Count});
        foreach (var relative in plan.Keys)
        {
            var path = SafePath(target, relative); var exists = File.Exists(path);
            var hash = exists ? InstallerTrace.Step(U.T("计算原文件校验值","Hash original"),path,()=>Hash(path),log) : "";
            journal.Entries.Add(new(relative, exists, hash));
            if (exists)
            {
                var dest = SafePath(Path.Combine(backup, "files"), relative);
                InstallerTrace.Step(U.T("备份并校验原文件","Back up and verify original"),path+" -> "+dest,()=>{
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);File.Copy(path,dest,false);
                    if(Hash(dest)!=hash)throw new DiagnosticFailure("BACKUP_HASH_MISMATCH",U.T("备份校验失败，尚未写入目标。","Backup verification failed; target not yet changed."),U.T("保留诊断包并检查磁盘和文件占用。","Retain diagnostics and check disk/file access."),dest);
                },log);
            }
            else log(U.T("安装前不存在：","Not present before installation: ")+path);
        }
        Save(); log(U.T("备份已完成：","Backup complete: ")+backup);
        InstallerTrace.Session?.Snapshot("transaction-prepared.json",journalPath);
        if(rebuildPendingHash!="")ValidateRebuild(target,rebuildPendingHash);
        bool committed=false, markerStarted=false;
        try
        {
            if (checkRunning) CheckNotRunning();
            InstallerTrace.Step(U.T("写入未完成标记","Write pending marker"),marker,()=>WriteTextAtomic(marker, JsonSerializer.Serialize(new PendingRecovery { Backup=backup, TransactionId=journal.Id, OriginalStateHash=StateHash(journal) }, Json)),log);
            markerStarted=true;
            journal.Status = "installing"; Save(); int count = 0;
            foreach (var (relative, source) in plan)
            {
                var dest = SafePath(target, relative);
                if (source.Length == 0) InstallerTrace.Step(U.T("清理旧文件","Remove obsolete file"),dest,()=>File.Delete(dest),log);
                else InstallerTrace.Step(U.T("部署并校验文件","Deploy and verify file"),source+" -> "+dest,()=>{
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);File.Copy(source,dest,true);
                    var expected=Hash(source);var actual=Hash(dest);
                    if(expected!=actual)throw new DiagnosticFailure("WRITE_HASH_MISMATCH",U.T("写入后校验失败。","Post-write checksum mismatch.")+$"\nExpected: {expected}\nActual: {actual}",U.T("将执行回滚；请保留诊断日志。","Rollback will be attempted; retain the diagnostic log."),dest);
                },log);
                if (++count == failAfter) {var injected=new IOException("Injected test failure");injected.Data["LMM.Step"]="After deployment";injected.Data["LMM.Path"]=dest;throw injected;}
                progress(count * 100 / plan.Count);
            }
            InstallerTrace.Step(U.T("清理旧 UI 空目录","Prune empty UI directories"),target,()=>PruneEmptyUiDirectories(target),log);
            var logDirectory = SafePath(target, Scripts + "/LMM_Log");
            if (Directory.Exists(logDirectory) && !Directory.EnumerateFileSystemEntries(logDirectory).Any()) Directory.Delete(logDirectory, false);
            journal.Status = "completed"; Save(); committed=true;
            InstallerTrace.Step(U.T("清除未完成标记","Clear pending marker"),marker,()=>File.Delete(marker),log);
            InstallerTrace.Session?.Snapshot("transaction-completed.json",journalPath);
            InstallerTrace.CaptureTarget(target);return backup;
        }
        catch (Exception installError)
        {
            if(committed)throw new DiagnosticFailure("FINALIZE_REQUIRED",U.T("安装已完成，但事务收尾失败；没有回退已完成的安装。", "Installation completed but finalization failed; the completed installation was not rolled back."),U.T("重新运行安装器，核对文件后重试收尾。", "Run the installer again to verify files and retry finalization."),marker,installError);
            // Record the original failure BEFORE rollback, retaining both exception stacks if recovery fails.
            log(InstallerTrace.Fault(U.T("安装首次失败","Original installation failure"),installError));
            journal.Status="failed";journal.Failure=installError.ToString();
            try {Save();}catch(Exception journalError){InstallerTrace.Fault("Save failed transaction",journalError);}
            if(!markerStarted)throw; // No target files were changed; leave any prior pending marker intact.
            try { Restore(backup, target, false,log);log(U.T("安装失败，原文件已恢复。","Installation failed; original files restored.")); }
            catch (Exception restoreError)
            {
                log(InstallerTrace.Fault(U.T("自动回滚失败","Automatic rollback failed"),restoreError));
                journal.RollbackFailure=restoreError.ToString();try{Save();}catch(Exception saveError){InstallerTrace.Fault("Save rollback failure",saveError);}
                InstallerTrace.Session?.Snapshot("transaction-recovery-required.json",journalPath);
                throw new DiagnosticFailure("ROLLBACK_FAILED",U.T("安装失败且回滚未完成。","Installation failed and rollback did not finish.")+
                    "\n"+U.T("首次错误：","Original error: ")+installError.Message+"\n"+U.T("回滚错误：","Rollback error: ")+restoreError.Message,
                    U.T("保留此备份，导出诊断包后排查：","Keep this backup and export diagnostics: ")+backup,backup,new AggregateException(installError,restoreError));
            }
            throw;
        }
    }
    public static void Restore(string backup, string expectedTarget, bool checkRunning = true,Action<string>? log=null)
    {
        if (checkRunning) CheckNotRunning();
        using var targetLease = new TargetLease(expectedTarget);
        NoLinks(backup);
        var file = Path.Combine(backup, "transaction.json");
        InstallerTrace.Session?.Snapshot("transaction-before-restore.json",file);
        var journal = InstallerTrace.Step(U.T("读取恢复事务","Read recovery transaction"),file,()=>ReadJournal(backup,expectedTarget),log);
        var pendingPath=SafePath(expectedTarget,Pending);
        var pendingHash=File.Exists(pendingPath)?Hash(pendingPath):"";
        if(pendingHash!="" && !MatchesPending(ReadPending(expectedTarget),backup,journal))throw new DiagnosticFailure("WRONG_RECOVERY_TRANSACTION",U.T("所选备份不是当前未完成事务，尚未更改任何文件。", "This backup does not match the pending transaction. No files changed."),U.T("选择当前提示对应的备份，旧备份不能替代本次恢复。", "Select the backup matching the pending transaction, not an unrelated older backup."),file);
        if (!NormalizeDirectory(journal.Target).Equals(NormalizeDirectory(expectedTarget), StringComparison.OrdinalIgnoreCase)) throw new DiagnosticFailure("BACKUP_TARGET_MISMATCH",U.T("备份属于其他 X-Plane 目录。","Backup belongs to a different simulator.")+$"\nBackup target: {journal.Target}\nSelected target: {expectedTarget}",U.T("选择属于当前 X-Plane 目录的事务，不要修改备份清单。","Select a transaction for this simulator; do not edit the journal."),file);
        ValidateTarget(journal.Target);
        // Validate every original BEFORE restoring any file.
        foreach (var entry in journal.Entries)
        {
            var rel = entry.Path.Replace('\\', '/');
            InstallerTrace.Step(U.T("验证恢复文件","Verify recovery file"),rel,()=>{
                if (!(rel.StartsWith(Fwl + "/", StringComparison.OrdinalIgnoreCase) || rel.StartsWith("Resources/plugins/StarLux_LMM/", StringComparison.OrdinalIgnoreCase) || rel == Receipt)) throw new IOException(U.T("非法备份路径","Invalid backup path"));
                SafePath(journal.Target, rel);
                var saved=SafePath(Path.Combine(backup,"files"),rel);
                if (entry.Existed && !File.Exists(saved)) throw new FileNotFoundException(U.T("备份文件缺失，尚未开始恢复。","Backup file missing; restore has not started."),saved);
                if (entry.Existed && entry.Sha256.Length > 0 && !Hash(saved).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase)) throw new DiagnosticFailure("BACKUP_HASH_MISMATCH",U.T("备份文件校验失败。","Backup checksum mismatch."),U.T("请保留整个备份并导出诊断包。","Keep the entire backup and export diagnostics."),saved);
            },log);
        }
        if((File.Exists(pendingPath)?Hash(pendingPath):"")!=pendingHash)throw new IOException("Pending transaction changed during validation");
        PreflightTargets(expectedTarget,journal.Entries.Select(e=>e.Path),log ?? InstallerTrace.Write);
        foreach (var entry in journal.Entries.AsEnumerable().Reverse())
        {
            var dest = SafePath(journal.Target, entry.Path);
            InstallerTrace.Step(entry.Existed?U.T("恢复原文件","Restore original file"):U.T("移除本次新增文件","Remove newly installed file"),dest,()=>{
                if (entry.Existed) { Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(SafePath(Path.Combine(backup, "files"), entry.Path), dest, true);
                    if(entry.Sha256.Length>0 && !Hash(dest).Equals(entry.Sha256,StringComparison.OrdinalIgnoreCase))throw new IOException("Restored file checksum mismatch: "+dest);
                }
                else File.Delete(dest);
            },log);
        }
        journal.Status = "restored"; InstallerTrace.Step(U.T("保存恢复结果","Save recovery result"),file,()=>WriteTextAtomic(file, JsonSerializer.Serialize(journal, Json)),log);
        var marker = SafePath(journal.Target, "Resources/plugins/StarLux_LMM.install.pending.json");
        if (File.Exists(marker))
        {
            if (MatchesPending(ReadPending(journal.Target),backup,journal))
                InstallerTrace.Step(U.T("完成对应事务恢复","Finalize matching recovery"),marker,()=> { if(journal.PreviousPending!="")WriteTextAtomic(marker,journal.PreviousPending);else File.Delete(marker); },log);
            else InstallerTrace.Write("A different pending transaction remains; its marker was preserved.");
        }
        InstallerTrace.Session?.Snapshot("transaction-restored.json",file);InstallerTrace.CaptureTarget(journal.Target);
    }
}
