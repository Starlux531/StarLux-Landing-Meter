using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StarLux.Installer;

public sealed class Diagnosis
{
    public bool ValidTarget { get; set; }
    public string Version { get; set; } = "";
    public string SimulatorVersion { get; set; } = "";
    public bool HasFlyWithLua { get; set; }
    public bool HasPlugin { get; set; }
    public bool Verified { get; set; }
    public List<string> Issues { get; set; } = [];
    public string Describe() => !ValidTarget ? U.T("请选择 X-Plane 根目录", "Select an X-Plane folder") :
        !HasPlugin ? U.T("未安装插件", "Plugin not installed") :
        string.Join("\n", new[] { U.T("插件版本：", "Plugin version: ") + (Version.Length > 0 ? Version : U.T("未知", "Unknown")) }
            .Concat(Issues.Count > 0 ? Issues : [U.T("文件校验通过", "Files verified")]));
}

public static partial class Core
{
    public static string SimulatorVersion(string root)
    {
        if (!IsXPlane(root)) return "";
        try
        {
            var info = FileVersionInfo.GetVersionInfo(Path.Combine(root, "X-Plane.exe"));
            var version = ExtractVersion(info.ProductVersion ?? "");
            if (version.Length > 0) return version;
        }
        catch { }
        var log = SafePath(root, "Log.txt");
        if (File.Exists(log))
            foreach (var line in File.ReadLines(log).Take(30))
            {
                var match = Regex.Match(line, @"^(?:log\.txt for )?X-Plane\s+(\d+\.\d+(?:\.\d+)?)", RegexOptions.IgnoreCase);
                if (match.Success) return match.Groups[1].Value;
            }
        return "";
    }
    public static string Variant(Release r) => r.UiVariant.Length > 0 ? r.UiVariant :
        r.Variant.Contains("Compatibility", StringComparison.OrdinalIgnoreCase) ? "legacy" :
        r.Variant.Contains("Standard", StringComparison.OrdinalIgnoreCase) ? "sdk440" : "";
    public static bool Compatible(string xpVersion, string variant) => xpVersion == "" ||
        CompareVersion(xpVersion, "12.0") >= 0 && (variant != "sdk440" || CompareVersion(xpVersion, "12.4.4") >= 0);
    public static void ValidateCompatibility(string root, PackageManifest manifest)
    {
        var version = SimulatorVersion(root);
        if (!Compatible(version, manifest.UiVariant)) throw new IOException(U.T(
            "所选插件与 X-Plane 版本不匹配，请选择兼容版。", "The selected plugin is incompatible with this X-Plane version. Select Compatibility."));
    }
    static string InstalledVariant(string target, PackageManifest manifest)
    {
        if (manifest.UiVariant.Length > 0) return manifest.UiVariant;
        if (manifest.Kind != "flywithlua") return "";
        var main = manifest.Files.FirstOrDefault(f => MainLua(f.Path));
        if (main == null) return "";
        var path = SafePath(target, Scripts + "/" + main.Path);
        if (!File.Exists(path)) return "";
        var text = File.ReadAllText(path);
        return text.Contains("LMM_UI_") ? Regex.IsMatch(text, @"force_compatibility\s*=\s*true") ? "legacy" : "sdk440" : "";
    }
    static PackageManifest? ReadReceipt(string target)
    {
        var file = SafePath(target, Receipt);
        if (!File.Exists(file)) return null;
        var m = JsonSerializer.Deserialize<PackageManifest>(File.ReadAllText(file), Json);
        if (m == null || m.Product != "StarLux_LMM" || m.Schema != 1 || m.Kind is not ("flywithlua" or "native") || m.UiVariant is not ("" or "sdk440" or "legacy") || m.Files == null || m.Files.Count is 0 or > 2000 || string.IsNullOrWhiteSpace(m.Version) || ExtractVersion(m.Version) != m.Version)
            throw new IOException(U.T("安装记录无效", "Invalid installation receipt"));
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in m.Files)
            if (f == null || string.IsNullOrEmpty(f.Path) || string.IsNullOrEmpty(f.Sha256) || !Allowed(m.Kind, f.Path) || !seen.Add(f.Path.Replace('\\', '/')) || !Regex.IsMatch(f.Sha256, "^[a-fA-F0-9]{64}$"))
                throw new IOException(U.T("安装记录包含无效文件", "Invalid file in installation receipt"));
        if(m.Kind == "flywithlua" && (m.Files.Count(f=>MainLua(f.Path)) != 1 || CompareVersion(ExtractVersion(m.Files.Single(f=>MainLua(f.Path)).Path),m.Version) != 0))
            throw new IOException(U.T("安装记录与主脚本版本不符", "Receipt and main script versions differ"));
        return m;
    }
    // Only identifiable LMM code/assets. Never enumerate browser profiles or remove shared FWL.
    public static List<string> OwnedFiles(string target)
    {
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var scripts = SafePath(target, Scripts);
        if (Directory.Exists(scripts))
        {
            foreach (var path in Directory.EnumerateFiles(scripts, "*.lua")) if (MainLua(Path.GetFileName(path))) files.Add(Scripts + "/" + Path.GetFileName(path));
            foreach (var path in Directory.EnumerateFiles(scripts, "README*"))
            {
                // Versioned names alone are not proof of ownership in shared Scripts.
                if (!Regex.IsMatch(Path.GetFileName(path), @"^README_\d+\.\d+(?:\.\d+)?(?:beta\d*)?\.(?:md|txt)$", RegexOptions.IgnoreCase)) continue;
                NoLinks(path);
                using var reader = new StreamReader(path);
                var buffer = new char[2048]; var count = reader.Read(buffer, 0, buffer.Length);
                if (new string(buffer, 0, count).Contains("StarLux", StringComparison.OrdinalIgnoreCase)) files.Add(Scripts + "/" + Path.GetFileName(path));
            }
            if (File.Exists(SafePath(target, Scripts + "/LMM_Report_Reader.html"))) files.Add(Scripts + "/LMM_Report_Reader.html");
            foreach (var dir in Directory.EnumerateDirectories(scripts, "LMM_UI_*"))
                if (Regex.IsMatch(Path.GetFileName(dir), "^LMM_UI_[0-9]+$"))
                    foreach (var f in Files(dir))
                    {
                        var relative = Path.GetRelativePath(scripts, f).Replace('\\', '/');
                        if (Allowed("flywithlua", relative)) files.Add(Scripts + "/" + relative);
                    }
        }
        // A damaged receipt cannot authorize broader deletions; known Lua paths still repair.
        PackageManifest? receipt = null;
        try { receipt = ReadReceipt(target); } catch (IOException) { } catch (JsonException) { }
        if (receipt != null)
        {
            var prefix = receipt.Kind == "native" ? "Resources/plugins/StarLux_LMM" : Scripts;
            foreach (var f in receipt.Files)
            {
                // Shared top-level LICENSE/README are not removed on uninstall or upgrades.
                if (receipt.Kind == "flywithlua" && (f.Path == "LICENSE" || f.Path.StartsWith("README", StringComparison.OrdinalIgnoreCase))) continue;
                var path = prefix + "/" + f.Path;
                if (File.Exists(SafePath(target, path))) files.Add(path);
            }
        }
        foreach (var f in files) SafePath(target, f);
        return files.ToList();
    }
    static void PruneEmptyUiDirectories(string target)
    {
        var scripts = SafePath(target, Scripts);
        if (!Directory.Exists(scripts)) return;
        foreach (var dir in Directory.EnumerateDirectories(scripts, "LMM_UI_*"))
        {
            if (!Regex.IsMatch(Path.GetFileName(dir), "^LMM_UI_[0-9]+$")) continue;
            NoLinks(dir);
            // Only remove empty known module/font directories. Unknown contents stay.
            var fonts = SafePath(target, Scripts + "/" + Path.GetFileName(dir) + "/fonts");
            if (Directory.Exists(fonts) && !Directory.EnumerateFileSystemEntries(fonts).Any()) Directory.Delete(fonts, false);
            if (!Directory.EnumerateFileSystemEntries(dir).Any()) Directory.Delete(dir, false);
        }
    }
    public static Diagnosis Diagnose(string target)
    {
        var d = new Diagnosis { ValidTarget = IsXPlane(target) };
        if (!d.ValidTarget) return d;
        NoLinks(target);
        d.SimulatorVersion = SimulatorVersion(target); d.HasFlyWithLua = HasFwl(target);
        var files = OwnedFiles(target);
        d.HasPlugin = files.Count > 0 || File.Exists(SafePath(target, Receipt));
        if (!d.HasPlugin) return d;
        if (File.Exists(SafePath(target,"Resources/plugins/StarLux_LMM.install.pending.json"))) d.Issues.Add(U.T("上次操作未完成，请先恢复对应备份", "An interrupted operation requires backup recovery"));
        var mains = files.Where(f => MainLua(Path.GetFileName(f)) && Path.GetDirectoryName(f)?.Replace('\\', '/') == Scripts).ToList();
        d.Version = mains.Select(f => ExtractVersion(Path.GetFileName(f))).OrderByDescending(v => v, Comparer<string>.Create(CompareVersion)).FirstOrDefault() ?? "";
        if (mains.Count > 1) d.Issues.Add(U.T("混装：存在多个启用的主脚本", "Mixed installation: multiple active main scripts"));
        PackageManifest? receipt = null;
        try { receipt = ReadReceipt(target); } catch (Exception e) when (e is IOException or JsonException) { d.Issues.Add(U.T("安装记录损坏，需要修复", "Damaged receipt; repair required")); }
        if (receipt != null)
        {
            d.Version = receipt.Version;
            var prefix = receipt.Kind == "native" ? "Resources/plugins/StarLux_LMM" : Scripts;
            var expected = new HashSet<string>(receipt.Files.Select(f => prefix + "/" + f.Path.Replace('\\', '/')), StringComparer.OrdinalIgnoreCase);
            foreach (var f in receipt.Files)
            {
                var p = SafePath(target, prefix + "/" + f.Path);
                if (!File.Exists(p)) d.Issues.Add(U.T("缺失：", "Missing: ") + f.Path);
                else if (!Hash(p).Equals(f.Sha256, StringComparison.OrdinalIgnoreCase)) d.Issues.Add(U.T("文件不匹配：", "File mismatch: ") + f.Path);
            }
            foreach (var extra in files.Where(f => !expected.Contains(f))) d.Issues.Add(U.T("旧版残留或混装：", "Obsolete or mixed file: ") + Path.GetRelativePath(Scripts, extra));
            if (!Compatible(d.SimulatorVersion, InstalledVariant(target,receipt))) d.Issues.Add(U.T("插件 UI 与 X-Plane 版本不兼容", "Plugin UI is incompatible with X-Plane"));
            if (receipt.Kind == "flywithlua" && !d.HasFlyWithLua) d.Issues.Add(U.T("FlyWithLua 缺失或不完整", "FlyWithLua is missing or incomplete"));
        }
        else
        {
            d.Issues.Add(U.T("缺少有效安装清单，无法确认完整性；建议修复", "No valid receipt; integrity unknown. Repair recommended."));
            if (mains.Count == 0) d.Issues.Add(U.T("缺少主脚本", "Main script missing"));
        }
        if (d.SimulatorVersion == "") d.Issues.Add(U.T("无法识别 X-Plane 版本，兼容性待确认", "X-Plane version unknown; compatibility unverified"));
        d.Verified = receipt != null && d.Issues.Count == 0;
        return d;
    }
    public static Release? RepairRelease(IEnumerable<Release> releases, Diagnosis d)
    {
        // Prefer the installed version, but select the correct UI variant for the simulator.
        return releases.Where(r => Compatible(d.SimulatorVersion, Variant(r)))
            .OrderBy(r => CompareVersion(r.Version, d.Version) == 0 ? 0 : 1)
            .ThenByDescending(r => r.Version, Comparer<string>.Create(CompareVersion))
            .ThenBy(r => Variant(r) == (d.SimulatorVersion != "" && CompareVersion(d.SimulatorVersion, "12.4.4") < 0 ? "legacy" : "sdk440") ? 0 : 1)
            .ThenBy(r => r.DefaultLanguage == U.Language || r.Variant.Contains(U.Language == "en" ? "International" : "-CN", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .ThenBy(r => r.LocalDirectory.Length == 0).FirstOrDefault();
    }
    public static string Uninstall(string baseDir, string target, Action<string> log, Action<int> progress, bool checkRunning = true, int failAfter = -1)
    {
        ValidateTarget(target); if (checkRunning) CheckNotRunning();
        target = NormalizeDirectory(target); using var lease = new TargetLease(target);
        var plan = OwnedFiles(target).ToDictionary(f => f, _ => "", StringComparer.OrdinalIgnoreCase);
        // Generated viewer code must not keep loading an uninstalled plugin; reports/cache stay.
        foreach (var f in new[] { "LMM_Viewer.html", "LMM_Viewer_Data.js" }) plan[Scripts + "/LMM_Log/" + f] = "";
        return ExecutePlan(baseDir, target, plan, null, log, progress, checkRunning, failAfter);
    }
    public const string ResetStart = "<!-- LMM_INSTALLER_RESET_START -->";
    public const string ResetEnd = "<!-- LMM_INSTALLER_RESET_END -->";
    public static string ResetScript(string token) => ResetStart + "<script>(function(){try{const token=" + JsonSerializer.Serialize(token) +
        ";const marker='starlux-lmm-reader-installer-reset';if(localStorage.getItem(marker)===token)return;const legacy=['starlux-lmm-interface-language','starlux-lmm-trajectory-metrics','starlux-lmm-fused-metrics','starlux-lmm-chart-mode','starlux-lmm-layout-mode-v116'];const keys=[];for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(k&&(k.startsWith('starlux-lmm-reader-')||legacy.includes(k)))keys.push(k)}keys.forEach(k=>localStorage.removeItem(k));localStorage.setItem(marker,token)}catch{}})();</script>" + ResetEnd;
    static PreparedPackage PreparePreferences(string target, PreparedPackage package, bool clean)
    {
        string token = clean ? Guid.NewGuid().ToString("N") : "";
        if (!clean) try { token = ReadReceipt(target)?.AnalyzerResetToken ?? ""; } catch (Exception e) when (e is IOException or JsonException) { }
        if (token == "" || !package.Manifest.Files.Any(f => f.Path == "LMM_Report_Reader.html")) return package;
        var staging = Directory.CreateTempSubdirectory("StarLux-LMM-preferences-").FullName;
        try
        {
            var manifest = JsonSerializer.Deserialize<PackageManifest>(JsonSerializer.Serialize(package.Manifest, Json), Json)!;
            manifest.AnalyzerResetToken = token;
            foreach (var f in manifest.Files)
            {
                var dest = SafePath(staging, f.Path); Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(SafePath(package.Root, f.Path), dest);
            }
            var reader = SafePath(staging, "LMM_Report_Reader.html");
            var text = Regex.Replace(File.ReadAllText(reader), Regex.Escape(ResetStart) + ".*?" + Regex.Escape(ResetEnd), "", RegexOptions.Singleline);
            if (!text.Contains("<head>", StringComparison.OrdinalIgnoreCase)) throw new IOException(U.T("分析器缺少页面头，无法纯净重装", "Analyzer has no page head; cannot reset preferences"));
            var index = text.IndexOf("<head>", StringComparison.OrdinalIgnoreCase) + 6;
            File.WriteAllText(reader, text.Insert(index, ResetScript(token)));
            manifest.Files = manifest.Files.Select(f => f.Path == "LMM_Report_Reader.html" ? new PayloadFile(f.Path, Hash(reader)) : f).ToList();
            return new(manifest, staging);
        }
        catch { Directory.Delete(staging, true); throw; }
    }
}
