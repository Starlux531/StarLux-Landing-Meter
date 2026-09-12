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
    public string Target { get; set; } = "";
    public string Status { get; set; } = "prepared";
    public string Version { get; set; } = "";
    public List<JournalEntry> Entries { get; set; } = [];
}
public record JournalEntry(string Path, bool Existed, string Sha256 = "");

public static class Core
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
            if (!acquired) { mutex.Dispose(); throw new IOException("此 X-Plane 正在被其他安装器修改，请稍后重试。 / Another installer is modifying this simulator."); }
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
            return ([N(1), N(2), N(3)], m.Groups[4].Value.ToLowerInvariant() switch { "alpha" => 0, "beta" => 1, "rc" => 2, _ => 3 }, N(5));
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
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains(':')) throw new IOException("非法路径 / Invalid relative path: " + relative);
        var parts = relative.Replace('\\', '/').Split('/');
        if (parts.Any(p => p is ".." or "." or "" || p.EndsWith(' ') || p.EndsWith('.') || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Regex.IsMatch(p, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase)))
            throw new IOException("非法路径 / Invalid relative path: " + relative);
        var full = Path.GetFullPath(Path.Combine(root, relative));
        var prefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException("路径超出目标 / Path escapes target");
        NoLinks(full);
        return full;
    }
    public static void NoLinks(string path)
    {
        for (var p = Path.GetFullPath(path); p != null; p = Path.GetDirectoryName(p))
            if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("为保证备份安全，不支持符号链接或目录联接 / Reparse point: " + p);
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
        if (!IsXPlane(path)) throw new IOException("请选择含 X-Plane.exe 和 Resources/plugins 的 X-Plane 根目录。 / Select the X-Plane root.");
        NoLinks(path);
        // Avoid interpreting an XP11 installation as an XP12 target. Missing metadata remains user-confirmed.
        var version = FileVersionInfo.GetVersionInfo(Path.Combine(path, "X-Plane.exe")).ProductMajorPart;
        if (version > 0 && version < 12) throw new IOException("本安装器面向 X-Plane 12，不支持 X-Plane 11。 / X-Plane 12 required.");
    }
    public static void CheckNotRunning()
    {
        if (Process.GetProcessesByName("X-Plane").Length > 0) throw new IOException("请完全退出 X-Plane 后再安装或恢复。 / Exit X-Plane before installing or restoring.");
    }
    public static bool HasFwl(string root) => new[] { "win_x64/FlyWithLua.xpl", "64/win.xpl" }.Any(p => File.Exists(Path.Combine(root, Fwl, p)))
        && File.Exists(Path.Combine(root, Fwl, "Internals/FlyWithLua.ini"));
    public static InstalledState Inspect(string root)
    {
        if (!IsXPlane(root)) return new("", "尚未选择有效的 X-Plane 根目录 / No valid X-Plane folder selected", false);
        var scripts = Path.Combine(root, Scripts);
        var mains = Directory.Exists(scripts) ? Directory.GetFiles(scripts, "*.lua").Where(f => MainLua(Path.GetFileName(f))).ToArray() : [];
        var v = mains.Length == 0 ? "" : string.Join(", ", mains.Select(f => ExtractVersion(Path.GetFileName(f))));
        var details = mains.Length switch { 0 => "未安装 / Not installed", 1 => "已安装 / Installed: " + v, _ => "检测到多个主脚本，安装时将备份旧脚本 / Multiple active scripts: " + v };
        var receipt = Path.Combine(root, Receipt);
        if (File.Exists(receipt))
        {
            try
            {
                var m = JsonSerializer.Deserialize<PackageManifest>(File.ReadAllText(receipt), Json)!;
                var prefix = m.Kind == "native" ? "Resources/plugins/StarLux_LMM" : Scripts;
                var valid = m.Files.Count > 0 && m.Files.All(f => { var p = SafePath(Path.Combine(root, prefix), f.Path); return File.Exists(p) && Hash(p) == f.Sha256; });
                if (valid) { v = m.Version; details = $"已安装 / Installed: {v} · {m.Build}（文件校验通过 / verified）"; }
                else details += "\n安装记录与文件不一致，建议重新安装 / Receipt differs; repair recommended";
            }
            catch { details += "\n安装记录无法读取 / Invalid receipt"; }
        }
        return new(v, details, HasFwl(root));
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
                if (m.Product != "StarLux_LMM" || m.Schema != 1 || ExtractVersion(m.Version) == "") throw new IOException("无效清单 / Invalid manifest");
                result.Add(new Release { Version = m.Version, Build = m.Build, UiVariant = m.UiVariant, DefaultLanguage = m.DefaultLanguage, LocalDirectory = dir });
            }
            catch (Exception e) { log($"本地版本忽略 / Skipped: {f}: {e.Message}"); }
        }
        return result.OrderByDescending(r => r.Version, Comparer<string>.Create(CompareVersion)).ToList();
    }
    public static void ExtractZip(string zip, string destination)
    {
        using var archive = ZipFile.OpenRead(zip);
        long total = 0; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (archive.Entries.Count > 20000) throw new IOException("ZIP 文件过多 / Too many ZIP entries");
        foreach (var entry in archive.Entries)
        {
            // Reject Unix symlinks, Windows reparse points, traversal, duplicate Windows paths and zip bombs.
            if (((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000 || (entry.ExternalAttributes & 0x400) != 0) throw new IOException("ZIP 不允许链接 / ZIP links forbidden");
            var relative = entry.FullName.Replace('\\', '/').TrimEnd('/'); if (relative == "") continue;
            var target = SafePath(destination, relative);
            if (!seen.Add(relative)) throw new IOException("ZIP 重复路径 / Duplicate ZIP path: " + relative);
            if (entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\')) { Directory.CreateDirectory(target); continue; }
            total += entry.Length;
            if (entry.Length > 256L * 1024 * 1024 || total > 512L * 1024 * 1024) throw new IOException("ZIP 超出大小限制 / ZIP size limit");
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, false);
        }
    }
    public static PreparedPackage Prepare(string directory, string version = "")
    {
        var manifestFile = Path.Combine(directory, "manifest.json");
        if (File.Exists(manifestFile))
        {
            var manifest = JsonSerializer.Deserialize<PackageManifest>(File.ReadAllText(manifestFile), Json) ?? throw new IOException("空清单 / Empty manifest");
            var prepared = new PreparedPackage(manifest, Path.Combine(directory, "payload")); ValidatePackage(prepared);
            if (version.Length > 0 && CompareVersion(version, manifest.Version) != 0) throw new IOException("所选版本与清单不一致 / Manifest version mismatch");
            return prepared;
        }
        // Historic release ZIPs are not repository snapshots. Only a unique active payload is accepted.
        var all = Files(directory).ToArray();
        var manifests = all.Where(f => Path.GetFileName(f) == "manifest.json" && !f.Contains(Path.DirectorySeparatorChar + "fonts" + Path.DirectorySeparatorChar)).ToArray();
        if (manifests.Length == 1) return Prepare(Path.GetDirectoryName(manifests[0])!, version);
        var mains = all.Where(f => MainLua(Path.GetFileName(f))).ToArray();
        if (mains.Length != 1) throw new IOException("发布包应只有一个 LMM 主脚本；不接受含历史备份的仓库快照。 / Ambiguous package; use release ZIP.");
        var root = Path.GetDirectoryName(mains[0])!;
        var m = new PackageManifest { Version = ExtractVersion(Path.GetFileName(mains[0])), Build = "legacy-release", Notes = "历史发布包 / Legacy release" };
        if (version.Length > 0 && CompareVersion(version, m.Version) != 0) throw new IOException("所选版本与主脚本不一致 / Release version mismatch");
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
        if (m.Schema != 1 || m.Product != "StarLux_LMM" || ExtractVersion(m.Version) == "" || m.Kind is not ("flywithlua" or "native") || m.Files.Count == 0 || m.Files.Count > 2000) throw new IOException("不支持的安装清单 / Unsupported manifest");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in m.Files)
        {
            if (!seen.Add(f.Path.Replace('\\', '/')) || !Allowed(m.Kind, f.Path)) throw new IOException("不允许的载荷文件 / Disallowed payload: " + f.Path);
            var path = SafePath(package.Root, f.Path);
            if (!Regex.IsMatch(f.Sha256, "^[a-fA-F0-9]{64}$") || !File.Exists(path) || !Hash(path).Equals(f.Sha256, StringComparison.OrdinalIgnoreCase)) throw new IOException("文件校验失败 / SHA256 mismatch: " + f.Path);
        }
        if (m.Kind == "flywithlua" && m.Files.Count(f => MainLua(f.Path)) != 1) throw new IOException("必须只有一个主脚本 / Exactly one main script required");
        if (m.Kind == "flywithlua")
        {
            var fileVersion = ExtractVersion(m.Files.Single(f => MainLua(f.Path)).Path);
            if (fileVersion.Length > 0 && CompareVersion(fileVersion, m.Version) != 0) throw new IOException("主脚本文件名版本与清单不同 / Main script version differs from manifest");
        }
        if (m.Kind == "native" && !m.Files.Any(f => f.Path.Replace('\\', '/').Equals("win_x64/StarLux_LMM.xpl", StringComparison.OrdinalIgnoreCase))) throw new IOException("缺少原生插件 / Missing native plugin");
    }
    public static string FindFwl(string extracted)
    {
        var binaries = Files(extracted).Where(f => Path.GetFileName(f).Equals("FlyWithLua.xpl", StringComparison.OrdinalIgnoreCase) && Path.GetFileName(Path.GetDirectoryName(f)) == "win_x64").ToArray();
        if (binaries.Length != 1) throw new IOException("请选择 XP12 NG+ Windows 版 ZIP（win_x64/FlyWithLua.xpl）。 / XP12 NG+ ZIP required.");
        var root = Path.GetDirectoryName(Path.GetDirectoryName(binaries[0]))!;
        if (!File.Exists(Path.Combine(root, "Internals/FlyWithLua.ini")) || !Directory.Exists(Path.Combine(root, "Modules"))) throw new IOException("FlyWithLua ZIP 不完整 / Incomplete FlyWithLua ZIP");
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
            if (fwlRoot == null) throw new IOException("缺少 FlyWithLua，未授权安装依赖 / FlyWithLua required");
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
        if (package.Manifest.Kind == "flywithlua")
        {
            var native = Path.Combine(target, "Resources/plugins/StarLux_LMM");
            if (Directory.Exists(native) && Files(native).Any(f => f.EndsWith(".xpl", StringComparison.OrdinalIgnoreCase)))
                throw new IOException("检测到原生 StarLux_LMM 插件，请先手动移出其目录，避免双重记录。 / Remove native LMM before switching to Lua.");
        }
        foreach (var path in plan.Keys) SafePath(target, path);
        return plan;
    }
    public static string Install(string baseDir, string target, PreparedPackage package, string? fwlRoot, Action<string> log, Action<int> progress, bool checkRunning = true, int failAfter = -1)
    {
        if (checkRunning) CheckNotRunning();
        target = NormalizeDirectory(target);
        using var targetLease = new TargetLease(target);
        var plan = Plan(target, package, fwlRoot);
        var backupRoot = Path.Combine(baseDir, "backup"); NoLinks(backupRoot);
        // Keep recovery data outside the simulator tree; user must move an installer placed inside XP.
        if (Path.GetFullPath(backupRoot).StartsWith(target.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) throw new IOException("请将安装器移到 X-Plane 文件夹外，再安装。 / Keep installer/backup outside X-Plane.");
        var backup = Path.Combine(backupRoot, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8]);
        // A portable installer may have been moved. Also check an in-target marker from an interrupted run.
        var marker = SafePath(target, "Resources/plugins/StarLux_LMM.install.pending.json");
        if (File.Exists(marker)) throw new IOException("发现未完成的安装，请先恢复标记中指定的备份 / Restore incomplete installation first: " + File.ReadAllText(marker));
        Directory.CreateDirectory(backup);
        var receiptSource = Path.Combine(backup, "new-receipt.json"); File.WriteAllText(receiptSource, JsonSerializer.Serialize(package.Manifest, Json)); plan[Receipt] = receiptSource;
        var journal = new Journal { Target = target, Version = package.Manifest.Version };
        var journalPath = Path.Combine(backup, "transaction.json");
        void Save() { File.WriteAllText(journalPath + ".tmp", JsonSerializer.Serialize(journal, Json)); File.Move(journalPath + ".tmp", journalPath, true); }
        // All originals are copied BEFORE any target writes. Backup failure leaves target untouched.
        foreach (var relative in plan.Keys)
        {
            var path = SafePath(target, relative); var exists = File.Exists(path);
            var hash = exists ? Hash(path) : "";
            journal.Entries.Add(new(relative, exists, hash));
            if (exists) { var dest = SafePath(Path.Combine(backup, "files"), relative); Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(path, dest, false); if (Hash(dest) != hash) throw new IOException("备份校验失败，未修改目标 / Backup verification failed; target unchanged"); }
        }
        Save(); log("备份 / Backup: " + backup);
        try
        {
            if (checkRunning) CheckNotRunning();
            File.WriteAllText(marker, JsonSerializer.Serialize(new { backup }, Json));
            journal.Status = "installing"; Save(); int count = 0;
            foreach (var (relative, source) in plan)
            {
                var dest = SafePath(target, relative);
                if (source.Length == 0) File.Delete(dest);
                else { Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(source, dest, true); if (Hash(source) != Hash(dest)) throw new IOException("写入后校验失败 / Write verification failed: " + relative); }
                if (++count == failAfter) throw new IOException("Injected test failure");
                progress(count * 100 / plan.Count);
            }
            journal.Status = "completed"; Save(); File.Delete(marker); return backup;
        }
        catch (Exception installError)
        {
            try { Restore(backup, target, false); log("安装失败，原文件已恢复 / Failed; originals restored"); }
            catch (Exception restoreError) { throw new IOException($"安装失败且回滚未完成，请保留备份 / Recovery required: {backup}\n{installError.Message}\n{restoreError.Message}"); }
            throw;
        }
    }
    public static void Restore(string backup, string expectedTarget, bool checkRunning = true)
    {
        if (checkRunning) CheckNotRunning();
        using var targetLease = new TargetLease(expectedTarget);
        NoLinks(backup);
        var file = Path.Combine(backup, "transaction.json");
        var journal = JsonSerializer.Deserialize<Journal>(File.ReadAllText(file), Json) ?? throw new IOException("无效备份 / Invalid backup");
        if (!NormalizeDirectory(journal.Target).Equals(NormalizeDirectory(expectedTarget), StringComparison.OrdinalIgnoreCase)) throw new IOException("备份属于其他 X-Plane 目录 / Backup target mismatch");
        ValidateTarget(journal.Target);
        // Validate the full journal before touching any file, including manually altered journals.
        foreach (var entry in journal.Entries)
        {
            var rel = entry.Path.Replace('\\', '/');
            if (!(rel.StartsWith(Fwl + "/", StringComparison.OrdinalIgnoreCase) || rel.StartsWith("Resources/plugins/StarLux_LMM/", StringComparison.OrdinalIgnoreCase) || rel == Receipt)) throw new IOException("非法备份路径 / Invalid backup path");
            SafePath(journal.Target, rel);
            if (entry.Existed && !File.Exists(SafePath(Path.Combine(backup, "files"), rel))) throw new IOException("备份缺失 / Missing backup file: " + rel);
            if (entry.Existed && entry.Sha256.Length > 0 && !Hash(SafePath(Path.Combine(backup, "files"), rel)).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase)) throw new IOException("备份文件校验失败 / Backup file checksum mismatch: " + rel);
        }
        foreach (var entry in journal.Entries.AsEnumerable().Reverse())
        {
            var dest = SafePath(journal.Target, entry.Path);
            if (entry.Existed) { Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(SafePath(Path.Combine(backup, "files"), entry.Path), dest, true); }
            else File.Delete(dest);
        }
        journal.Status = "restored"; File.WriteAllText(file, JsonSerializer.Serialize(journal, Json));
        var marker = SafePath(journal.Target, "Resources/plugins/StarLux_LMM.install.pending.json");
        if (File.Exists(marker))
        {
            // Never clear a different pending transaction when the user selected an older backup.
            using var m = JsonDocument.Parse(File.ReadAllText(marker));
            if (m.RootElement.TryGetProperty("backup", out var b) && Path.GetFullPath(b.GetString() ?? "").Equals(Path.GetFullPath(backup), StringComparison.OrdinalIgnoreCase)) File.Delete(marker);
        }
    }
}
