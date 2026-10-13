using System.IO.Compression;
using System.Text.Json;

namespace StarLux.Installer;

static class DiagnosticsTests
{
    static void Check(bool ok,string message){if(!ok)throw new Exception(message);}
    static void Write(string root,string relative,string value){var p=Core.SafePath(root,relative);Directory.CreateDirectory(Path.GetDirectoryName(p)!);File.WriteAllText(p,value);}
    public static void Run(Action<string,Action> test,string root)
    {
        void Case(string name,Action<string,DiagnosticSession> action)
        {
            test("diagnostics: "+name,()=>{
                var dir=Path.Combine(root,"diagnostics-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);
                var previous=InstallerTrace.Session;
                using var session=new DiagnosticSession(Path.Combine(dir,"logs"));InstallerTrace.Session=session;
                try{action(dir,session);}finally{InstallerTrace.Session=previous;}
            });
        }
        (string xp,PreparedPackage package) Fixture(string dir)
        {
            var xp=Path.Combine(dir,"XP");
            Write(xp,"X-Plane.exe","fixture");Write(xp,"Log.txt","log.txt for X-Plane 12.4.3-r2\n");
            Write(xp,Core.Fwl+"/win_x64/FlyWithLua.xpl","runtime");Write(xp,Core.Fwl+"/Internals/FlyWithLua.ini","ini");
            Write(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc2.lua","OLD");
            Write(xp,Core.Scripts+"/LMM_Settings.cfg","DO_NOT_EXPORT_CONFIG");
            Write(xp,Core.Scripts+"/LMM_Log/private-flight.txt","DO_NOT_EXPORT_FLIGHT");
            var payload=Path.Combine(dir,"payload");Write(payload,"StarLux_LMM_v1.1.9rc2.lua","NEW");
            Write(payload,"LMM_Report_Reader.html","<html><head></head><body>reader</body></html>");
            var m=new PackageManifest{Version="1.1.9rc2",UiVariant="legacy",Files=Core.Files(payload).Select(p=>new PayloadFile(Path.GetRelativePath(payload,p).Replace('\\','/'),Core.Hash(p))).ToList()};
            return(xp,new(m,payload));
        }
        Case("immediate UTF8 flush and concurrent action correlation",(dir,session)=>{
            Parallel.For(0,30,i=>{using var scope=InstallerTrace.Begin("parallel-"+i);InstallerTrace.Write("中文路径 / step-"+i);});
            var text=File.ReadAllText(session.LogPath);
            for(var i=0;i<30;i++)Check(text.Contains("step-"+i)&&text.Contains("parallel-"+i+"-"),"missing concurrent action");
            Check(text.Contains("中文路径"),"UTF8 lost");Check(text.Contains("ACTION_END"),"scope missing");
            var old=session.LogPath;using var next=new DiagnosticSession(Path.Combine(dir,"logs"));
            Check(next.LogPath!=old&&File.ReadAllText(old)==text,"new launch overwrote previous log");
        });
        test("diagnostics: read-only primary uses writable fallback",()=>{
            var dir=Path.Combine(root,"logger-fallback");Directory.CreateDirectory(dir);var blocked=Path.Combine(dir,"blocked");File.WriteAllText(blocked,"file");
            using var s=new DiagnosticSession(Path.Combine(blocked,"logs"),Path.Combine(dir,"fallback"));
            s.Write("TEST","survived");Check(s.LogPath.Contains("fallback")&&File.ReadAllText(s.LogPath).Contains("survived"),"fallback failed");
            Check(s.StorageWarning!="","fallback not reported");
            using var unavailable=new DiagnosticSession(Path.Combine(blocked,"logs"));unavailable.Write("TEST","memory only");
            var zip=Path.Combine(dir,"memory.zip");unavailable.Export(zip);using var z=ZipFile.OpenRead(zip);Check(z.GetEntry("current-memory.log")!=null,"memory diagnostics lost");
        });
        Case("successful install includes every deployment and recovery metadata",(dir,session)=>{
            var (xp,p)=Fixture(dir);
            var backup=Core.Install(Path.Combine(dir,"portable"),xp,p,null,InstallerTrace.Write,_=>{},false);
            var text=File.ReadAllText(session.LogPath);
            foreach(var f in p.Manifest.Files)Check(text.Contains(f.Path),"missing file trace: "+f.Path);
            Check(Core.Diagnose(xp).Verified,"successful package invalid");
            Check(text.Contains("transaction.json")&&text.Contains("install.pending.json"),"transaction trace missing");
            Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"LMM_Settings.cfg"))=="DO_NOT_EXPORT_CONFIG","settings touched");
            Core.Restore(backup,xp,false,InstallerTrace.Write);
            Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.9rc2.lua"))=="OLD","restore incomplete");
        });
        Case("original error survives successful rollback",(dir,session)=>{
            var (xp,p)=Fixture(dir);Exception? caught=null;
            try{Core.Install(Path.Combine(dir,"portable"),xp,p,null,InstallerTrace.Write,_=>{},false,1);}catch(Exception e){caught=e;}
            Check(caught!=null&&caught.Message=="Injected test failure","original failure lost");
            var text=File.ReadAllText(session.LogPath);Check(text.Contains("Injected test failure")&&text.Contains("ExecutePlan"),"stack not persisted");
            Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.9rc2.lua"))=="OLD","rollback failed");
            var transaction=Directory.GetFiles(Path.Combine(dir,"portable/backup"),"transaction.json",SearchOption.AllDirectories).Single();
            var j=JsonSerializer.Deserialize<Journal>(File.ReadAllText(transaction),Core.Json)!;
            Check(j.Status=="restored"&&j.Failure.Contains("Injected test failure"),"journal erased first failure");
        });
        Case("rollback failure preserves marker and both errors",(dir,session)=>{
            var (xp,p)=Fixture(dir);FileStream? held=null;Exception? caught=null;
            try
            {
                Core.Install(Path.Combine(dir,"portable"),xp,p,null,InstallerTrace.Write,_=>{
                    held=new FileStream(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.9rc2.lua"),FileMode.Open,FileAccess.Read,FileShare.None);
                    throw new IOException("SIMULATED_FIRST_WRITE_FAILURE");
                },false);
            }
            catch(Exception e){caught=e;}
            finally{held?.Dispose();}
            Check(caught is DiagnosticFailure {Code:"ROLLBACK_FAILED"},"missing recovery-specific error");
            Check(caught!.ToString().Contains("SIMULATED_FIRST_WRITE_FAILURE"),"first exception lost");
            Check(File.Exists(Path.Combine(xp,"Resources/plugins/StarLux_LMM.install.pending.json")),"unsafe pending marker deletion");
            var transaction=Directory.GetFiles(Path.Combine(dir,"portable/backup"),"transaction.json",SearchOption.AllDirectories).Single();
            var j=JsonSerializer.Deserialize<Journal>(File.ReadAllText(transaction),Core.Json)!;
            Check(j.Failure.Contains("SIMULATED_FIRST_WRITE_FAILURE")&&j.RollbackFailure!="","two causes not retained");
            Core.Restore(Path.GetDirectoryName(transaction)!,xp,false,InstallerTrace.Write);
            Check(!File.Exists(Path.Combine(xp,"Resources/plugins/StarLux_LMM.install.pending.json")),"manual recovery did not clear matching marker");
        });
        Case("missing original backup explained before any new transaction",(dir,session)=>{
            var (xp,p)=Fixture(dir);var missing=Path.Combine(dir,"原来的安装器","backup","missing");
            Write(xp,"Resources/plugins/StarLux_LMM.install.pending.json",JsonSerializer.Serialize(new {backup=missing}));
            Exception? caught=null;try{Core.Install(Path.Combine(dir,"portable"),xp,p,null,InstallerTrace.Write,_=>{},false);}catch(Exception e){caught=e;}
            Check(caught is DiagnosticFailure {Code:"RECOVERY_BACKUP_MISSING"},"not diagnosed");
            Check(InstallerTrace.Describe(caught!).Contains("原来的安装器"),"human-readable Unicode path missing");
            Check(!Directory.Exists(Path.Combine(dir,"portable/backup")),"created unrelated backup");
            Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.9rc2.lua"))=="OLD","pending recovery modified files");
            var zip=Path.Combine(dir,"support.zip");session.Export(zip);
            using var archive=ZipFile.OpenRead(zip);
            Check(archive.Entries.Any(e=>e.Name.EndsWith("pending.json")),"pending snapshot absent");
            foreach(var entry in archive.Entries){using var reader=new StreamReader(entry.Open());var text=reader.ReadToEnd();Check(!text.Contains("DO_NOT_EXPORT_CONFIG")&&!text.Contains("DO_NOT_EXPORT_FLIGHT"),"private data exported");}
        });
        Case("corrupt package reports file and expected/actual hash",(dir,session)=>{
            var (_,p)=Fixture(dir);File.AppendAllText(Path.Combine(p.Root,"StarLux_LMM_v1.1.9rc2.lua"),"tampered");
            Exception? caught=null;try{Core.ValidatePackage(p);}catch(Exception e){caught=e;}
            Check(caught is DiagnosticFailure {Code:"PACKAGE_HASH_MISMATCH"},"checksum cause missing");
            var text=InstallerTrace.Describe(caught!);Check(text.Contains("StarLux_LMM_v1.1.9rc2.lua")&&text.Contains("Expected:")&&text.Contains("Actual:"),"checksum details missing");
        });
        Case("missing/corrupt recovery files rejected before restoration",(dir,session)=>{
            var (xp,p)=Fixture(dir);var backup=Core.Install(Path.Combine(dir,"portable"),xp,p,null,InstallerTrace.Write,_=>{},false);
            File.Delete(Path.Combine(backup,"files",Core.Scripts,"StarLux_LMM_v1.1.9rc2.lua"));
            Exception? caught=null;try{Core.Restore(backup,xp,false);}catch(Exception e){caught=e;}
            Check(caught is FileNotFoundException,"missing backup not identified");
            Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.9rc2.lua"))=="NEW","partially restored before validation");
            Check(InstallerTrace.Describe(caught!).Contains("PATH_MISSING"),"missing-file explanation");
        });
        Case("permissions, disk full, sharing and unknown errors not conflated",(dir,session)=>{
            Check(InstallerTrace.Describe(new UnauthorizedAccessException("Denied")).Contains("ACCESS_DENIED"),"permissions");
            Check(InstallerTrace.Describe(new IOException("full",unchecked((int)0x80070070))).Contains("DISK_FULL"),"disk full");
            Check(InstallerTrace.Describe(new IOException("locked",unchecked((int)0x80070020))).Contains("FILE_IN_USE"),"file lock");
            Check(InstallerTrace.Describe(new Exception("unknown")).Contains("OPERATION_FAILED"),"unknown");
            Check(Core.CompareVersion("1.0.2rc2","1.0.2")>0&&Core.CompareVersion("1.0.3","1.0.2rc2")>0,"maintenance ordering");
            Check(Core.CompareVersion("1.0.2-rc2","1.0.2")<0,"normal prerelease ordering");
        });
    }
}
