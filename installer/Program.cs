using System.Text.Json;

namespace StarLux.Installer;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        InstallerTrace.Initialize();
        using var session=InstallerTrace.Session;
        AppDomain.CurrentDomain.UnhandledException += (_,e) => { if(e.ExceptionObject is Exception error) InstallerTrace.Fault("Unhandled process exception",error); };
        TaskScheduler.UnobservedTaskException += (_,e) => InstallerTrace.Fault("Unobserved background task exception",e.Exception);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_,e) => {
            var detail=InstallerTrace.Fault("Unhandled UI exception",e.Exception);
            MessageBox.Show(detail,U.T("安装器发生异常，请保留诊断日志","Installer error: retain diagnostic logs"));
            Application.Exit();
        };
        try {return Run(args);}
        catch(Exception e)
        {
            var detail=InstallerTrace.Fault("Startup / command failure",e);
            if(args.Length==0) MessageBox.Show(detail,U.T("安装器启动失败","Installer startup failed"));
            return 1;
        }
    }
    static int Run(string[] args)
    {
        if (args.Length == 2 && args[0] == "--apply-self-update") return SelfUpdater.Apply(args[1]);
        if (args.Contains("--self-test")) return SelfTests.Run(args);
        if (args.Contains("--inspect"))
        {
            var i = Array.IndexOf(args, "--inspect");
            if (i + 2 >= args.Length) return 2;
            File.WriteAllText(args[i + 2], JsonSerializer.Serialize(Core.Inspect(args[i + 1]), Core.Json)); return 0;
        }
        if (args.Length == 2 && args[0] == "--detect")
        {
            File.WriteAllText(args[1], JsonSerializer.Serialize(Core.Discover(AppContext.BaseDirectory), Core.Json)); return 0;
        }
        ApplicationConfiguration.Initialize();
        var language = Array.IndexOf(args, "--language");
        if (language >= 0 && language + 1 < args.Length && args[language + 1] is "zh" or "en") U.Language = args[language + 1];
        var rendering = args.Length >= 2 && args[0] == "--render";
        var probe = args.Contains("--update-probe") || args.Contains("--update-probe-fail");
        using var form = new MainForm(rendering || probe);
        if (rendering)
        {
            if(args.Contains("--preview-files") || args.Contains("--preview-uninstall") || args.Contains("--preview-install"))
            {
                var d = new Diagnosis { ValidTarget=true,HasPlugin=true,Version="1.1.9rc2",SimulatorVersion="12.4.3",
                    Issues=[U.T("文件内容与安装清单不同：LMM_Report_Reader.html", "File contents differ from receipt: LMM_Report_Reader.html"),U.T("缺失：LMM_UI_119/core.lua", "Missing: LMM_UI_119/core.lua")] };
                d.Files=[new() {Path=Core.Scripts+"/LMM_Report_Reader.html",Exists=true,Bytes=854123,Status=U.T("内容与安装清单不一致", "Contents differ from receipt"),Expected=new string('a',64),Actual=new string('b',64)},
                    new() {Path=Core.Scripts+"/LMM_UI_119/core.lua",Status=U.T("缺失", "Missing"),Expected=new string('c',64)},
                    new() {Path=Core.Scripts+"/LMM_Settings.cfg",Category="settings",Exists=true,Bytes=1800},
                    new() {Path=Core.Scripts+"/LMM_Apt_Index_v1.cache",Category="cache",Exists=true,Bytes=58210},
                    new() {Path=Core.Scripts+"/LMM_Log/LMM_ZJSY_B737_RWY26_2026-09-29_11-32-41_CN.txt",Category="reports",Exists=true,Bytes=3891240},
                    new() {Path=Core.Scripts+"/LMM_Log/personal-note.txt",Category="unknown",Exists=true,Removable=false,Bytes=302}];
                var uninstall=args.Contains("--preview-uninstall");var installing=args.Contains("--preview-install");
                using var review = new MaintenanceReview(@"D:\Games\X-Plane 12", d, U.T("安装详情与维护预览", "Installation and maintenance preview"), uninstall,uninstall,
                    installing?new() {{Core.Scripts+"/LMM_Report_Reader.html","payload"},{Core.Scripts+"/LMM_UI_119/core.lua","payload"}}:null,
                    uninstall?U.T("完全卸载：程序、设置、缓存将备份后移除。飞行记录仅在勾选后删除。FlyWithLua、未知文件、浏览器偏好与安装器备份保留。", "Full uninstall: back up and remove programs, settings and caches. Flight records require explicit selection. FlyWithLua, unknown files, browser preferences and installer backups remain."):"");
                review.StartPosition=FormStartPosition.Manual;review.Location=new(-30000,-30000);review.Show();Application.DoEvents();
                using var shot=new Bitmap(review.Width,review.Height);review.DrawToBitmap(shot,new Rectangle(Point.Empty,shot.Size));shot.Save(args[1]);return 0;
            }
            if (args.Contains("--preview-updates") || args.Contains("--preview-current")) form.PreviewState(args.Contains("--preview-updates"));
            form.StartPosition = FormStartPosition.Manual; form.Location = new(-30000, -30000); form.ShowInTaskbar = false;
            form.Show(); Application.DoEvents(); using var bitmap = new Bitmap(form.Width, form.Height);
            form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(args[1]); return 0;
        }
        if (args.Length >= 2 && args[0] == "--update-health")
        {
            var ready = Path.GetFullPath(args[1]);
            if (Path.GetFileName(ready) != "ready.json" || !Path.GetFileName(Path.GetDirectoryName(ready)!).StartsWith("StarLux-installer-update-")) return 2;
            Core.NoLinks(ready);
            if (probe)
            {
                if (args.Contains("--update-probe-fail")) return 1;
                form.CreateControl(); File.WriteAllText(ready, JsonSerializer.Serialize(new { version = SelfUpdater.Version, pid = Environment.ProcessId })); return 0;
            }
            form.Shown += (_, _) => File.WriteAllText(ready, JsonSerializer.Serialize(new { version = SelfUpdater.Version, pid = Environment.ProcessId }));
        }
        if (args.Length == 2 && args[0] == "--update-result") form.ShowUpdateResult(args[1]);
        Application.Run(form); return 0;
    }
}
