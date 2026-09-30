using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Encodings.Web;

namespace StarLux.Installer;

public sealed class DiagnosticFailure(string code, string message, string advice, string path = "", Exception? inner = null) : IOException(message, inner)
{
    public string Code { get; } = code;
    public string Advice { get; } = advice;
    public string FailurePath { get; } = path;
}

public sealed class DiagnosticSession : IDisposable
{
    readonly object gate = new();
    readonly string[] roots;
    readonly Queue<string> memory = new();
    readonly string id = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + "-" + Environment.ProcessId + "-" + Guid.NewGuid().ToString("N")[..6];
    int nextRoot;
    long sequence;
    public string DirectoryPath { get; private set; } = "";
    public string LogPath => DirectoryPath == "" ? "" : Path.Combine(DirectoryPath, "installer.log");
    public string StorageWarning { get; private set; } = "";
    public string SessionId => id;
    public event Action<string>? Line;
    public DiagnosticSession(params string[] roots) { this.roots = roots; Write("SESSION", "Diagnostic session started"); }
    public void Write(string level, string message)
    {
        lock (gate)
        {
            var line = $"{DateTimeOffset.Now:O} #{++sequence:D6} [PID {Environment.ProcessId}/T{Environment.CurrentManagedThreadId}] [{InstallerTrace.OperationId}] [{level}] {message}{Environment.NewLine}";
            memory.Enqueue(line); while(memory.Count>2000) memory.Dequeue();
            try { Line?.Invoke(line); } catch { /* A closing UI must not interrupt durable logging. */ }
            try
            {
                if (DirectoryPath == "") { OpenFallback(); return; }
                File.AppendAllText(LogPath, line, new UTF8Encoding(false));
            }
            catch(Exception e) { StorageWarning = e.Message; DirectoryPath = ""; OpenFallback(); }
        }
    }
    void OpenFallback()
    {
        while(nextRoot<roots.Length)
        {
            var root=roots[nextRoot++];
            try
            {
                Core.NoLinks(root);var dir=Path.Combine(root,id);Directory.CreateDirectory(dir);
                var path=Path.Combine(dir,"installer.log");
                File.WriteAllText(path,string.Concat(memory),new UTF8Encoding(false));
                DirectoryPath=dir;
                if(nextRoot>1) StorageWarning=U.T("默认日志目录不可写，已切换日志目录。","Default log location unavailable; using fallback.");
                return;
            }
            catch(Exception e) {StorageWarning=e.Message;}
        }
        StorageWarning=U.T("日志无法落盘，请导出诊断包或复制窗口日志。原因：","Log storage unavailable; export diagnostics or copy the window log. Reason: ")+StorageWarning;
    }
    public void Snapshot(string name, string file)
    {
        try
        {
            Core.NoLinks(file);
            if(!File.Exists(file)) { Write("SNAPSHOT", "Not present: "+file); return; }
            if(new FileInfo(file).Length>2*1024*1024) {Write("WARNING","Metadata exceeds 2 MiB; not copied: "+file);return;}
            var bytes=File.ReadAllBytes(file);
            lock(gate)
            {
                if(DirectoryPath=="") {Write("WARNING","Snapshot not saved; log storage unavailable: "+file);return;}
                var dest=Path.Combine(DirectoryPath,DateTime.Now.ToString("HHmmssfff")+"-"+(++sequence)+"-"+name);
                File.WriteAllBytes(dest,bytes);Write("SNAPSHOT",file+" -> "+dest);
            }
        }
        catch(Exception e) {Write("WARNING","Could not capture "+file+Environment.NewLine+e);}
    }
    public void Export(string destination)
    {
        lock(gate)
        {
            Core.NoLinks(destination);
            using var file=new FileStream(destination,FileMode.CreateNew,FileAccess.Write,FileShare.None);
            using var zip=new ZipArchive(file,ZipArchiveMode.Create);
            void Text(string name,string text) {using var writer=new StreamWriter(zip.CreateEntry(name).Open(),new UTF8Encoding(false));writer.Write(text);}
            Text("README.txt","StarLux installer diagnostic bundle\nIncludes current/recent installer sessions and installation metadata only.\nContains local paths/usernames. No flight TXT, configuration contents, executable backups or uploaded data.\nPrevious installer 1.0.2 did not persist logs; missing historic errors cannot be reconstructed.\n");
            if(DirectoryPath=="") {Text("current-memory.log",string.Concat(memory));return;}
            var root=Path.GetDirectoryName(DirectoryPath)!;
            var dirs=Directory.EnumerateDirectories(root).Where(p=>Path.GetFileName(p).Length>=20 && File.Exists(Path.Combine(p,"installer.log")))
                .OrderByDescending(p=>Path.GetFileName(p),StringComparer.Ordinal).Where(p=>p!=DirectoryPath).Take(4).Prepend(DirectoryPath);
            foreach(var dir in dirs)
            {
                try
                {
                    Core.NoLinks(dir);
                    foreach(var source in Directory.EnumerateFiles(dir).Where(p=>Path.GetFileName(p)=="installer.log" || Path.GetExtension(p)==".json"))
                    {
                        Core.NoLinks(source);
                        using var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.ReadWrite);
                        using var output=zip.CreateEntry(Path.GetFileName(dir)+"/"+Path.GetFileName(source)).Open();
                        input.CopyTo(output);
                    }
                }
                catch(Exception e) {Text(Path.GetFileName(dir)+"/capture-error.txt",e.ToString());}
            }
        }
    }
    public void Dispose() => Write("SESSION","Session ended");
}

public static class InstallerTrace
{
    static readonly AsyncLocal<string?> operation = new();
    static readonly JsonSerializerOptions json = new() { Encoder=JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    public static DiagnosticSession? Session {get;set;}
    public static string OperationId => operation.Value ?? "session";
    public static string LogPath => Session?.LogPath ?? "";
    public static void Initialize()
    {
        Session=new DiagnosticSession(Path.Combine(AppContext.BaseDirectory,"logs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"StarLux_LMM_Installer","logs"),
            Path.Combine(Path.GetTempPath(),"StarLux_LMM_Installer","logs"));
        Event("ENVIRONMENT",new {version=SelfUpdater.Version,exe=Environment.ProcessPath,baseDir=AppContext.BaseDirectory,
            os=Environment.OSVersion.ToString(),architecture=System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            runtime=Environment.Version.ToString(),language=U.Language});
    }
    public static void Write(string message) => Session?.Write("INFO",message);
    public static void Status(string message) => Session?.Write("STATUS", message);
    public static void Event(string name,object? details=null) => Session?.Write(name,details==null?"":JsonSerializer.Serialize(details,json));
    public static IDisposable Begin(string name,object? details=null)
    {
        var previous=operation.Value;operation.Value=name+"-"+Guid.NewGuid().ToString("N")[..8];
        Event("ACTION_BEGIN",new {name,details});return new Scope(previous);
    }
    sealed class Scope(string? previous) : IDisposable
    {
        public void Dispose(){Event("ACTION_END");operation.Value=previous;}
    }
    public static string Fault(string context,Exception e)
    {
        Status(context + Environment.NewLine + Describe(e));
        Session?.Write("ERROR",context+Environment.NewLine+Describe(e)+Environment.NewLine+e);
        return Describe(e)+Environment.NewLine+Environment.NewLine+U.T("诊断日志：","Diagnostic log: ")+(LogPath==""?U.T("未能保存，请导出诊断包。","Unavailable; export diagnostics."):LogPath);
    }
    public static string Describe(Exception e)
    {
        var failure=Walk(e).OfType<DiagnosticFailure>().FirstOrDefault();
        var underlying=Walk(e).FirstOrDefault(x=>x is UnauthorizedAccessException or FileNotFoundException or DirectoryNotFoundException or PathTooLongException)
            ?? Walk(e).FirstOrDefault(x=>x is IOException && (x.HResult&0xffff) is 32 or 33 or 112 or 39) ?? e;
        var code=failure?.Code ?? (underlying switch {
            UnauthorizedAccessException=>"ACCESS_DENIED",FileNotFoundException or DirectoryNotFoundException=>"PATH_MISSING",
            PathTooLongException=>"PATH_TOO_LONG",JsonException=>"INVALID_JSON",
            _ when (underlying.HResult&0xffff) is 32 or 33=>"FILE_IN_USE",
            _ when (underlying.HResult&0xffff) is 112 or 39=>"DISK_FULL",
            OperationCanceledException=>"CANCELLED",_=>"OPERATION_FAILED"});
        var advice=failure?.Advice ?? code switch {
            "ACCESS_DENIED"=>U.T("检查所列路径的写入权限和安全软件拦截记录。不能仅凭此错误认定为杀毒软件问题。","Check permissions for the listed path and security-software history; this error alone does not prove antivirus interference."),
            "PATH_MISSING"=>U.T("检查文件是否被移动、删除或未完整解压。恢复操作需要原备份及 files 子目录。","Check whether files were moved, removed or incompletely extracted. Recovery needs the original backup and its files directory."),
            "PATH_TOO_LONG"=>U.T("将安装器完整解压到较短路径，保留原备份位置后再操作。","Extract the complete installer to a shorter path; preserve the original backup location."),
            "FILE_IN_USE"=>U.T("退出 X-Plane 和其他安装器；确认没有程序占用该文件后重试。","Close X-Plane and other installers; retry when the file is no longer in use."),
            "DISK_FULL"=>U.T("检查目标、备份及临时目录所在磁盘的剩余空间，保留现有备份。","Check free space on target, backup and temporary drives; retain existing backups."),
            "INVALID_JSON"=>U.T("清单或事务记录无法解析。请保留原文件并导出诊断包，不要手工删除安装标记。","A manifest or transaction cannot be parsed. Keep the original and export diagnostics; do not delete installation markers."),
            _=>U.T("请导出诊断包，结合首次错误排查；当前证据不足以确定更具体原因。","Export diagnostics for investigation of the first failure; the available evidence does not establish a more specific cause.")};
        var step=Walk(e).Select(x=>x.Data["LMM.Step"] as string).FirstOrDefault(x=>x!=null) ?? U.T("见完整日志","See full log");
        var path=failure?.FailurePath;
        if(string.IsNullOrEmpty(path)) path=Walk(e).OfType<FileNotFoundException>().Select(x=>x.FileName).FirstOrDefault(x=>!string.IsNullOrEmpty(x))
            ?? Walk(e).Select(x=>x.Data["LMM.Path"] as string).FirstOrDefault(x=>x!=null) ?? "";
        return $"[{code}] {e.Message}\n"+U.T("步骤：","Step: ")+step+"\n"+U.T("路径：","Path: ")+path+
            $"\n{underlying.GetType().FullName} · HRESULT 0x{underlying.HResult:X8}\n"+advice;
    }
    static IEnumerable<Exception> Walk(Exception e)
    {
        yield return e;
        if(e is AggregateException a) {foreach(var inner in a.InnerExceptions) foreach(var child in Walk(inner)) yield return child;}
        else if(e.InnerException!=null) foreach(var child in Walk(e.InnerException)) yield return child;
    }
    public static T Step<T>(string name,string path,Func<T> action,Action<string>? log=null)
    {
        void Emit(string s){if(log!=null)log(s);else Write(s);}
        Emit(U.T("开始：","BEGIN: ")+name+" | "+path);var clock=Stopwatch.StartNew();
        try {var value=action();Emit(U.T("完成：","OK: ")+name+$" ({clock.ElapsedMilliseconds} ms) | "+path);return value;}
        catch(Exception e) {if(!e.Data.Contains("LMM.Step"))e.Data["LMM.Step"]=name;if(!e.Data.Contains("LMM.Path"))e.Data["LMM.Path"]=path;Fault(name,e);Emit(U.T("失败：","FAILED: ")+name+" | "+path+" | "+e.Message);throw;}
    }
    public static void Step(string name,string path,Action action,Action<string>? log=null) => Step(name,path,()=>{action();return true;},log);
    public static void CaptureTarget(string target)
    {
        if(!Core.IsXPlane(target))return;
        try
        {
            var marker=Core.SafePath(target,"Resources/plugins/StarLux_LMM.install.pending.json");
            Session?.Snapshot("pending.json",marker);Session?.Snapshot("receipt.json",Core.SafePath(target,Core.Receipt));
            if(File.Exists(marker) && new FileInfo(marker).Length<=2*1024*1024)
            {
                using var doc=JsonDocument.Parse(File.ReadAllText(marker));
                if(doc.RootElement.TryGetProperty("backup",out var b) && b.ValueKind==JsonValueKind.String && !string.IsNullOrWhiteSpace(b.GetString()))
                {
                    var backup=b.GetString()!;Event("RECOVERY_LOCATION",new {backup,exists=Directory.Exists(backup)});
                    Session?.Snapshot("transaction.json",Path.Combine(backup,"transaction.json"));
                }
            }
        }
        catch(Exception e){Fault("Capture installation metadata",e);}
    }
}
