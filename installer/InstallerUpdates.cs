using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StarLux.Installer;

public sealed class InstallerRelease
{
    public string Version { get; set; } = "";
    public List<DownloadSource> Sources { get; set; } = [];
}
public record InstallerCatalog(bool Available, List<InstallerRelease> Releases);
public sealed class InstallerUpdateManifest
{
    public int Schema { get; set; } = 1;
    public string Product { get; set; } = "StarLux_LMM_Installer";
    public string Version { get; set; } = "";
    public string Executable { get; set; } = SelfUpdater.ExecutableName;
    public string Sha256 { get; set; } = "";
}
public sealed class UpdateRequest
{
    public int ParentPid { get; set; }
    public long ParentStarted { get; set; }
    public string Target { get; set; } = "";
    public string OriginalHash { get; set; } = "";
    public string Version { get; set; } = "";
    public string NewHash { get; set; } = "";
}
public sealed partial class Network
{
    async Task<byte[]> ReadSmall(string url, int maximum, CancellationToken token)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(token); limit.CancelAfter(TimeSpan.FromSeconds(25));
        using var response = await Open(url, limit.Token);
        using var stream = await response.Content.ReadAsStreamAsync(limit.Token);
        using var result = new MemoryStream(); await CopyBounded(stream, result, maximum, limit.Token, null, null); return result.ToArray();
    }
    public async Task<InstallerCatalog> InstallerCatalog(CancellationToken token)
    {
        async Task<(bool, List<InstallerRelease>)> Source(string name, string url)
        {
            var list = new List<InstallerRelease>();
            try
            {
                for (int page = 1; page <= 5; page++)
                {
                    using var document = JsonDocument.Parse(await ReadSmall(url + $"?per_page=100&page={page}", 8 * 1024 * 1024, token));
                    if (document.RootElement.ValueKind != JsonValueKind.Array) throw new IOException(U.T("发布目录格式无效", "Invalid release catalog"));
                    foreach (var release in document.RootElement.EnumerateArray())
                    {
                        if (release.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True || release.TryGetProperty("prerelease", out var pre) && pre.ValueKind == JsonValueKind.True) continue;
                        var tag = release.GetProperty("tag_name").GetString() ?? "";
                        var match = Regex.Match(tag, @"^installer-v(\d+\.\d+(?:\.\d+)?)$", RegexOptions.IgnoreCase);
                        if (!match.Success || !release.TryGetProperty("assets", out var assets)) continue;
                        if (assets.ValueKind == JsonValueKind.Object && assets.TryGetProperty("links", out var links)) assets = links;
                        if (assets.ValueKind != JsonValueKind.Array) continue;
                        var version = match.Groups[1].Value;
                        var packageName = $"StarLux_LMM_Installer_Update_v{version}.zip";
                        var package = assets.EnumerateArray().FirstOrDefault(a => a.TryGetProperty("name", out var n) && n.GetString() == packageName);
                        if (package.ValueKind != JsonValueKind.Object || !package.TryGetProperty("browser_download_url", out var download)) continue;
                        var address = download.GetString() ?? "";
                        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || !TrustedInitial(uri)) continue;
                        var digest = package.TryGetProperty("digest", out var hash) && hash.ValueKind == JsonValueKind.String ? hash.GetString() ?? "" : "";
                        digest = digest.StartsWith("sha256:") ? digest[7..] : "";
                        if (!Regex.IsMatch(digest, "^[a-fA-F0-9]{64}$"))
                        {
                            var metadata = assets.EnumerateArray().FirstOrDefault(a => a.TryGetProperty("name", out var n) && n.GetString() == "installer-release.json");
                            if (metadata.ValueKind != JsonValueKind.Object || !metadata.TryGetProperty("browser_download_url", out var md)) continue;
                            using var json = JsonDocument.Parse(await ReadSmall(md.GetString() ?? "", 65536, token));
                            var m = json.RootElement;
                            if (m.GetProperty("product").GetString() != "StarLux_LMM_Installer" || m.GetProperty("version").GetString() != version || m.GetProperty("asset").GetString() != packageName) continue;
                            digest = m.GetProperty("sha256").GetString() ?? "";
                        }
                        if (Regex.IsMatch(digest, "^[a-fA-F0-9]{64}$")) list.Add(new() { Version = version, Sources = [new(name, address, digest.ToLowerInvariant())] });
                    }
                    if (document.RootElement.GetArrayLength() < 100) break;
                }
                return (true, list);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception e) { log(U.T("安装器更新源暂不可用：", "Installer update source unavailable: ") + name + " · " + e.Message); return (false, list); }
        }
        var results = await Task.WhenAll(Source("GitHub", "https://api.github.com/repos/Starlux531/StarLux-Landing-Meter/releases"), Source("Gitee", "https://gitee.com/api/v5/repos/starlux531/starluxlmm/releases"));
        var merged = results.SelectMany(r => r.Item2).GroupBy(r => r.Version).Where(g => g.SelectMany(r => r.Sources).Select(s => s.Sha256).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1).Select(g => new InstallerRelease { Version = g.Key, Sources = g.SelectMany(r => r.Sources).ToList() }).OrderByDescending(r => r.Version, Comparer<string>.Create(Core.CompareVersion)).ToList();
        return new(results.Any(r => r.Item1), merged);
    }
}

public static class SelfUpdater
{
    // Independent from the plugin's 1.x release line and the old preview installer numbering.
    public static string Version => typeof(SelfUpdater).Assembly.GetName().Version!.ToString(3);
    public static string DisplayVersion => Version.EndsWith(".0", StringComparison.Ordinal) ? Version[..^2] : Version;
    public const string ExecutableName = "StarLux_LMM_installer_安装器.exe";
    public static InstallerUpdateManifest ValidatePayload(string directory, string expectedVersion)
    {
        var manifest = JsonSerializer.Deserialize<InstallerUpdateManifest>(File.ReadAllText(Core.SafePath(directory, "installer-update.json")), Core.Json)
            ?? throw new IOException(U.T("更新清单为空", "Empty update manifest"));
        if (manifest.Schema != 1 || manifest.Product != "StarLux_LMM_Installer" || manifest.Version != expectedVersion || manifest.Executable != ExecutableName || !Regex.IsMatch(manifest.Sha256, "^[a-fA-F0-9]{64}$"))
            throw new IOException(U.T("安装器更新清单无效", "Invalid installer update manifest"));
        var files = Core.Files(directory).Select(f => Path.GetRelativePath(directory, f)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!files.SetEquals(["installer-update.json", ExecutableName])) throw new IOException(U.T("更新包包含非安装器文件", "Update package contains unexpected files"));
        var exe = Core.SafePath(directory, manifest.Executable);
        if (!Core.Hash(exe).Equals(manifest.Sha256, StringComparison.OrdinalIgnoreCase)) throw new IOException(U.T("更新程序校验失败", "Updater executable checksum mismatch"));
        ValidateExecutable(exe, expectedVersion); return manifest;
    }
    public static void ValidateExecutable(string path, string version)
    {
        var info = FileVersionInfo.GetVersionInfo(path);
        if (info.ProductName != "StarLux LMM Installer" || Core.CompareVersion(info.ProductVersion ?? "", version) != 0)
            throw new IOException(U.T("更新程序身份或版本不匹配", "Installer executable product or version mismatch"));
    }
    public static string Stage(string unpacked, string expectedVersion, string? target = null)
    {
        var manifest = ValidatePayload(unpacked, expectedVersion);
        if (Core.CompareVersion(expectedVersion, Version) <= 0) throw new IOException(U.T("没有更高的安装器版本", "No newer installer version"));
        target ??= Environment.ProcessPath!; Core.NoLinks(target);
        var dir = Directory.CreateTempSubdirectory("StarLux-installer-update-").FullName;
        File.Copy(Core.SafePath(unpacked, ExecutableName), Path.Combine(dir, "replacement.exe"));
        // Use this version's helper protocol, not code from an unstarted downloaded app.
        File.Copy(Environment.ProcessPath!, Path.Combine(dir, "helper.exe"));
        using var parent = Process.GetCurrentProcess();
        var request = new UpdateRequest { ParentPid = parent.Id, ParentStarted = parent.StartTime.ToUniversalTime().Ticks, Target = Path.GetFullPath(target), OriginalHash = Core.Hash(target), Version = expectedVersion, NewHash = manifest.Sha256 };
        var file = Path.Combine(dir, "request.json"); File.WriteAllText(file, JsonSerializer.Serialize(request, Core.Json)); return file;
    }
    public static void Launch(string request)
    {
        var helper = Path.Combine(Path.GetDirectoryName(request)!, "helper.exe");
        var start = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        start.ArgumentList.Add("--apply-self-update"); start.ArgumentList.Add(request);
        _ = Process.Start(start) ?? throw new IOException(U.T("无法启动更新助手", "Could not start update helper"));
    }
    public static int Apply(string requestFile, bool probe = false, bool failProbe = false)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(requestFile))!;
        string backup = "", target = "", swap = ""; bool replaced = false, originalVerified = false;
        Process? child = null;
        try
        {
            Core.NoLinks(dir);
            if (!Path.GetFileName(dir).StartsWith("StarLux-installer-update-", StringComparison.Ordinal) || Path.GetFileName(requestFile) != "request.json") throw new IOException("Invalid updater staging directory");
            var r = JsonSerializer.Deserialize<UpdateRequest>(File.ReadAllText(requestFile), Core.Json) ?? throw new IOException("Invalid update request");
            target = Path.GetFullPath(r.Target); Core.NoLinks(target);
            if (Path.GetExtension(target) != ".exe" || !Regex.IsMatch(r.NewHash, "^[a-fA-F0-9]{64}$") || !Regex.IsMatch(r.OriginalHash, "^[a-fA-F0-9]{64}$")) throw new IOException("Invalid update target");
            var replacement = Path.Combine(dir, "replacement.exe");
            if (!Core.Hash(replacement).Equals(r.NewHash, StringComparison.OrdinalIgnoreCase)) throw new IOException("Update payload changed");
            ValidateExecutable(replacement, r.Version);
            try
            {
                using var parent = Process.GetProcessById(r.ParentPid);
                if (parent.StartTime.ToUniversalTime().Ticks != r.ParentStarted || !string.Equals(parent.MainModule?.FileName, target, StringComparison.OrdinalIgnoreCase)) throw new IOException("Updater parent mismatch");
                if (!parent.WaitForExit(60000)) throw new IOException("Installer is still running");
            }
            catch (ArgumentException) { /* Parent already exited; original hash still required. */ }
            if (!Core.Hash(target).Equals(r.OriginalHash, StringComparison.OrdinalIgnoreCase)) throw new IOException("Installed executable changed");
            originalVerified = true;
            backup = target + ".previous-" + Guid.NewGuid().ToString("N") + ".exe";
            swap = target + ".update-" + Guid.NewGuid().ToString("N") + ".exe";
            File.Copy(replacement, swap); File.Replace(swap, target, backup); replaced = true;
            if (Core.Hash(target) != r.NewHash.ToLowerInvariant()) throw new IOException("Updated executable verification failed");
            var health = Path.Combine(dir, "ready.json");
            var start = new ProcessStartInfo(target) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(target)! };
            start.ArgumentList.Add("--update-health"); start.ArgumentList.Add(health);
            if (probe) start.ArgumentList.Add(failProbe ? "--update-probe-fail" : "--update-probe");
            child = Process.Start(start) ?? throw new IOException("Could not restart installer");
            var deadline = Stopwatch.StartNew();
            while (!File.Exists(health) && !child.HasExited && deadline.Elapsed < TimeSpan.FromSeconds(30)) Thread.Sleep(100);
            if (!File.Exists(health)) { if (!child.HasExited) { child.Kill(); child.WaitForExit(10000); } throw new IOException("Updated installer did not become ready"); }
            using var ack = JsonDocument.Parse(File.ReadAllText(health));
            if (ack.RootElement.GetProperty("version").GetString() != r.Version || ack.RootElement.GetProperty("pid").GetInt32() != child.Id) throw new IOException("Invalid update readiness acknowledgement");
            File.WriteAllText(Path.Combine(dir, "result.json"), JsonSerializer.Serialize(new { success = true, target, backup }, Core.Json)); return 0;
        }
        catch (Exception e)
        {
            string recovery = "";
            if (child != null) try { if (!child.HasExited) { child.Kill(); child.WaitForExit(10000); } } catch { }
            if (replaced) try { File.Copy(backup, target, true); } catch (Exception restore) { recovery = restore.Message; }
            try { File.WriteAllText(Path.Combine(dir, "result.json"), JsonSerializer.Serialize(new { success = false, error = e.Message, recovery, target, backup }, Core.Json)); } catch { }
            if (originalVerified && recovery == "" && !probe) try
                {
                    var restart = new ProcessStartInfo(target) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(target)! };
                    restart.ArgumentList.Add("--update-result"); restart.ArgumentList.Add(Path.Combine(dir, "result.json")); Process.Start(restart);
                }
                catch { }
            return 1;
        }
        finally { child?.Dispose(); if (swap.Length > 0 && File.Exists(swap)) try { File.Delete(swap); } catch { } }
    }
}
