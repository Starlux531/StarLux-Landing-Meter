using System.Text.Json;

namespace StarLux.Installer;

public sealed partial class MainForm
{
    internal void ShowUpdateResult(string file)
    {
        Core.NoLinks(file);
        if (Path.GetFileName(file) != "result.json" || !Path.GetFileName(Path.GetDirectoryName(file)!).StartsWith("StarLux-installer-update-", StringComparison.Ordinal)) return;
        try
        {
            using var result = JsonDocument.Parse(File.ReadAllText(file));
            if (!result.RootElement.GetProperty("success").GetBoolean()) Shown += (_, _) => Prompt(U.T("更新失败，已恢复旧安装器", "Update failed; previous installer restored"), U.T("更新程序未能正常启动，已恢复原程序。诊断记录：", "The new installer could not start. The original executable has been restored. Diagnostic record: ") + file);
        }
        catch { }
    }
    async Task Install(bool repairing)
    {
        if (busy) return; SetBusy(true);
        var xp = target.Text.Trim(); string? temp = null;
        try
        {
            Core.ValidateTarget(xp); Core.CheckNotRunning(); diagnosis = await Task.Run(() => Core.Diagnose(xp)); Log(diagnosis.Describe());
            if (repairing) releases.SelectedItem = Core.RepairRelease(releases.Items.Cast<Release>(), diagnosis);
            if (releases.SelectedItem is not Release selected) throw new IOException(U.T("没有可用的匹配安装包，请检查更新。", "No matching package is available. Check updates."));
            if (!Core.Compatible(diagnosis.SimulatorVersion, Core.Variant(selected))) throw new IOException(U.T("所选标准版不兼容当前 XP，请改选兼容版或点击修复。", "Standard is incompatible with this XP version. Select Compatibility or use Repair."));
            var choice = Prompt(repairing ? U.T("修复插件", "Repair plugin") : U.T("安装插件", "Install plugin"), U.T("目标：", "Target: ") + xp + "\n\n" + U.ReleaseName(selected) + "\n\n" +
                (diagnosis.Version != "" && Core.CompareVersion(selected.Version, diagnosis.Version) < 0 ? U.T("注意：将安装较旧版本。\n", "Note: this will downgrade the plugin.\n") : "") +
                (diagnosis.SimulatorVersion == "" ? U.T("XP 版本未识别，请先核对所选版本的兼容范围。\n", "XP version is unknown. Check the compatibility range before continuing.\n") : "") +
                U.T("保留配置：保留插件设置和分析器偏好。\n纯净重装：重置插件设置；下次打开随插件分析器时重置其偏好。\n两种方式都保留飞行记录、机场缓存和其他插件。", "Keep settings: preserve plugin and analyzer preferences.\nClean reinstall: reset plugin settings and reset the bundled analyzer on its next open.\nBoth modes preserve flight reports, airport caches and other plugins."),
                (U.T("保留配置", "Keep settings"), DialogResult.Yes), (U.T("纯净重装", "Clean reinstall"), DialogResult.No), No);
            if (choice is not (DialogResult.Yes or DialogResult.No)) return; bool clean = choice == DialogResult.No;
            catalogCancellation?.Cancel(); operation = new(); SetBusy(true); SavePreferences(); temp = Directory.CreateTempSubdirectory("StarLux-LMM-install-").FullName;
            using var net = new Network(Log); PreparedPackage package;
            if (selected.LocalDirectory != "")
            {
                var original = await Task.Run(() => Core.Prepare(selected.LocalDirectory)); var stageRoot = Path.Combine(temp, "payload");
                await Task.Run(() => { foreach (var f in original.Manifest.Files) { var dest = Core.SafePath(stageRoot, f.Path); Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(Core.SafePath(original.Root, f.Path), dest); } }); package = new(original.Manifest, stageRoot); Core.ValidatePackage(package);
            }
            else { var zip = await net.Download(selected.Sources, Path.Combine(temp, "lmm.zip"), Preferred, Percent, operation.Token); var unpack = Path.Combine(temp, "plugin"); await Task.Run(() => Core.ExtractZip(zip, unpack)); package = await Task.Run(() => Core.Prepare(unpack, selected.Version)); }
            if (package.Manifest.UiVariant == "") package.Manifest.UiVariant = Core.Variant(selected); Core.ValidateCompatibility(xp, package.Manifest);
            string? fwlRoot = null;
            if (package.Manifest.Kind == "flywithlua" && !Core.HasFwl(xp))
            {
                var answer = Prompt(U.T("安装 FlyWithLua", "Install FlyWithLua"), U.T("缺少 FlyWithLua NG+。可下载固定的 XP12 官方运行库，或导入已下载的 NG+ ZIP。", "FlyWithLua NG+ is missing. Download the pinned official XP12 runtime or import an existing NG+ ZIP."), (U.T("下载运行库", "Download runtime"), DialogResult.Yes), (U.T("导入 ZIP", "Import ZIP"), DialogResult.No), No);
                if (answer is not (DialogResult.Yes or DialogResult.No)) return; string zip;
                if (answer == DialogResult.Yes) zip = await net.Download(DependencySources(), Path.Combine(temp, "fwl.zip"), Preferred, Percent, operation.Token);
                else { using var file = new OpenFileDialog { Title = U.T("选择 XP12 FlyWithLua NG+ ZIP", "Select XP12 FlyWithLua NG+ ZIP"), Filter = "ZIP|*.zip" }; if (file.ShowDialog(this) != DialogResult.OK) return; zip = file.FileName; }
                var unpack = Path.Combine(temp, "fwl"); await Task.Run(() => Core.ExtractZip(zip, unpack)); fwlRoot = Core.FindFwl(unpack);
                var license = Path.Combine(Path.GetDirectoryName(fwlRoot)!, "LICENSE"); if (File.Exists(license) && !File.Exists(Path.Combine(fwlRoot, "LICENSE"))) File.Copy(license, Path.Combine(fwlRoot, "LICENSE"));
            }
            operation.Token.ThrowIfCancellationRequested(); applying = true; cancel.Enabled = false;
            var backup = await Task.Run(() => Core.Install(baseDir, xp, package, fwlRoot, Log, Percent, clean: clean)); Log(U.T("安装完成。备份：", "Installation complete. Backup: ") + backup);
            Prompt(U.T("操作完成", "Completed"), U.T("插件已安装，请启动 X-Plane 验证加载。\n备份：", "Plugin installed. Start X-Plane to verify loading.\nBackup: ") + backup);
        }
        catch (OperationCanceledException) { Log(U.T("下载已取消", "Download cancelled")); }
        catch (Exception e) { Log(e.Message); Prompt(U.T("操作未完成", "Operation not completed"), e.Message); }
        finally { applying = false; operation?.Dispose(); operation = null; SetBusy(false); await InspectTarget(); Cleanup(temp, "StarLux-LMM-install-"); }
    }
    async Task Uninstall()
    {
        if (busy) return; SetBusy(true);
        try
        {
            var xp = target.Text.Trim(); Core.ValidateTarget(xp); Core.CheckNotRunning();
            if (Prompt(U.T("卸载插件", "Uninstall plugin"), U.T("将移除 LMM 主脚本、UI 模块和随插件分析器。保留插件设置、浏览器偏好、飞行记录、机场缓存及 FlyWithLua。可使用本次备份恢复。\n\n目标：", "Remove LMM scripts, UI modules and the bundled analyzer. Keep plugin settings, browser preferences, reports, airport caches and FlyWithLua. Restore from this operation's backup if needed.\n\nTarget: ") + xp, Yes, No) != DialogResult.OK) return;
            catalogCancellation?.Cancel(); applying = true; SetBusy(true); var backup = await Task.Run(() => Core.Uninstall(baseDir, xp, Log, Percent)); Log(U.T("卸载完成。备份：", "Uninstalled. Backup: ") + backup); Prompt(U.T("卸载完成", "Uninstalled"), U.T("插件已卸载，配置与飞行记录已保留。", "Plugin removed. Settings and flight reports preserved."));
        }
        catch (Exception e) { Log(e.Message); Prompt(U.T("卸载未完成", "Uninstall failed"), e.Message); }
        finally { applying = false; SetBusy(false); await InspectTarget(); }
    }
    async Task Restore()
    {
        if (busy) return; SetBusy(true);
        try
        {
            var xp = target.Text.Trim(); Core.ValidateTarget(xp); Core.CheckNotRunning();
            using var file = new OpenFileDialog { Title = U.T("选择备份事务清单", "Select backup transaction"), Filter = "transaction.json|transaction.json", InitialDirectory = Path.Combine(baseDir, "backup") };
            if (file.ShowDialog(this) != DialogResult.OK) return;
            if (Prompt(U.T("恢复备份", "Restore backup"), U.T("将恢复此事务涉及的文件，包括纯净重装重置的插件配置。请优先选择最近的备份；浏览器偏好不在文件备份中。", "Restore files touched by this transaction, including plugin settings reset by clean reinstall. Prefer the most recent backup. Browser preferences are not part of file backups."), Yes, No) != DialogResult.OK) return;
            catalogCancellation?.Cancel(); applying = true; SetBusy(true); await Task.Run(() => Core.Restore(Path.GetDirectoryName(file.FileName)!, xp)); Log(U.T("备份已恢复", "Backup restored"));
        }
        catch (Exception e) { Log(e.Message); Prompt(U.T("恢复未完成", "Restore failed"), e.Message); }
        finally { applying = false; SetBusy(false); await InspectTarget(); }
    }
    async Task UpdateInstaller()
    {
        var selected = installerCatalog?.Releases.FirstOrDefault(); if (selected == null || Core.CompareVersion(selected.Version, SelfUpdater.Version) <= 0) return;
        if (Prompt(U.T("更新安装器", "Update installer"), U.T("将下载并校验安装器，然后关闭当前窗口、替换程序并重新启动。插件、配置和备份目录保持原位。\n\n新版本：", "Download and verify the installer, close this window, replace the executable and restart. Plugin files, settings and backup folders stay in place.\n\nNew version: ") + selected.Version, Yes, No) != DialogResult.OK) return;
        string? temp = null;
        try
        {
            catalogCancellation?.Cancel(); operation = new(); SetBusy(true); temp = Directory.CreateTempSubdirectory("StarLux-LMM-update-download-").FullName;
            using var net = new Network(Log); var zip = await net.Download(selected.Sources, Path.Combine(temp, "update.zip"), Preferred, Percent, operation.Token); var unpack = Path.Combine(temp, "unpack"); await Task.Run(() => Core.ExtractZip(zip, unpack)); operation.Token.ThrowIfCancellationRequested();
            var request = await Task.Run(() => SelfUpdater.Stage(unpack, selected.Version)); SavePreferences(); SelfUpdater.Launch(request); closingForUpdate = true; Close();
        }
        catch (OperationCanceledException) { Log(U.T("更新下载已取消", "Update download cancelled")); }
        catch (Exception e) { Log(e.Message); Prompt(U.T("安装器更新未完成", "Installer update failed"), e.Message); }
        finally { operation?.Dispose(); operation = null; if (!IsDisposed) SetBusy(false); Cleanup(temp, "StarLux-LMM-update-download-"); }
    }
    IEnumerable<DownloadSource> DependencySources()
    {
        var file = Path.Combine(baseDir, "version/flywithlua-mirrors.json"); var list = new List<DownloadSource>();
        if (File.Exists(file)) foreach (var m in JsonSerializer.Deserialize<List<DownloadSource>>(File.ReadAllText(file), Core.Json) ?? []) if (m.Sha256.Equals(Network.OfficialFwl.Sha256, StringComparison.OrdinalIgnoreCase) && Uri.TryCreate(m.Url, UriKind.Absolute, out var uri) && Network.TrustedInitial(uri)) list.Add(m);
        list.Add(Network.OfficialFwl); return list;
    }
    void Cleanup(string? temp, string prefix) { if (temp == null) return; try { Core.NoLinks(temp); if (Path.GetDirectoryName(temp) == Path.GetTempPath().TrimEnd('\\') && Path.GetFileName(temp).StartsWith(prefix, StringComparison.Ordinal)) Directory.Delete(temp, true); } catch (Exception e) { Log(e.Message); } }
}
