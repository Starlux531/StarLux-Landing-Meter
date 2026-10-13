namespace StarLux.Installer;

static class LifecycleTests
{
    static void Assert(bool condition,string message) { if(!condition)throw new Exception(message); }
    public static void Run(Action<string,Action> test,string root)
    {
        var xp=Path.Combine(root,"lifecycle-XP"); var home=Path.Combine(root,"lifecycle-home");var payload=Path.Combine(root,"lifecycle-payload");
        void Write(string dir,string rel,string text) { var p=Core.SafePath(dir,rel);Directory.CreateDirectory(Path.GetDirectoryName(p)!);File.WriteAllText(p,text); }
        void Data(string rel,string text="user-data")=>Write(xp,Core.Scripts+"/"+rel,text);
        Write(xp,"X-Plane.exe","fixture");Write(xp,"Log.txt","X-Plane 12.4.4\n");
        Write(xp,Core.Fwl+"/win_x64/FlyWithLua.xpl","runtime");Write(xp,Core.Fwl+"/Internals/FlyWithLua.ini","ini");
        Write(payload,"StarLux_LMM_v1.1.9rc3.lua","new plugin");Write(payload,"LMM_Report_Reader.html","<html><head></head></html>");Write(payload,"LMM_UI_119/core.lua","new module");
        var package=new PreparedPackage(new PackageManifest {Version="1.1.9rc3",UiVariant="sdk440",Files=Core.Files(payload).Select(p=>new PayloadFile(Path.GetRelativePath(payload,p).Replace('\\','/'),Core.Hash(p))).ToList()},payload);
        void Install()=>Core.Install(home,xp,package,null,_=>{},_=>{},false);
        void Seed()
        {
            Data("LMM_Settings.cfg");Data("LMM_Apt_Index_v1.cache");Data("LMM_Startup_Diagnostic.txt");
            Data("LMM_Log/LMM_TEST_A320_2026-09-29_CN.txt");Data("LMM_Log/LMM_TEST_A320_2026-09-29_CN.txt.previous");
            Data("LMM_Log/LMM_TEST_A320_2026-09-29_CN.txt.recording.tmp");Data("LMM_Log/.LMM_Recording_20260929_123456_1.part");
            Data("LMM_Log/LMM_Trends_Analyzer.html");Data("LMM_Log/README.txt","StarLux Landing Meter documentation");
            Data("LMM_Log/.lmm-update-standard.txt");Data("LMM_Log/.lmm_index.tmp");
            Data("LMM_Log/my-private-note.txt");Data("LMM_UI_119/notes.user");Data("other.lua");Data("LICENSE","shared license");
        }
        Install(); Seed();
        test("lifecycle: inventory identifies program, config, records and protected unknowns",()=>{
            var d=Core.Diagnose(xp);Assert(d.Verified,"user data incorrectly triggers repair");
            foreach(var category in new[]{"program","settings","cache","reports","metadata","unknown"})Assert(d.Files.Any(f=>f.Category==category),"missing category: "+category);
            Assert(d.Files.Count(f=>f.Category=="reports")==4,"incomplete recordings not inventoried");
            Assert(d.Files.Any(f=>f.Path.EndsWith("notes.user")&&!f.Removable),"unknown module data unprotected");
        });
        test("lifecycle: exact hash and missing-file repair evidence",()=>{
            Data("LMM_Report_Reader.html","modified");File.Delete(Core.SafePath(xp,Core.Scripts+"/LMM_UI_119/core.lua"));
            var d=Core.Diagnose(xp);var changed=d.Files.Single(f=>f.Path.EndsWith("LMM_Report_Reader.html"));
            Assert(!d.Verified&&changed.Expected.Length==64&&changed.Actual.Length==64&&changed.Expected!=changed.Actual,"missing checksum evidence");
            Assert(d.Files.Any(f=>!f.Exists&&f.Path.EndsWith("core.lua")),"missing file hidden");Install();
        });
        test("lifecycle: full uninstall without record consent preserves all flight data",()=>{
            var d=Core.Diagnose(xp);var remove=Core.RemovalFiles(d,true,false);
            Assert(remove.Contains(Core.Scripts+"/LMM_Settings.cfg")&&!remove.Any(p=>p.EndsWith(".part")),"wrong default scope");
            var backup=Core.RemoveReviewed(home,xp,remove,true,false,_=>{},_=>{},false);
            Assert(!File.Exists(Core.SafePath(xp,Core.Scripts+"/LMM_Settings.cfg")),"settings retained");
            foreach(var f in d.Files.Where(f=>f.Category is "reports" or "unknown"))Assert(File.Exists(Core.SafePath(xp,f.Path)),"unapproved deletion: "+f.Path);
            Assert(Core.HasFwl(xp),"shared runtime removed");Core.Restore(backup,xp,false);
        });
        test("lifecycle: complete removal and recovery restores every approved byte",()=>{
            var d=Core.Diagnose(xp);var remove=Core.RemovalFiles(d,true,true);var hashes=remove.ToDictionary(p=>p,p=>Core.Hash(Core.SafePath(xp,p)));
            var backup=Core.RemoveReviewed(home,xp,remove,true,true,_=>{},_=>{},false);
            foreach(var f in remove)Assert(!File.Exists(Core.SafePath(xp,f)),"approved file remains: "+f);
            Assert(File.Exists(Core.SafePath(xp,Core.Scripts+"/other.lua"))&&File.Exists(Core.SafePath(xp,Core.Scripts+"/LICENSE")),"shared file removed");
            Core.Restore(backup,xp,false);foreach(var (p,h) in hashes)Assert(Core.Hash(Core.SafePath(xp,p))==h,"recovery mismatch: "+p);
        });
        test("lifecycle: failed full removal rolls back settings and flight data",()=>{
            var remove=Core.RemovalFiles(Core.Diagnose(xp),true,true);var hashes=remove.ToDictionary(p=>p,p=>Core.Hash(Core.SafePath(xp,p)));
            try { Core.RemoveReviewed(home,xp,remove,true,true,_=>{},_=>{},false,5);throw new Exception("injected failure did not occur"); }catch(IOException){}
            foreach(var (p,h) in hashes)Assert(Core.Hash(Core.SafePath(xp,p))==h,"rollback lost: "+p);
        });
        test("lifecycle: altered removal scope cannot delete other plugins",()=>{
            var remove=Core.RemovalFiles(Core.Diagnose(xp),true,true);remove.Add(Core.Scripts+"/other.lua");
            try{Core.RemoveReviewed(home,xp,remove,true,true,_=>{},_=>{},false);throw new Exception("unsafe request accepted");}catch(IOException){}
            Assert(Core.Diagnose(xp).Verified,"unsafe request changed target");
        });
        test("lifecycle: read-only and locked target rejected before any deployment",()=>{
            var reader=Core.SafePath(xp,Core.Scripts+"/LMM_Report_Reader.html");var main=Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.9rc3.lua");
            Data("StarLux_LMM_v1.1.9rc3.lua","original main");var before=Core.Hash(main);
            File.SetAttributes(reader,FileAttributes.ReadOnly);
            try{try{Install();throw new Exception("read-only accepted");}catch(DiagnosticFailure e){Assert(e.Code=="TARGET_READ_ONLY"&&e.FailurePath==reader,"read-only reason lacks file");}}
            finally{File.SetAttributes(reader,FileAttributes.Normal);}
            using(var held=new FileStream(reader,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
                try{Install();throw new Exception("locked target accepted");}catch(IOException){}
            Assert(Core.Hash(main)==before&&!File.Exists(Core.SafePath(xp,Core.Pending)),"partial deployment or pending marker created");Install();
        });
        test("lifecycle: fresh files outside approved preview remain untouched",()=>{
            var remove=Core.RemovalFiles(Core.Diagnose(xp),true,true);Data("LMM_Log/LMM_NEW_FLIGHT.txt","new flight");
            var backup=Core.RemoveReviewed(home,xp,remove,true,true,_=>{},_=>{},false);
            Assert(File.Exists(Core.SafePath(xp,Core.Scripts+"/LMM_Log/LMM_NEW_FLIGHT.txt")),"unreviewed file deleted");Core.Restore(backup,xp,false);
        });
        test("lifecycle: install cannot expand approved cleanup scope",()=>{
            var plan=Core.Plan(xp,package,null);var reviewed=plan.Keys.Append(Core.Receipt).ToList();
            Data("StarLux_LMM_v1.1.8.lua","appeared after review");
            try {Core.Install(home,xp,package,null,_=>{},_=>{},false,reviewedPaths:reviewed);throw new Exception("expanded scope accepted");}catch(IOException){}
            Assert(File.Exists(Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.8.lua")),"unapproved cleanup occurred");
            File.Delete(Core.SafePath(xp,Core.Scripts+"/StarLux_LMM_v1.1.8.lua"));
        });
        test("lifecycle: retained data remains discoverable after normal uninstall",()=>{
            var backup=Core.Uninstall(home,xp,_=>{},_=>{},false);var d=Core.Diagnose(xp);
            Assert(!d.HasPlugin&&d.HasRelatedFiles&&Core.RemovalFiles(d,true,true).Count>0,"cannot clean remaining personal data");Core.Restore(backup,xp,false);
        });
        test("lifecycle: compact output suppresses verbose trace but retains actionable error",()=>{
            string Entry(string level,string text)=>"time #1 [PID 1/T1] [op] ["+level+"] "+text+"\n";
            var step=Entry("INFO","BEGIN: Copy | private/file.lua");Assert(LogPresentation.Render(step,false)==""&&LogPresentation.Render(step,true)==step,"verbosity selection failed");
            var err=Entry("STATUS","[TARGET_READ_ONLY] file.html\nClear Read-only");Assert(LogPresentation.Render(err,false).Contains("Clear Read-only"),"key cause hidden");
            Assert(LogPresentation.Render(Entry("PLAN","{very long details}"),false)=="","raw metadata visible in compact mode");
            Assert(LogPresentation.Render(Entry("INFO","Installation complete. Backup: backup/123"),false).Contains("Backup:"),"completion lost");
        });
    }
}
