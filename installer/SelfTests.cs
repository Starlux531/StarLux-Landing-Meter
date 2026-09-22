using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace StarLux.Installer;

static class SelfTests
{
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    static void Reject(Action action) { try { action(); } catch (IOException) { return; } throw new Exception("Expected IOException"); }
    static void Write(string root, string relative, string text) { var f = Core.SafePath(root, relative); Directory.CreateDirectory(Path.GetDirectoryName(f)!); File.WriteAllText(f, text); }
    sealed class MockHandler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(send(request));
    }
    public static int Run(string[] args)
    {
        var output = args.Length > 1 ? args[1] : Path.Combine(Path.GetTempPath(), "StarLux-installer-tests.json");
        var root = Directory.CreateTempSubdirectory("StarLux-installer-tests-").FullName;
        var results = new List<object>(); bool passed = true;
        void Test(string name, Action test)
        {
            try { test(); results.Add(new { name, passed = true }); }
            catch (Exception e) { passed = false; results.Add(new { name, passed = false, error = e.ToString() }); }
        }
        try
        {
            Test("semantic version / prerelease order", () =>
            {
                Assert(Core.CompareVersion("1.1.8beta", "1.1.4") > 0, "beta vs stable");
                Assert(Core.CompareVersion("1.1.8beta", "1.1.8") < 0, "beta vs final");
                Assert(Core.CompareVersion("1.10", "1.9.9") > 0, "numeric order");
                Assert(Core.CompareVersion("1.1.8-beta2", "1.1.8beta1") > 0, "beta numbers");
            });
            Test("latest labels include all current variants, not beta or old local packages", () =>
            {
                var items = Core.LabelReleases([
                    new() { Version = "1.1.7", LocalDirectory = "offline" },
                    new() { Version = "1.1.8beta", UiVariant = "sdk440" },
                    new() { Version = "1.1.8", UiVariant = "legacy", DefaultLanguage = "zh" },
                    new() { Version = "1.1.8", Variant = "StarLux_LMM_v1.1.8-Standard-International.zip" },
                    new() { Version = "1.1.8", UiVariant = "sdk440", DefaultLanguage = "zh" }
                ]);
                Assert(items.Count(r => r.IsLatest) == 3, "all final variants latest");
                Assert(items[0].UiVariant == "sdk440" && items[0].DefaultLanguage == "zh", "default standard CN, newest first");
                Assert(items[0].ToString().Contains("最新 / Latest"), "bilingual badge");
                Assert(items.Single(r => r.UiVariant == "legacy").CompatibilityLabel.Contains("< 12.4.4"), "legacy range");
                Assert(items.Single(r => r.Variant.Length > 0).LanguageLabel.Contains("English default"), "remote language inferred");
                Assert(Core.LabelReleases([]).Count == 0, "empty catalog");
            });
            Test("Windows path traversal / ADS / device rejection", () =>
            {
                foreach (var p in new[] { "../x", "a/../../x", "C:/x", "x:y", "a./b", "a//b", "a/CON.txt", "NUL", "a/..\\x", "\\\\server\\x" }) Reject(() => Core.SafePath(root, p));
                Assert(Core.SafePath(root, "中文/字体.otf").StartsWith(root), "Unicode paths");
            });
            Test("ZIP traversal and duplicates rejected", () =>
            {
                var z = Path.Combine(root, "bad.zip"); using (var a = ZipFile.Open(z, ZipArchiveMode.Create)) a.CreateEntry("../escape.txt");
                Reject(() => Core.ExtractZip(z, Path.Combine(root, "bad-output")));
                z = Path.Combine(root, "duplicate.zip"); using (var a = ZipFile.Open(z, ZipArchiveMode.Create)) { a.CreateEntry("a.txt"); a.CreateEntry("A.txt"); }
                Reject(() => Core.ExtractZip(z, Path.Combine(root, "duplicate-output")));
            });
            var xp = Path.Combine(root, "模拟 XP"); Write(xp, "X-Plane.exe", "test"); Directory.CreateDirectory(Path.Combine(xp, "Resources/plugins"));
            Test("simulator paths normalize trailing separators", () => Assert(Core.NormalizeDirectory(xp + "\\") == Core.NormalizeDirectory(xp), "duplicate directory spelling"));
            Write(xp, Core.Fwl + "/win_x64/FlyWithLua.xpl", "fixture"); Write(xp, Core.Fwl + "/Internals/FlyWithLua.ini", "fixture");
            Write(xp, Core.Scripts + "/StarLux_LMM_v1.1.7.lua", "old-script");
            Write(xp, Core.Scripts + "/Other_User.lua", "user-script");
            Write(xp, Core.Scripts + "/LMM_Settings.cfg", "user-settings");
            Write(xp, Core.Scripts + "/LMM_Log/report.txt", "user-log");
            Write(xp, Core.Scripts + "/LMM_Log/.lmm_index", "airport-cache");
            var pkg = Path.Combine(root, "version/1.1.8beta");
            Write(pkg, "payload/StarLux_LMM_v1.1.8beta.lua", "new-script");
            Write(pkg, "payload/LMM_Report_Reader.html", "reader");
            Write(pkg, "payload/LMM_UI_118/dialog.lua", "module");
            var manifest = new PackageManifest { Version = "1.1.8beta", Build = "language-fix", Files = Core.Files(Path.Combine(pkg, "payload")).Select(f => new PayloadFile(Path.GetRelativePath(Path.Combine(pkg, "payload"), f).Replace('\\', '/'), Core.Hash(f))).ToList() };
            Write(pkg, "manifest.json", JsonSerializer.Serialize(manifest, Core.Json));
            var package = Core.Prepare(pkg);
            Test("local manifest discovered without network", () => Assert(Core.LocalReleases(root, _ => { }).Single().Version == "1.1.8beta", "local package"));
            Test("tampered local payload rejected", () => { var p = Path.Combine(pkg, "payload/LMM_Report_Reader.html"); var original = File.ReadAllText(p); File.WriteAllText(p, "tampered"); Reject(() => Core.Prepare(pkg)); File.WriteAllText(p, original); });
            Test("selected version must match manifest", () => Reject(() => Core.Prepare(pkg, "1.1.7")));
            Test("manifest must match versioned main filename", () => { var old = package.Manifest.Version; package.Manifest.Version = "1.1.9"; Reject(() => Core.ValidatePackage(package)); package.Manifest.Version = old; });
            Test("unknown payload / duplicate file blocked", () =>
            {
                package.Manifest.Files.Add(new("LMM_Settings.cfg", new string('0', 64))); Reject(() => Core.ValidatePackage(package)); package.Manifest.Files.RemoveAt(package.Manifest.Files.Count - 1);
                package.Manifest.Files.Add(package.Manifest.Files[0]); Reject(() => Core.ValidatePackage(package)); package.Manifest.Files.RemoveAt(package.Manifest.Files.Count - 1);
            });
            void Preserved()
            {
                Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "Other_User.lua")) == "user-script", "other scripts");
                Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Settings.cfg")) == "user-settings", "settings");
                Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Log/report.txt")) == "user-log", "logs");
                Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Log/.lmm_index")) == "airport-cache", "cache");
            }
            string backup = "";
            Test("upgrade backs up and disables old main / preserves user data", () =>
            {
                backup = Core.Install(Path.Combine(root, "portable"), xp, package, null, _ => { }, _ => { }, false);
                Assert(!File.Exists(Path.Combine(xp, Core.Scripts, "StarLux_LMM_v1.1.7.lua")), "old main still active");
                Assert(File.Exists(Path.Combine(backup, "files", Core.Scripts, "StarLux_LMM_v1.1.7.lua")), "missing backup");
                Assert(Core.Inspect(xp).Version == "1.1.8beta", "receipt"); Preserved();
            });
            Test("restore returns old version and removes newly installed files", () =>
            {
                Core.Restore(backup, xp, false); Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "StarLux_LMM_v1.1.7.lua")) == "old-script", "restore original");
                Assert(!File.Exists(Path.Combine(xp, Core.Scripts, "StarLux_LMM_v1.1.8beta.lua")), "new main remains"); Preserved();
            });
            Test("injected write failure rolls back", () =>
            {
                Reject(() => Core.Install(Path.Combine(root, "portable"), xp, package, null, _ => { }, _ => { }, false, 2));
                Assert(File.Exists(Path.Combine(xp, Core.Scripts, "StarLux_LMM_v1.1.7.lua")), "old main missing");
                Assert(!File.Exists(Path.Combine(xp, Core.Scripts, "StarLux_LMM_v1.1.8beta.lua")), "new main remains"); Preserved();
            });
            Test("invalid XP directory and backup-inside-XP rejected", () =>
            {
                Reject(() => Core.ValidateTarget(Path.Combine(xp, "Resources")));
                Reject(() => Core.Install(xp, xp, package, null, _ => { }, _ => { }, false));
            });
            Test("missing FWL blocks install without explicit dependency", () =>
            {
                var missing = Path.Combine(root, "missing-fwl"); Write(missing, "X-Plane.exe", "test"); Directory.CreateDirectory(Path.Combine(missing, "Resources/plugins"));
                Reject(() => Core.Plan(missing, package, null));
            });
            Test("dependency plan excludes demo scripts and user preferences", () =>
            {
                var clean = Path.Combine(root, "new-XP"); Write(clean, "X-Plane.exe", "test"); Directory.CreateDirectory(Path.Combine(clean, "Resources/plugins"));
                Write(clean, Core.Fwl + "/user.ini", "keep");
                var fwl = Path.Combine(root, "fwl/FlyWithLua"); Write(fwl, "win_x64/FlyWithLua.xpl", "fixture"); Write(fwl, "Internals/FlyWithLua.ini", "fixture"); Write(fwl, "Modules/graphics.lua", "fixture"); Write(fwl, "Scripts/demo.lua", "must-not-enable"); Write(fwl, "user.ini", "default");
                Assert(Core.FindFwl(Path.Combine(root, "fwl")) == Path.GetFullPath(fwl), "FWL detection");
                var plan = Core.Plan(clean, package, fwl);
                Assert(!plan.ContainsKey(Core.Fwl + "/Scripts/demo.lua") && !plan.ContainsKey(Core.Fwl + "/user.ini"), "dependency overrides scripts/preferences");
                Core.Install(Path.Combine(root, "portable"), clean, package, fwl, _ => { }, _ => { }, false); Assert(Core.HasFwl(clean), "FWL not installed");
            });
            Test("foreign backup target rejected", () => Reject(() => Core.Restore(backup, Path.Combine(root, "new-XP"), false)));
            Test("unfinished transaction blocks a moved second installer", () =>
            {
                Write(xp, "Resources/plugins/StarLux_LMM.install.pending.json", "{\"backup\":\"incomplete\"}");
                Reject(() => Core.Install(Path.Combine(root, "other-installer"), xp, package, null, _ => { }, _ => { }, false));
                File.Delete(Path.Combine(xp, "Resources/plugins/StarLux_LMM.install.pending.json"));
            });
            Test("corrupted backup rejected before modifying target", () =>
            {
                var f = Path.Combine(backup, "files", Core.Scripts, "StarLux_LMM_v1.1.7.lua"); var original = File.ReadAllText(f);
                File.WriteAllText(f, "corrupt"); Reject(() => Core.Restore(backup, xp, false)); File.WriteAllText(f, original);
                Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "StarLux_LMM_v1.1.7.lua")) == "old-script", "target was modified");
            });
            Test("native payload uses isolated root and disables Lua main", () =>
            {
                var dir = Path.Combine(root, "native-payload"); Write(dir, "win_x64/StarLux_LMM.xpl", "native fixture");
                var m = new PackageManifest { Kind = "native", Version = "2.0.0beta", Files = [new("win_x64/StarLux_LMM.xpl", Core.Hash(Path.Combine(dir, "win_x64/StarLux_LMM.xpl")))] };
                var p = new PreparedPackage(m, dir); var plan = Core.Plan(xp, p, null);
                Assert(plan.ContainsKey("Resources/plugins/StarLux_LMM/win_x64/StarLux_LMM.xpl"), "native root");
                Assert(plan[Core.Scripts + "/StarLux_LMM_v1.1.7.lua"] == "", "Lua not disabled");
                var b = Core.Install(Path.Combine(root, "portable"), xp, p, null, _ => { }, _ => { }, false);
                Assert(Core.Inspect(xp).Version == "2.0.0beta", "native receipt"); Core.Restore(b, xp, false); Preserved();
            });
            Test("legacy ZIP ignores configs/logs and rejects repo snapshots", () =>
            {
                var legacy = Path.Combine(root, "legacy"); Write(legacy, "StarLux_LMM_v1.1.4.lua", "legacy"); Write(legacy, "LMM_Settings.cfg", "do not install"); Write(legacy, "LMM_Log/report.txt", "do not install");
                var p = Core.Prepare(legacy, "1.1.4"); Assert(p.Manifest.Files.Count == 1, "legacy allowlist");
                Write(legacy, "archive/StarLux_LMM_v1.1.1.lua", "backup"); Reject(() => Core.Prepare(legacy));
            });
            Test("trusted origins only", () =>
            {
                Assert(Network.TrustedInitial(new(Network.GithubRepo + "/releases/download/v1/file.zip")), "official denied");
                foreach (var u in new[] { "http://github.com/Starlux531/StarLux-Landing-Meter/x", "https://github.com.evil.test/Starlux531/StarLux-Landing-Meter/x", "https://evil.test/a.zip", "https://github.com:444/Starlux531/StarLux-Landing-Meter/x" }) Assert(!Network.TrustedInitial(new(u)), "untrusted allowed");
            });
            Test("download fails over after corrupt mirror / verifies shared digest", () =>
            {
                byte[] good;
                using (var m = new MemoryStream()) { using (var z = new ZipArchive(m, ZipArchiveMode.Create, true)) { using var w = new StreamWriter(z.CreateEntry("a.txt").Open()); w.Write("good"); } good = m.ToArray(); }
                int calls = 0;
                using var net = new Network(_ => { }, new MockHandler(r => { calls++; return new(HttpStatusCode.OK) { Content = new ByteArrayContent(r.RequestUri!.Host == "gitee.com" ? Encoding.UTF8.GetBytes("invalid") : good) }; }));
                var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(good)).ToLowerInvariant();
                var dest = Path.Combine(root, "download.zip");
                net.Download([new("Gitee", Network.GiteeRepo + "/x.zip"), new("GitHub", Network.GithubRepo + "/x.zip", hash)], dest, "Gitee", _ => { }, default).GetAwaiter().GetResult();
                Assert(calls == 2 && Core.Hash(dest) == hash, "failover/digest");
            });
            Test("catalog merges matching mirrors but keeps CN / International distinct", () =>
            {
                using var net = new Network(_ => { }, new MockHandler(r =>
                {
                    var host = r.RequestUri!.Host == "gitee.com" ? Network.GiteeRepo : Network.GithubRepo;
                    var text = JsonSerializer.Serialize(new[] { new { tag_name = "v1.1.4", assets = new[] { new { name = "StarLux-Landing-Meter-v1.1.4-CN.zip", browser_download_url = host + "/releases/download/v1.1.4/a.zip" } } } });
                    return new(HttpStatusCode.OK) { Content = new StringContent(text) };
                }));
                var list = net.Catalog(default).GetAwaiter().GetResult(); Assert(list.Count == 1 && list[0].Sources.Count == 2, "mirror merge");
            });
            Test("unsafe redirect rejected", () =>
            {
                using var net = new Network(_ => { }, new MockHandler(_ => { var r = new HttpResponseMessage(HttpStatusCode.Redirect); r.Headers.Location = new("https://evil.test/a.zip"); return r; }));
                Reject(() => net.Download([new("GitHub", Network.GithubRepo + "/x.zip")], Path.Combine(root, "redirect.zip"), "Auto", _ => { }, default).GetAwaiter().GetResult());
            });
            MaintenanceTests.Run(Test, root);
            if (args.Length > 2 && !args[2].StartsWith("--"))
            {
                Test("bundled real stable payload verifies", () => { var p = Core.Prepare(args[2]); Assert(Core.ExtractVersion(p.Manifest.Version) == p.Manifest.Version && p.Manifest.Files.Any(f => f.Path.EndsWith("LMMUI-Regular.otf")), "real package missing UI/fonts"); });
            }
            var fwlOption = Array.IndexOf(args, "--fwl-archive");
            if (fwlOption >= 0)
            {
                Test("real official NG+ archive / DLLs / installation / restore", () =>
                {
                    var zip = args[fwlOption + 1]; Assert(Core.Hash(zip) == Network.OfficialFwl.Sha256, "official digest");
                    var unpack = Path.Combine(root, "official-fwl"); Core.ExtractZip(zip, unpack); var fwl = Core.FindFwl(unpack);
                    Assert(File.Exists(Path.Combine(fwl, "win_x64/OpenAL32.dll")) && File.Exists(Path.Combine(fwl, "win_x64/glut64.dll")), "DLL dependencies");
                    var clean = Path.Combine(root, "official-XP"); Write(clean, "X-Plane.exe", "test"); Directory.CreateDirectory(Path.Combine(clean, "Resources/plugins"));
                    var b = Core.Install(Path.Combine(root, "portable"), clean, package, fwl, _ => { }, _ => { }, false);
                    Assert(Core.HasFwl(clean), "official installed"); Core.Restore(b, clean, false); Assert(!Core.HasFwl(clean), "official restored");
                });
            }
            if (args.Contains("--network"))
            {
                Test("live dual-source catalog and current release download", () =>
                {
                    using var net = new Network(_ => { }); var list = net.Catalog(default).GetAwaiter().GetResult(); Assert(list.Count > 0, "no live releases");
                    var r = list.First(r => r.Version == "1.1.4" && r.Variant.EndsWith("CN.zip"));
                    foreach (var s in r.Sources)
                    {
                        var zip = net.Download([s], Path.Combine(root, s.Name + ".zip"), "Auto", _ => { }, default).GetAwaiter().GetResult();
                        var unpack = Path.Combine(root, "live-" + s.Name); Core.ExtractZip(zip, unpack); var p = Core.Prepare(unpack, r.Version); Assert(p.Manifest.Version == "1.1.4", "wrong legacy version");
                    }
                });
            }
        }
        finally
        {
            File.WriteAllText(output, JsonSerializer.Serialize(new { passed, results, fixtureRoot = root }, Core.Json));
            // Leave fixture roots for independent inspection of rollback and backup files.
        }
        return passed ? 0 : 1;
    }
}
