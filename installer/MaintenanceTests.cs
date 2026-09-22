using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StarLux.Installer;

static class MaintenanceTests
{
    static void Assert(bool ok, string message) { if (!ok) throw new Exception(message); }
    static void Reject(Action action) { try { action(); } catch (IOException) { return; } throw new Exception("Expected rejection"); }
    static void Write(string root, string relative, string content) { var file = Core.SafePath(root, relative); Directory.CreateDirectory(Path.GetDirectoryName(file)!); File.WriteAllText(file, content); }
    sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken t) => Task.FromResult(send(r)); }
    public static void Run(Action<string, Action> Test, string root)
    {
        var xp = Path.Combine(root, "maintenance-XP"); var home = Path.Combine(root, "maintenance-portable");
        Write(xp, "X-Plane.exe", "fixture"); Write(xp, "Log.txt", "log.txt for X-Plane 12.4.4-r1\n"); Directory.CreateDirectory(Path.Combine(xp, "Resources/plugins"));
        Write(xp, Core.Fwl + "/win_x64/FlyWithLua.xpl", "runtime"); Write(xp, Core.Fwl + "/Internals/FlyWithLua.ini", "ini");
        Write(xp, Core.Scripts + "/LMM_Settings.cfg", "my-config"); Write(xp, Core.Scripts + "/LMM_Log/my-flight.txt", "my-flight"); Write(xp, Core.Scripts + "/LMM_Log/.lmm_index", "my-cache"); Write(xp, Core.Scripts + "/other.lua", "other-plugin");
        var payload = Path.Combine(root, "maintenance-payload"); Write(payload, "StarLux_LMM_v1.1.8.lua", "return 'recorder'"); Write(payload, "LMM_Report_Reader.html", "<html><head></head><body>analyzer</body></html>"); Write(payload, "LMM_UI_118/layout.lua", "return {}");
        var manifest = new PackageManifest { Version = "1.1.8", UiVariant = "sdk440", DefaultLanguage = "zh", Files = Core.Files(payload).Select(f => new PayloadFile(Path.GetRelativePath(payload, f).Replace('\\', '/'), Core.Hash(f))).ToList() };
        var package = new PreparedPackage(manifest, payload);
        void Install(bool clean = false, int failAfter = -1) => Core.Install(home, xp, package, null, _ => { }, _ => { }, false, failAfter, clean);
        void Preserved(bool config = true)
        {
            Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "other.lua")) == "other-plugin", "other plugin lost");
            Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Log/my-flight.txt")) == "my-flight", "report lost");
            Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Log/.lmm_index")) == "my-cache", "cache lost");
            if (config) Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Settings.cfg")) == "my-config", "config lost");
        }
        Test("maintenance: verified compatible baseline", () => { Install(); Assert(Core.Diagnose(xp).Verified, "baseline not verified"); Preserved(); });
        Test("maintenance: stale UI directories and owned version guides are backed up and removed", () =>
        {
            Write(xp, Core.Scripts + "/LMM_UI_117/fonts/old.otf", "old font");
            Write(xp, Core.Scripts + "/README_1.1.7.md", "# StarLux Landing Meter");
            Write(xp, Core.Scripts + "/README_1.1.8beta.md", "StarLux development");
            Write(xp, Core.Scripts + "/README_9.9.9.md", "Another plugin");
            Write(xp, Core.Scripts + "/LMM_UI_116/notes.user", "personal note");
            var backup = Core.Install(home, xp, package, null, _ => { }, _ => { }, false);
            Assert(!Directory.Exists(Path.Combine(xp, Core.Scripts, "LMM_UI_117")), "empty UI directory remains");
            Assert(!File.Exists(Path.Combine(xp, Core.Scripts, "README_1.1.8beta.md")), "old guide remains");
            Assert(File.Exists(Path.Combine(xp, Core.Scripts, "README_9.9.9.md")), "unrelated guide removed");
            Assert(File.Exists(Path.Combine(xp, Core.Scripts, "LMM_UI_116/notes.user")), "unknown file removed");
            Core.Restore(backup, xp, false);
            Assert(File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_UI_117/fonts/old.otf")) == "old font", "backup not restorable");
            Assert(File.Exists(Path.Combine(xp, Core.Scripts, "README_1.1.8beta.md")), "guide not restored");
            Install(); Preserved();
        });
        Test("maintenance: missing, modified and mixed files detected together", () =>
        {
            File.Delete(Path.Combine(xp, Core.Scripts, "LMM_UI_118/layout.lua")); Write(xp, Core.Scripts + "/LMM_Report_Reader.html", "tampered"); Write(xp, Core.Scripts + "/StarLux_LMM_v1.1.7.lua", "old"); Write(xp, Core.Scripts + "/LMM_UI_117/layout.lua", "old module");
            var d = Core.Diagnose(xp); Assert(!d.Verified && d.Issues.Count >= 4, "false healthy or missing diagnostics"); Install(); Assert(Core.Diagnose(xp).Verified, "repair not healthy"); Assert(!File.Exists(Path.Combine(xp, Core.Scripts, "LMM_UI_117/layout.lua")), "stale module remains"); Preserved();
        });
        Test("maintenance: XP mismatch and repair package selection", () =>
        {
            Write(xp, "Log.txt", "X-Plane 12.4.3\n"); var d = Core.Diagnose(xp); Assert(!d.Verified, "incompatible marked healthy"); Reject(() => Install());
            var standard = new Release { Version = "1.1.8", UiVariant = "sdk440" }; var legacy = new Release { Version = "1.1.8", UiVariant = "legacy" }; Assert(Core.RepairRelease([standard, legacy], d) == legacy, "wrong repair variant"); Write(xp, "Log.txt", "X-Plane 12.4.4\n");
        });
        Test("maintenance: unknown XP is not claimed compatible", () => { File.Delete(Path.Combine(xp, "Log.txt")); Assert(!Core.Diagnose(xp).Verified, "unknown compatibility green"); Write(xp, "Log.txt", "X-Plane 12.4.4\n"); });
        Test("maintenance: keep-settings repair keeps analyzer bytes", () => { var reader = Path.Combine(xp, Core.Scripts, "LMM_Report_Reader.html"); var hash = Core.Hash(reader); Install(); Assert(Core.Hash(reader) == hash, "unexpected preference injection"); Preserved(); });
        Test("maintenance: clean reset is receipted and source payload unchanged", () =>
        {
            var hash = Core.Hash(Path.Combine(payload, "LMM_Report_Reader.html")); Install(true); Assert(!File.Exists(Path.Combine(xp, Core.Scripts, "LMM_Settings.cfg")), "config not reset");
            var html = File.ReadAllText(Path.Combine(xp, Core.Scripts, "LMM_Report_Reader.html")); Write(root,"analyzer-reset.html",html); Assert(html.Contains(Core.ResetStart) && html.Contains("starlux-lmm-reader-installer-reset"), "reset hook missing"); Assert(Core.Diagnose(xp).Verified, "transformed reader not receipted"); Assert(Core.Hash(Path.Combine(payload, "LMM_Report_Reader.html")) == hash, "source payload mutated"); Preserved(false);
            var before = Core.Hash(Path.Combine(xp, Core.Scripts, "LMM_Report_Reader.html")); Install(); Assert(Core.Hash(Path.Combine(xp, Core.Scripts, "LMM_Report_Reader.html")) == before, "ordinary repair repeated reset token"); Write(xp, Core.Scripts + "/LMM_Settings.cfg", "my-config");
        });
        Test("maintenance: clean-reinstall failure restores settings and program", () => { Reject(() => Install(true, 4)); Preserved(); Assert(Core.Diagnose(xp).Verified, "rollback left corrupt plugin"); });
        Test("maintenance: uninstall and restore keep user data and FWL", () =>
        {
            var backup = Core.Uninstall(home, xp, _ => { }, _ => { }, false); Assert(!Core.Diagnose(xp).HasPlugin, "uninstall left active plugin"); Assert(Core.HasFwl(xp), "FWL removed"); Preserved(); Core.Restore(backup, xp, false); Assert(Core.Diagnose(xp).Verified, "uninstall restore failed"); Preserved();
        });
        Test("maintenance: failed uninstall rolls back", () => { Reject(() => Core.Uninstall(home, xp, _ => { }, _ => { }, false, 2)); Assert(Core.Diagnose(xp).Verified, "failed uninstall damaged plugin"); Preserved(); });
        Test("maintenance: corrupt receipt repair does not touch unrelated files", () => { Write(xp, Core.Receipt, "{broken"); Assert(!Core.Diagnose(xp).Verified, "bad receipt healthy"); Install(); Assert(Core.Diagnose(xp).Verified, "bad receipt repair failed"); Preserved(); });
        Test("maintenance: null or inconsistent receipt still permits safe repair",()=>
        {
            foreach(var bad in new[]{"{\"schema\":1,\"product\":\"StarLux_LMM\",\"version\":\"1.1.8\",\"files\":null}",JsonSerializer.Serialize(new PackageManifest{Version="1.1.7",Files=manifest.Files},Core.Json)})
            { Write(xp,Core.Receipt,bad); Assert(!Core.Diagnose(xp).Verified,"invalid receipt healthy"); Install(); Assert(Core.Diagnose(xp).Verified,"invalid receipt blocks repair"); Preserved(); }
        });
        Test("installer update: independent catalog tags and mirror metadata", () =>
        {
            using var net = new Network(_ => { }, new Handler(r =>
            {
                var host = r.RequestUri!.Host == "gitee.com" ? Network.GiteeRepo : Network.GithubRepo;
                if (r.RequestUri.AbsolutePath.EndsWith("installer-release.json")) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { product = "StarLux_LMM_Installer", version = "1.0.1", asset = "StarLux_LMM_Installer_Update_v1.0.1.zip", sha256 = new string('a', 64) })) };
                return new(HttpStatusCode.OK)
                {
                    Content = new StringContent(JsonSerializer.Serialize(new[]{
                    new{tag_name="v9.0.0",assets=new[]{new{name="StarLux_LMM_Installer_Update_v9.0.0.zip",browser_download_url=host+"/releases/download/v9/a.zip"}}},
                    new{tag_name="installer-v1.0.1",assets=new[]{new{name="StarLux_LMM_Installer_Update_v1.0.1.zip",browser_download_url=host+"/releases/download/installer-v1.0.1/a.zip"},new{name="installer-release.json",browser_download_url=host+"/releases/download/installer-v1.0.1/installer-release.json"}}}
                }))
                };
            }));
            var catalog = net.InstallerCatalog(default).GetAwaiter().GetResult(); Assert(catalog.Available && catalog.Releases.Count == 1 && catalog.Releases[0].Version == "1.0.1" && catalog.Releases[0].Sources.Count == 2, "tag or mirror mismatch");
        });
        Test("installer update: network failure stays unknown", () => { using var net = new Network(_ => { }, new Handler(_ => new(HttpStatusCode.ServiceUnavailable))); var c = net.InstallerCatalog(default).GetAwaiter().GetResult(); Assert(!c.Available && c.Releases.Count == 0, "offline shown as latest"); });
        Test("installer update: package product, version and executable hashes", () =>
        {
            var dir = Path.Combine(root, "self-update-package"); Directory.CreateDirectory(dir); var exe = Path.Combine(dir, SelfUpdater.ExecutableName); File.Copy(Environment.ProcessPath!, exe);
            var m = new InstallerUpdateManifest { Version = SelfUpdater.Version, Sha256 = Core.Hash(exe) }; Write(dir, "installer-update.json", JsonSerializer.Serialize(m, Core.Json)); SelfUpdater.ValidatePayload(dir, SelfUpdater.Version);
            Reject(() => SelfUpdater.ValidatePayload(dir, "99.0.0")); File.AppendAllText(exe, "tamper"); Reject(() => SelfUpdater.ValidatePayload(dir, SelfUpdater.Version));
        });
        var args = Environment.GetCommandLineArgs(); var fixtureIndex = Array.IndexOf(args, "--update-fixture");
        if (fixtureIndex >= 0 && fixtureIndex + 1 < args.Length)
        {
            var next = Path.GetFullPath(args[fixtureIndex + 1]); var version = System.Diagnostics.FileVersionInfo.GetVersionInfo(next).ProductVersion!.Split('+')[0];
            var updateDir = Path.Combine(root, "update-integration-payload"); Directory.CreateDirectory(updateDir); File.Copy(next, Path.Combine(updateDir, SelfUpdater.ExecutableName));
            Write(updateDir, "installer-update.json", JsonSerializer.Serialize(new InstallerUpdateManifest { Version = version, Sha256 = Core.Hash(next) }, Core.Json));
            foreach (var fail in new[] { false, true }) Test(fail ? "self-update integration: restart failure restores previous executable" : "self-update integration: staged replacement and restarted readiness", () =>
            {
                var portable = Path.Combine(root, fail ? "update-rollback" : "update-success"); Directory.CreateDirectory(portable); var target = Path.Combine(portable, SelfUpdater.ExecutableName); File.Copy(Environment.ProcessPath!, target);
                Write(portable, "version/keep.json", "offline-packages"); Write(portable, "backup/keep.txt", "old-backups"); var original = Core.Hash(target);
                var requestFile = SelfUpdater.Stage(updateDir, version, target); var request = JsonSerializer.Deserialize<UpdateRequest>(File.ReadAllText(requestFile), Core.Json)!;
                request.ParentPid = int.MaxValue; request.ParentStarted = 0; File.WriteAllText(requestFile, JsonSerializer.Serialize(request, Core.Json)); // model the parent having exited
                var result = SelfUpdater.Apply(requestFile, probe: true, failProbe: fail);
                Assert(result == (fail ? 1 : 0), "unexpected updater result"); Assert(Core.Hash(target) == (fail ? original : Core.Hash(next)), "wrong executable after update/rollback");
                Assert(File.ReadAllText(Path.Combine(portable, "version/keep.json")) == "offline-packages" && File.ReadAllText(Path.Combine(portable, "backup/keep.txt")) == "old-backups", "adjacent data changed");
                Assert(File.Exists(Path.Combine(Path.GetDirectoryName(requestFile)!, "result.json")), "update result missing");
            });
        }
        Test("UI: English and Chinese states, red flashing and static current", () =>
        {
            ApplicationConfiguration.Initialize(); var old = U.Language;
            try { foreach (var lang in new[] { "en", "zh" }) { U.Language = lang; using var f = new MainForm(true); f.PreviewState(true); Assert(f.FlashStates.All(x => x), "updates do not flash"); f.PreviewOffline(); Assert(f.FlashStates.All(x=>x),"known updates stopped flashing offline"); if (lang == "en") Assert(f.CardText.All(x => !Regex.IsMatch(x, @"[\u4e00-\u9fff]")), "Chinese text in English status"); f.PreviewState(false); Assert(f.FlashStates.All(x => !x), "latest still flashing"); f.PreviewOffline(); Assert(f.CardText.All(x=>!x.Contains(U.T("已是最新版本","Up to date"))),"offline claimed latest"); } }
            finally { U.Language = old; }
        });
    }
}
