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
            InstallerTrace.Session?.Snapshot("self-update-result.json",file);
            using var result = JsonDocument.Parse(File.ReadAllText(file));
            InstallerTrace.Event("SELF_UPDATE_RESULT",new {path=file,result=result.RootElement.Clone()});
            if (!result.RootElement.GetProperty("success").GetBoolean())
            {
                var detail=U.T("自更新未完成。请查看错误与恢复结果，不要删除原安装器备份。\n诊断记录：", "Self-update did not complete. Review the error and recovery result; retain the previous executable backup.\nDiagnostic record: ")+file;
                if(result.RootElement.TryGetProperty("error",out var error))detail+="\n\n"+error.GetString();
                if(result.RootElement.TryGetProperty("recovery",out var recovery)&&!string.IsNullOrEmpty(recovery.GetString()))detail+="\n\n"+U.T("恢复也失败：","Recovery also failed: ")+recovery.GetString();
                Shown += (_, _) => Prompt(U.T("安装器更新未完成", "Installer update incomplete"),detail);
            }
        }
        catch(Exception e) {Error("Read installer update result",e,false);}
    }
    async Task Install(bool repairing)
    {
        if (busy) return; SetBusy(true);
        var xp = target.Text.Trim(); string? temp = null;
        using var trace=InstallerTrace.Begin(repairing?"repair":"install",new {target=xp,source=Preferred});lastLoggedPercent=-1;progress.Value=0;
        InstallerTrace.Status(U.T(repairing ? "正在检查修复条件…" : "正在检查安装条件…", repairing ? "Checking repair requirements…" : "Checking installation requirements…"));
        try
        {
            InstallerTrace.Step(U.T("检查目标与运行状态","Check target and running processes"),xp,()=>{Core.ValidateTarget(xp);Core.CheckNotRunning();},Log);
            InstallerTrace.CaptureTarget(xp);
            var recovery=await ResolveBeforeInstall(xp); if(!recovery.Proceed)return;
            diagnosis = await Task.Run(() => Core.Diagnose(xp)); Log(diagnosis.Describe());
            if (repairing) releases.SelectedItem = Core.RepairRelease(releases.Items.Cast<Release>(), diagnosis);
            if (releases.SelectedItem is not Release selected) throw new IOException(U.T("没有可用的匹配安装包，请检查更新。", "No matching package is available. Check updates."));
            if (!Core.Compatible(diagnosis.SimulatorVersion, Core.Variant(selected))) throw new IOException(U.T("所选标准版不兼容当前 XP，请改选兼容版或点击修复。", "Standard is incompatible with this XP version. Select Compatibility or use Repair."));
            var choice = Prompt(repairing ? U.T("修复插件", "Repair plugin") : U.T("安装插件", "Install plugin"), U.T("目标：", "Target: ") + xp + "\n\n" + U.ReleaseName(selected) + "\n\n" +
                (repairing ? U.T("修复优先使用当前已安装版本；升级请使用“安装 / 更新插件”。\n当前版本：", "Repair prefers the installed version; use Install / update to upgrade.\nInstalled: ") + diagnosis.Version + U.T(" → 修复目标：", " → Repair target: ") + selected.Version + "\n" +
                    (Core.CompareVersion(selected.Version,diagnosis.Version)!=0 ? U.T("当前版本安装包不可用：本次将改为上述目标版本。\n", "The installed package is unavailable: this operation will change to the target version above.\n") : "") +
                    U.T("检测原因：", "Findings: ") + (diagnosis.Issues.Count == 0 ? U.T("文件校验通过，无需修复；仍可选择重新安装。", "Files verified; repair is unnecessary, but reinstallation is available.") : string.Join("\n",diagnosis.Issues)) + "\n\n" : "") +
                (diagnosis.Version != "" && Core.CompareVersion(selected.Version, diagnosis.Version) < 0 ? U.T("注意：将安装较旧版本。\n", "Note: this will downgrade the plugin.\n") : "") +
                (diagnosis.SimulatorVersion == "" ? U.T("XP 版本未识别，请先核对所选版本的兼容范围。\n", "XP version is unknown. Check the compatibility range before continuing.\n") : "") +
                U.T("保留配置：保留插件设置和分析器偏好。\n纯净重装：重置插件设置；下次打开随插件分析器时重置其偏好。\n两种方式都保留飞行记录、机场缓存和其他插件。", "Keep settings: preserve plugin and analyzer preferences.\nClean reinstall: reset plugin settings and reset the bundled analyzer on its next open.\nBoth modes preserve flight reports, airport caches and other plugins."),
                (U.T("保留配置", "Keep settings"), DialogResult.Yes), (U.T("纯净重装", "Clean reinstall"), DialogResult.No), No);
            if (choice is not (DialogResult.Yes or DialogResult.No)){stage.Text=U.T("已取消","Cancelled");InstallerTrace.Event("INSTALL_CANCELLED");return;} bool clean = choice == DialogResult.No;
            if(recovery.RebuildHash!="" && clean) { Prompt(U.T("恢复重装保留配置", "Recovery reinstall keeps settings"),U.T("本次是未完成事务的恢复重装，将保留当前设置。完成后如有需要，可另行选择重置配置。", "This recovery reinstall preserves current settings. You can reset them separately after recovery."));clean=false; }
            InstallerTrace.Event("INSTALL_SELECTION",new {selected.Version,selected.UiVariant,selected.DefaultLanguage,selected.LocalDirectory,clean,target=xp});
            InstallerTrace.Status(U.T("正在准备并校验安装包…", "Preparing and verifying the package…"));
            try{var drive=new DriveInfo(Path.GetPathRoot(Path.GetFullPath(xp))!);InstallerTrace.Event("DISK_SPACE",new {drive=drive.Name,availableBytes=drive.AvailableFreeSpace});}catch(Exception e){Error("Read target free space",e,false);}
            catalogCancellation?.Cancel(); operation = new(); SetBusy(true); SavePreferences(); temp = Directory.CreateTempSubdirectory("StarLux-LMM-install-").FullName;
            using var net = new Network(Log); PreparedPackage package;
            if (selected.LocalDirectory != "")
            {
                var original = await Task.Run(() => InstallerTrace.Step(U.T("校验本地安装包","Validate local package"),selected.LocalDirectory,()=>Core.Prepare(selected.LocalDirectory),Log)); var stageRoot = Path.Combine(temp, "payload");
                await Task.Run(() => { foreach (var f in original.Manifest.Files) { var dest = Core.SafePath(stageRoot, f.Path); InstallerTrace.Step(U.T("暂存安装文件","Stage package file"),Core.SafePath(original.Root,f.Path)+" -> "+dest,()=>{Directory.CreateDirectory(Path.GetDirectoryName(dest)!); File.Copy(Core.SafePath(original.Root, f.Path), dest);},Log); } }); package = new(original.Manifest, stageRoot); Core.ValidatePackage(package);
            }
            else { var zip = await net.Download(selected.Sources, Path.Combine(temp, "lmm.zip"), Preferred, Percent, operation.Token); var unpack = Path.Combine(temp, "plugin"); await Task.Run(() => InstallerTrace.Step(U.T("解压安装包","Extract package"),zip+" -> "+unpack,()=>Core.ExtractZip(zip, unpack),Log)); package = await Task.Run(() => InstallerTrace.Step(U.T("校验下载载荷","Validate downloaded payload"),unpack,()=>Core.Prepare(unpack, selected.Version),Log)); }
            if (package.Manifest.UiVariant == "") package.Manifest.UiVariant = Core.Variant(selected); Core.ValidateCompatibility(xp, package.Manifest);
            string? fwlRoot = null;
            if (package.Manifest.Kind == "flywithlua" && !Core.HasFwl(xp))
            {
                var answer = Prompt(U.T("安装 FlyWithLua", "Install FlyWithLua"), U.T("缺少 FlyWithLua NG+。可下载固定的 XP12 官方运行库，或导入已下载的 NG+ ZIP。", "FlyWithLua NG+ is missing. Download the pinned official XP12 runtime or import an existing NG+ ZIP."), (U.T("下载运行库", "Download runtime"), DialogResult.Yes), (U.T("导入 ZIP", "Import ZIP"), DialogResult.No), No);
                if (answer is not (DialogResult.Yes or DialogResult.No)) return; string zip;
                if (answer == DialogResult.Yes) zip = await net.Download(DependencySources(), Path.Combine(temp, "fwl.zip"), Preferred, Percent, operation.Token);
                else { using var file = new OpenFileDialog { Title = U.T("选择 XP12 FlyWithLua NG+ ZIP", "Select XP12 FlyWithLua NG+ ZIP"), Filter = "ZIP|*.zip" }; if (file.ShowDialog(this) != DialogResult.OK){InstallerTrace.Event("DEPENDENCY_IMPORT_CANCELLED");return;} zip = file.FileName;InstallerTrace.Event("USER_DEPENDENCY_FILE",new {path=zip}); }
                var unpack = Path.Combine(temp, "fwl"); await Task.Run(() => InstallerTrace.Step(U.T("解压安装包","Extract package"),zip+" -> "+unpack,()=>Core.ExtractZip(zip, unpack),Log)); fwlRoot = Core.FindFwl(unpack);
                var license = Path.Combine(Path.GetDirectoryName(fwlRoot)!, "LICENSE"); if (File.Exists(license) && !File.Exists(Path.Combine(fwlRoot, "LICENSE"))) File.Copy(license, Path.Combine(fwlRoot, "LICENSE"));
            }
            operation.Token.ThrowIfCancellationRequested();
            var reviewDiagnosis = await Task.Run(()=>Core.Diagnose(xp));
            var reviewPlan = await Task.Run(()=>Core.Plan(xp,package,fwlRoot));
            if(clean) foreach(var f in new[] { "LMM_Settings.cfg", "LMM_Log/LMM_Viewer.html", "LMM_Log/LMM_Viewer_Data.js" }) reviewPlan[Core.Scripts+"/"+f]="";
            reviewPlan[Core.Receipt]="receipt";
            using(var review = new MaintenanceReview(xp,reviewDiagnosis,U.T("确认安装变更", "Review installation changes"),plan:reviewPlan,
                explanation:U.ReleaseName(selected)+"\n"+(clean ? U.T("重置插件设置及随插件分析器偏好；飞行记录保留。", "Reset plugin settings and bundled analyzer preferences; keep flight records.") : U.T("保留插件设置、分析器偏好和飞行记录。", "Keep plugin settings, analyzer preferences and flight records."))+"\n"+U.T("下表列出新增、替换、清理和保留的文件。确认后会先预检并备份，再写入。", "The list shows additions, replacements, removals and preserved files. Access checks and backups precede deployment.")))
                if(review.ShowDialog(this)!=DialogResult.OK) { InstallerTrace.Status(U.T("已取消，插件文件未更改。", "Cancelled; plugin files unchanged.")); return; }
            applying = true; cancel.Enabled = false;
            InstallerTrace.Status(U.T("正在预检、备份并应用文件…", "Checking access, backing up and applying files…"));
            var backup = await Task.Run(() => Core.Install(baseDir, xp, package, fwlRoot, Log, Percent, clean: clean, reviewedPaths: reviewPlan.Keys.ToList(),rebuildPendingHash:recovery.RebuildHash)); Log(U.T("安装完成。备份：", "Installation complete. Backup: ") + backup);
            stage.Text=U.T("安装完成","Installation complete");InstallerTrace.Event("INSTALL_COMPLETE",new {backup,target=xp,selected.Version});
            Prompt(U.T("操作完成", "Completed"), U.T("插件已安装，请启动 X-Plane 验证加载。\n备份：", "Plugin installed. Start X-Plane to verify loading.\nBackup: ") + backup);
        }
        catch (OperationCanceledException) { stage.Text=U.T("已取消","Cancelled");Log(U.T("下载已取消", "Download cancelled")); }
        catch (Exception e) { Error(repairing?"Repair plugin":"Install plugin",e); }
        finally { applying = false; operation?.Dispose(); operation = null; SetBusy(false); await InspectTarget(); Cleanup(temp, "StarLux-LMM-install-"); }
    }
    async Task Uninstall(bool complete = false)
    {
        if (busy) return; using var trace=InstallerTrace.Begin("uninstall",new {target=target.Text.Trim()});SetBusy(true);
        try
        {
            var xp = target.Text.Trim(); Core.ValidateTarget(xp); Core.CheckNotRunning();
            await Task.Run(()=>Core.FinalizePending(xp,baseDir,Log));Core.CheckPending(xp,baseDir); var d = await Task.Run(()=>Core.Diagnose(xp));
            using var review = new MaintenanceReview(xp,d,U.T(complete ? "完全卸载 · 确认删除范围" : "卸载 · 保留个人数据", complete ? "Full uninstall · review removal" : "Uninstall · keep personal data"),removal:true,complete:complete,
                explanation:(complete ? U.T("移除程序、插件设置、缓存和安装记录。要清除全部已识别的飞行数据，请勾选下方选项。", "Remove programs, plugin settings, caches and receipt. Check the option below to remove all identified flight data too.") : U.T("仅卸载程序；保留插件设置、缓存和飞行记录。", "Remove programs only; preserve plugin settings, caches and flight records.")) + "\n" +
                U.T("仅删除清单中标记“删除”的文件。FlyWithLua、其他插件、未知文件和浏览器内偏好保留。备份保存在安装器旁的 backup 中，可恢复；不会删除安装器自身或其日志。", "Only rows marked Remove are deleted. FlyWithLua, other plugins, unknown files and browser preferences remain. A restorable backup is kept beside the installer; the installer and its logs are retained."));
            if(review.ShowDialog(this)!=DialogResult.OK) { InstallerTrace.Status(U.T("卸载已取消。", "Uninstall cancelled.")); return; }
            var selectedFiles = review.SelectedFiles; var includeReports = review.IncludeReports;
            InstallerTrace.Event("REMOVAL_APPROVED",new {target=xp,complete,includeReports,files=selectedFiles});
            InstallerTrace.Status(U.T("正在备份并卸载已确认的文件…", "Backing up and removing the reviewed files…"));
            catalogCancellation?.Cancel(); applying = true; SetBusy(true); var backup = await Task.Run(() => Core.RemoveReviewed(baseDir, xp, selectedFiles,complete,includeReports,Log,Percent)); Log(U.T("卸载完成。备份：", "Uninstalled. Backup: ") + backup);
            Prompt(U.T("卸载完成", "Uninstalled"), U.T("已移除所选文件：", "Removed selected files: ") + selectedFiles.Count + "\n" + (includeReports ? U.T("已移除清单中的飞行记录。", "Flight records listed in the review were removed.") : U.T("飞行记录已保留。", "Flight records preserved.")) + "\n" + U.T("恢复备份：", "Recovery backup: ") + backup);
            stage.Text=U.T("卸载完成","Uninstalled");InstallerTrace.Event("UNINSTALL_COMPLETE",new {backup,target=xp});
        }
        catch (Exception e) { Error("Uninstall plugin",e); }
        finally { applying = false; SetBusy(false); await InspectTarget(); }
    }
    async Task Restore()
    {
        if (busy) return; using var trace=InstallerTrace.Begin("restore",new {target=target.Text.Trim()});SetBusy(true);
        try
        {
            var xp = target.Text.Trim(); Core.ValidateTarget(xp); Core.CheckNotRunning();
            using var file = new OpenFileDialog { Title = U.T("选择备份事务清单", "Select backup transaction"), Filter = "transaction.json|transaction.json", InitialDirectory = Path.Combine(baseDir, "backup") };
            var pending = Core.SafePath(xp,Core.Pending);
            if(File.Exists(pending))
            {
                if(await Task.Run(()=>Core.FinalizePending(xp,baseDir,Log))) { Prompt(U.T("事务已完成", "Transaction finalized"),U.T("已核实文件与完成状态一致，清除了遗留标记，无需恢复旧文件。", "Verified the completed file state and cleared the stale marker. No rollback was needed."));return; }
                try
                {
                    var backup = Core.FindPendingBackup(xp,baseDir);
                    if(!string.IsNullOrEmpty(backup) && Directory.Exists(backup)) { Core.NoLinks(backup);file.InitialDirectory=backup;file.FileName="transaction.json"; }
                }
                catch(Exception e) { InstallerTrace.Fault("Read pending recovery location",e); }
            }
            if (file.ShowDialog(this) != DialogResult.OK){InstallerTrace.Event("RESTORE_CANCELLED");return;}
            InstallerTrace.Event("USER_RECOVERY_FILE",new {path=file.FileName,target=xp});InstallerTrace.Session?.Snapshot("selected-transaction.json",file.FileName);
            if (Prompt(U.T("恢复备份", "Restore backup"), U.T("将恢复此事务涉及的文件，包括纯净重装重置的插件配置。请优先选择最近的备份；浏览器偏好不在文件备份中。", "Restore files touched by this transaction, including plugin settings reset by clean reinstall. Prefer the most recent backup. Browser preferences are not part of file backups."), Yes, No) != DialogResult.OK) return;
            catalogCancellation?.Cancel(); applying = true; SetBusy(true); await Task.Run(() => Core.Restore(Path.GetDirectoryName(file.FileName)!, xp,true,Log)); Log(U.T("备份已恢复", "Backup restored"));
            stage.Text=U.T("备份已恢复","Backup restored");InstallerTrace.Event("RESTORE_COMPLETE",new {transaction=file.FileName,target=xp});
        }
        catch (Exception e) { Error("Restore backup",e); }
        finally { applying = false; SetBusy(false); await InspectTarget(); }
    }
    async Task UpdateInstaller()
    {
        using var trace=InstallerTrace.Begin("installer-self-update");
        var selected = installerCatalog?.Releases.FirstOrDefault(); if (selected == null || Core.CompareVersion(selected.Version, SelfUpdater.Version) <= 0) return;
        if (Prompt(U.T("更新安装器", "Update installer"), U.T("将下载并校验安装器，然后关闭当前窗口、替换程序并重新启动。插件、配置和备份目录保持原位。\n\n新版本：", "Download and verify the installer, close this window, replace the executable and restart. Plugin files, settings and backup folders stay in place.\n\nNew version: ") + selected.Version, Yes, No) != DialogResult.OK) return;
        string? temp = null;
        try
        {
            catalogCancellation?.Cancel(); operation = new(); SetBusy(true); temp = Directory.CreateTempSubdirectory("StarLux-LMM-update-download-").FullName;
            using var net = new Network(Log); var zip = await net.Download(selected.Sources, Path.Combine(temp, "update.zip"), Preferred, Percent, operation.Token); var unpack = Path.Combine(temp, "unpack"); await Task.Run(() => InstallerTrace.Step(U.T("解压安装包","Extract package"),zip+" -> "+unpack,()=>Core.ExtractZip(zip, unpack),Log)); operation.Token.ThrowIfCancellationRequested();
            var request = await Task.Run(() => InstallerTrace.Step(U.T("准备安装器自更新","Stage installer self-update"),unpack,()=>SelfUpdater.Stage(unpack, selected.Version),Log));InstallerTrace.Event("SELF_UPDATE_HELPER",new {request,version=selected.Version}); SavePreferences(); SelfUpdater.Launch(request); closingForUpdate = true; Close();
        }
        catch (OperationCanceledException) { Log(U.T("更新下载已取消", "Update download cancelled")); }
        catch (Exception e) { Error("Installer self-update",e); }
        finally { operation?.Dispose(); operation = null; if (!IsDisposed) SetBusy(false); Cleanup(temp, "StarLux-LMM-update-download-"); }
    }
    IEnumerable<DownloadSource> DependencySources()
    {
        var file = Path.Combine(baseDir, "version/flywithlua-mirrors.json"); var list = new List<DownloadSource>();
        if (File.Exists(file)) foreach (var m in JsonSerializer.Deserialize<List<DownloadSource>>(File.ReadAllText(file), Core.Json) ?? []) if (m.Sha256.Equals(Network.OfficialFwl.Sha256, StringComparison.OrdinalIgnoreCase) && Uri.TryCreate(m.Url, UriKind.Absolute, out var uri) && Network.TrustedInitial(uri)) list.Add(m);
        list.Add(Network.OfficialFwl); return list;
    }
    void Cleanup(string? temp, string prefix) { if (temp == null) return; try { Core.NoLinks(temp); if (Path.GetDirectoryName(temp) == Path.GetTempPath().TrimEnd('\\') && Path.GetFileName(temp).StartsWith(prefix, StringComparison.Ordinal)) Directory.Delete(temp, true); } catch (Exception e) { Error("Clean temporary directory "+temp,e,false); } }
}
