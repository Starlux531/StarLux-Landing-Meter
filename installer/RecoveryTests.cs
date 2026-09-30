using System.Text.Json;

namespace StarLux.Installer;

static class RecoveryTests
{
    static void Assert(bool ok,string text){if(!ok)throw new Exception(text);}
    public static void Run(Action<string,Action> test,string root)
    {
        void Case(string name,Action<string,string,PreparedPackage> action)=>test("recovery: "+name,()=>{
            var home=Path.Combine(root,"recovery-"+Guid.NewGuid().ToString("N"));var xp=Path.Combine(home,"XP");
            void Write(string r,string p,string text){var file=Core.SafePath(r,p);Directory.CreateDirectory(Path.GetDirectoryName(file)!);File.WriteAllText(file,text);}
            Write(xp,"X-Plane.exe","fixture");Write(xp,"Log.txt","X-Plane 12.4.4\n");Write(xp,Core.Fwl+"/win_x64/FlyWithLua.xpl","runtime");Write(xp,Core.Fwl+"/Internals/FlyWithLua.ini","ini");
            Write(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc2.lua","original");Write(xp,Core.Scripts+"/LMM_Settings.cfg","settings");Write(xp,Core.Scripts+"/LMM_Log/LMM_TEST.txt","flight");Write(xp,Core.Scripts+"/other.lua","other");
            var payload=Path.Combine(home,"payload");Write(payload,"StarLux_LMM_v1.1.9rc3.lua","new");Write(payload,"LMM_Report_Reader.html","<html><head></head></html>");
            var p=new PreparedPackage(new PackageManifest {Version="1.1.9rc3",UiVariant="sdk440",Files=Core.Files(payload).Select(f=>new PayloadFile(Path.GetFileName(f),Core.Hash(f))).ToList()},payload);
            action(home,xp,p);
        });
        string Install(string home,string xp,PreparedPackage p,int fail=-1,string rebuild="",Action<int>? progress=null)=>Core.Install(Path.Combine(home,"portable"),xp,p,null,_=>{},progress??(_=>{}),false,fail,rebuildPendingHash:rebuild);
        string Interrupted(string home,string xp,PreparedPackage p)
        {
            FileStream? held=null;
            try { Install(home,xp,p,1,progress:_=>{}); }catch(IOException){} // A successful automatic rollback is not the interrupted fixture.
            try { Core.Install(Path.Combine(home,"portable"),xp,p,null,_=>{},_=>{
                var deployed=p.Manifest.Files.Select(f=>Core.SafePath(xp,Core.Scripts+"/"+f.Path)).First(File.Exists);
                held=new FileStream(deployed,FileMode.Open,FileAccess.Read,FileShare.None);throw new IOException("Simulated interruption");},false); }
            catch(IOException){}finally{held?.Dispose();}
            var marker=Core.SafePath(xp,Core.Pending);Assert(File.Exists(marker),"fixture lacks pending marker");
            return JsonSerializer.Deserialize<PendingRecovery>(File.ReadAllText(marker),Core.Json)!.Backup;
        }
        void Preserved(string xp){foreach(var (rel,text) in new[]{("LMM_Settings.cfg","settings"),("LMM_Log/LMM_TEST.txt","flight"),("other.lua","other")})Assert(File.ReadAllText(Core.SafePath(xp,Core.Scripts+"/"+rel))==text,"lost personal/shared file");}
        Case("moved and renamed modern backup restores and clears marker",(home,xp,p)=>{
            var old=Interrupted(home,xp,p);var movedRoot=Path.Combine(home,"moved-installer/backup");Directory.CreateDirectory(movedRoot);var moved=Path.Combine(movedRoot,"renamed-backup");Directory.Move(old,moved);
            var found=Core.FindPendingBackup(xp,Path.Combine(home,"moved-installer"));Assert(found!="" && Core.NormalizeDirectory(found)==Core.NormalizeDirectory(moved),"relocated ID not discovered: "+found);
            Core.Restore(moved,xp,false);Assert(!File.Exists(Core.SafePath(xp,Core.Pending)),"moved recovery left blocking marker");Assert(File.ReadAllText(Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc2.lua"))=="original","original lost");Install(home,xp,p);Assert(Core.Diagnose(xp).Verified,"subsequent installation blocked");Preserved(xp);
        });
        Case("legacy moved backup accepted by transaction folder plus target and hashes",(home,xp,p)=>{
            var old=Interrupted(home,xp,p);File.WriteAllText(Core.SafePath(xp,Core.Pending),JsonSerializer.Serialize(new {backup=old}));
            var movedRoot=Path.Combine(home,"moved-legacy/backup");Directory.CreateDirectory(movedRoot);var moved=Path.Combine(movedRoot,Path.GetFileName(old));Directory.Move(old,moved);
            var found=Core.FindPendingBackup(xp,Path.Combine(home,"moved-legacy"));Assert(found!="" && Core.NormalizeDirectory(found)==Core.NormalizeDirectory(moved),"legacy relocation not found: "+found);Core.Restore(moved,xp,false);Assert(!File.Exists(Core.SafePath(xp,Core.Pending)),"legacy stale marker remains");Preserved(xp);
        });
        Case("unrelated backup rejected before any file changes",(home,xp,p)=>{
            var older=Install(home,xp,p);Core.Restore(older,xp,false);Interrupted(home,xp,p);var marker=Core.Hash(Core.SafePath(xp,Core.Pending));
            var currentFile=p.Manifest.Files.Select(f=>Core.SafePath(xp,Core.Scripts+"/"+f.Path)).First(File.Exists);var current=Core.Hash(currentFile);
            try{Core.Restore(older,xp,false);throw new Exception("wrong transaction accepted");}catch(DiagnosticFailure e){Assert(e.Code=="WRONG_RECOVERY_TRANSACTION","wrong failure code");}
            Assert(Core.Hash(Core.SafePath(xp,Core.Pending))==marker&&Core.Hash(currentFile)==current,"wrong backup modified state");
        });
        Case("missing backup and all program files missing rebuild without losing data",(home,xp,p)=>{
            Install(home,xp,p);foreach(var f in Core.OwnedFiles(xp))File.Delete(Core.SafePath(xp,f));
            var marker=Core.SafePath(xp,Core.Pending);var old=JsonSerializer.Serialize(new {backup=Path.Combine(home,"lost/backup/20260929-212314-ef45453d")});File.WriteAllText(marker,old);
            var backup=Install(home,xp,p,rebuild:Core.Hash(marker));Assert(Core.Diagnose(xp).Verified&&!File.Exists(marker),"repair cannot escape orphaned marker");
            Assert(File.ReadAllText(Path.Combine(backup,"superseded-pending.json"))==old,"old evidence not archived");Preserved(xp);
        });
        Case("rebuild failure restores previous marker and current files",(home,xp,p)=>{
            var marker=Core.SafePath(xp,Core.Pending);var old=JsonSerializer.Serialize(new {backup=Path.Combine(home,"lost/backup/20260929-212314-ef45453d")});File.WriteAllText(marker,old);
            try{Install(home,xp,p,1,Core.Hash(marker));throw new Exception("injected failure absent");}catch(IOException){}
            Assert(File.ReadAllText(marker)==old,"old marker lost on failed rebuild");Assert(File.ReadAllText(Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc2.lua"))=="original","current state not restored");Preserved(xp);
        });
        Case("cancel/stale approval and invalid payload cannot clear old marker",(home,xp,p)=>{
            var marker=Core.SafePath(xp,Core.Pending);File.WriteAllText(marker,JsonSerializer.Serialize(new {backup=Path.Combine(home,"lost")}));var before=Core.Hash(marker);
            try{Install(home,xp,p,rebuild:new string('a',64));throw new Exception("stale approval accepted");}catch(IOException){}
            File.AppendAllText(Core.SafePath(p.Root,p.Manifest.Files[0].Path),"tampered");
            try{Install(home,xp,p,rebuild:before);throw new Exception("invalid payload accepted");}catch(IOException){}
            Assert(Core.Hash(marker)==before,"rejected repair removed evidence");Preserved(xp);
        });
        Case("completed install with failed marker cleanup never rolls back",(home,xp,p)=>{
            var marker=Core.SafePath(xp,Core.Pending);
            try { try{Install(home,xp,p,progress:value=>{if(value==100)File.SetAttributes(marker,FileAttributes.ReadOnly);});throw new Exception("cleanup failure not detected");}
                catch(DiagnosticFailure e){Assert(e.Code=="FINALIZE_REQUIRED","successful install unnecessarily rolled back");} }
            finally{if(File.Exists(marker))File.SetAttributes(marker,FileAttributes.Normal);}
            Assert(File.ReadAllText(Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc3.lua"))=="new","completed files reverted");
            Assert(Core.FinalizePending(xp,Path.Combine(home,"portable")),"completed marker not finalized");Assert(Core.Diagnose(xp).Verified,"finalization unhealthy");Preserved(xp);
        });
        Case("completed status alone cannot clear marker when files differ",(home,xp,p)=>{
            var backup=Install(home,xp,p);File.WriteAllText(Core.SafePath(xp,Core.Pending),JsonSerializer.Serialize(new {backup}));File.AppendAllText(Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc3.lua"),"changed");
            Assert(!Core.FinalizePending(xp,Path.Combine(home,"portable"))&&File.Exists(Core.SafePath(xp,Core.Pending)),"unverified stale status trusted");
        });
        Case("repeated version changes, reinstalls and uninstall keep transaction state clean",(home,xp,p)=>{
            var previous=Path.Combine(home,"older");Directory.CreateDirectory(previous);File.WriteAllText(Path.Combine(previous,"StarLux_LMM_v1.1.9rc2.lua"),"older");var old=new PreparedPackage(new PackageManifest {Version="1.1.9rc2",UiVariant="legacy",Files=[new("StarLux_LMM_v1.1.9rc2.lua",Core.Hash(Path.Combine(previous,"StarLux_LMM_v1.1.9rc2.lua")))]},previous);
            foreach(var package in new[]{p,p,old,p,old,p}) {Install(home,xp,package);Assert(Core.Diagnose(xp).Verified&&!File.Exists(Core.SafePath(xp,Core.Pending)),"version switching leaves pending state");Preserved(xp);}
            Core.Uninstall(Path.Combine(home,"portable"),xp,_=>{},_=>{},false);Install(home,xp,p);Assert(Core.Diagnose(xp).Verified,"uninstall/reinstall blocked");Preserved(xp);
        });
        Case("moving simulator cannot restore into an old or different target",(home,xp,p)=>{
            var backup=Install(home,xp,p);var moved=xp+"-moved";Directory.Move(xp,moved);
            try{Core.Restore(backup,moved,false);throw new Exception("wrong target accepted");}catch(DiagnosticFailure e){Assert(e.Code=="BACKUP_TARGET_MISMATCH","incorrect moved-target error");}
            Assert(!Directory.Exists(xp),"old simulator path recreated");Preserved(moved);
        });
    }
}
