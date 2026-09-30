namespace StarLux.Installer;

public sealed partial class MainForm
{
    async Task<(bool Proceed,string RebuildHash)> ResolveBeforeInstall(string xp)
    {
        if(!File.Exists(Core.SafePath(xp,Core.Pending)))return (true,"");
        if(await Task.Run(()=>Core.FinalizePending(xp,baseDir,Log)))return (true,"");
        var backup=await Task.Run(()=>Core.FindPendingBackup(xp,baseDir));
        var before=Core.Hash(Core.SafePath(xp,Core.Pending));
        var choice=Prompt(U.T("处理上次未完成操作", "Resolve interrupted operation"),
            (backup!="" ? U.T("已找到对应备份：", "Matching backup found: ")+backup : U.T("原位置和当前安装器的 backup 中均未找到对应备份。备份可能被移动、删除或未复制。", "No matching backup found at the original location or beside this installer. It may have been moved, deleted or omitted when copying."))+"\n\n"+
            U.T("恢复备份：找回原文件，再继续安装。\n保留数据重新安装：从完整安装包重新部署程序，保留当前设置和飞行记录；先备份当前现状并归档旧事务。无法凭空恢复已经丢失的旧文件。\n两种方式都不会直接删除标记后裸装，下一步仍需确认具体安装清单。", "Restore backup: recover the original files, then continue.\nReinstall, keep data: redeploy from a complete package, retain current settings and flight records, and back up the current state plus the old marker first. Already lost files cannot be recovered.\nBoth paths retain transaction protection. Review the exact install plan before any deployment."),
            (backup!=""?U.T("恢复对应备份", "Restore matching backup"):U.T("定位原备份", "Locate original backup"),DialogResult.Yes),
            (U.T("保留数据重新安装", "Reinstall, keep data"),DialogResult.No),No);
        if(choice==DialogResult.No) { InstallerTrace.Event("REBUILD_PENDING_APPROVED",new {target=xp,markerHash=before}); return (true,before); }
        if(choice!=DialogResult.Yes)return (false,"");
        if(backup=="")
        {
            using var file=new OpenFileDialog {Title=U.T("选择原 transaction.json", "Select original transaction.json"),Filter="transaction.json|transaction.json",InitialDirectory=Path.Combine(baseDir,"backup")};
            if(file.ShowDialog(this)!=DialogResult.OK)return (false,""); backup=Path.GetDirectoryName(file.FileName)!;
        }
        applying=true;SetBusy(true);
        try { await Task.Run(()=>Core.Restore(backup,xp,true,Log)); }
        finally { applying=false;SetBusy(true); }
        if(File.Exists(Core.SafePath(xp,Core.Pending))) { InstallerTrace.Status(U.T("现状已恢复，原来的未完成事务仍需处理；请再次选择修复。", "Current state restored; an earlier pending transaction still needs attention. Select Repair again."));return (false,""); }
        InstallerTrace.Status(U.T("对应备份已恢复，现在继续检查安装包。", "Matching backup restored; continuing with package checks."));return (true,"");
    }
}
