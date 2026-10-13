using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StarLux.Installer;

public sealed class PendingRecovery
{
    public string Backup { get; set; } = "";
    public string TransactionId { get; set; } = "";
    public string OriginalStateHash { get; set; } = "";
}

public static partial class Core
{
    static void WriteTextAtomic(string path,string text)
    {
        var temp=path+"."+Guid.NewGuid().ToString("N")+".tmp"; NoLinks(path);
        try { File.WriteAllText(temp,text); File.Move(temp,path,true); }
        finally { if(File.Exists(temp))File.Delete(temp); }
    }
    static PendingRecovery ReadPending(string target)
    {
        var marker=SafePath(target,Pending);
        try
        {
            var pending=JsonSerializer.Deserialize<PendingRecovery>(File.ReadAllText(marker),Json);
            if(pending==null || !Path.IsPathFullyQualified(pending.Backup))throw new JsonException("Missing absolute backup path");
            return pending;
        }
        catch(Exception e) { throw new DiagnosticFailure("PENDING_INVALID",U.T("未完成事务标记无法解析。", "Cannot parse the pending transaction marker."),U.T("保留标记并导出诊断包；不要手工删除标记。", "Keep the marker and export diagnostics; do not delete it manually."),marker,e); }
    }
    static string StateHash(Journal journal) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(
        new { target=NormalizeDirectory(journal.Target).ToUpperInvariant(), entries=journal.Entries.OrderBy(e=>e.Path,StringComparer.OrdinalIgnoreCase).ToArray() },Json)))).ToLowerInvariant();

    static bool MatchesPending(PendingRecovery pending,string backup,Journal journal)
    {
        if(pending.TransactionId!="") return journal.Id==pending.TransactionId && pending.OriginalStateHash!="" && StateHash(journal)==pending.OriginalStateHash;
        if(NormalizeDirectory(pending.Backup).Equals(NormalizeDirectory(backup),StringComparison.OrdinalIgnoreCase))return true;
        // Legacy records lack IDs: require the exact generated transaction directory name.
        // Restore also validates the target, every entry and every original file hash.
        var original=Path.GetFileName(NormalizeDirectory(pending.Backup));
        if(!Regex.IsMatch(original,@"^\d{8}-\d{6}-[a-fA-F0-9]{8}$") || !original.Equals(Path.GetFileName(NormalizeDirectory(backup)),StringComparison.OrdinalIgnoreCase))return false;
        // If the old copy still exists, compare immutable original state as additional evidence.
        var old=Path.Combine(pending.Backup,"transaction.json");
        if(File.Exists(old)) { NoLinks(old); var saved=JsonSerializer.Deserialize<Journal>(File.ReadAllText(old),Json); return saved!=null && StateHash(saved)==StateHash(journal); }
        return true;
    }
    static Journal ReadJournal(string backup,string target)
    {
        NoLinks(backup); var file=Path.Combine(backup,"transaction.json");
        var j=JsonSerializer.Deserialize<Journal>(File.ReadAllText(file),Json) ?? throw new IOException("Invalid transaction");
        if(!NormalizeDirectory(j.Target).Equals(NormalizeDirectory(target),StringComparison.OrdinalIgnoreCase))throw new DiagnosticFailure("BACKUP_TARGET_MISMATCH",U.T("备份属于其他模拟器目录。", "Backup belongs to another simulator folder."),U.T("选择当前 X-Plane 对应的备份。若移动了模拟器，请提供旧、新路径及诊断包，不会向旧路径写入。", "Select the backup for this simulator. If X-Plane was moved, provide both paths and diagnostics; the old path will not be modified."),file);
        if(j.Entries==null || j.Entries.Count==0 || j.Entries.Count>20000)throw new IOException("Invalid transaction entry count");
        var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var e in j.Entries)
        {
            var rel=e.Path.Replace('\\','/'); SafePath(target,rel);
            if(!seen.Add(rel) || !(rel.StartsWith(Fwl+"/",StringComparison.OrdinalIgnoreCase)||rel.StartsWith("Resources/plugins/StarLux_LMM/",StringComparison.OrdinalIgnoreCase)||rel==Receipt))throw new IOException("Invalid transaction path: "+rel);
        }
        return j;
    }
    public static string FindPendingBackup(string target,params string[] installerDirectories)
    {
        if(!File.Exists(SafePath(target,Pending)))return "";
        var p=ReadPending(target); var candidates=new List<string>{p.Backup};
        foreach(var home in installerDirectories)
        {
            var root=Path.Combine(home,"backup"); NoLinks(root);
            if(!Directory.Exists(root))continue;
            var direct=Path.Combine(root,Path.GetFileName(NormalizeDirectory(p.Backup)));candidates.Add(direct);
            if(p.TransactionId!="")candidates.AddRange(Directory.EnumerateDirectories(root).Take(2000));
        }
        foreach(var path in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try { if(File.Exists(Path.Combine(path,"transaction.json"))) { var j=ReadJournal(path,target); if(MatchesPending(p,path,j))return path; } }
            catch(Exception e) when(e is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { InstallerTrace.Event("RECOVERY_CANDIDATE_REJECTED",new {path,error=e.Message}); }
        }
        return "";
    }
    static bool FilesMatch(string target,IEnumerable<JournalEntry> entries)
    {
        foreach(var e in entries)
        {
            var file=SafePath(target,e.Path);
            if(Directory.Exists(file))return false;
            if(e.Existed ? !File.Exists(file)||e.Sha256.Length!=64||Hash(file)!=e.Sha256 : File.Exists(file))return false;
        }
        return true;
    }
    // Finalization is separate from recovery: never undo a completed install merely to remove a stale marker.
    public static bool FinalizePending(string target,string installerDirectory,Action<string>? log=null)
    {
        using var lease=new TargetLease(target);
        var marker=SafePath(target,Pending); if(!File.Exists(marker))return true;
        var markerHash=Hash(marker); var backup=FindPendingBackup(target,installerDirectory);if(backup=="")return false;
        var j=ReadJournal(backup,target); IEnumerable<JournalEntry>? state=null;
        if(j.Status=="restored" && string.IsNullOrEmpty(j.PreviousPending))state=j.Entries;
        if(j.Status=="completed" && j.ResultFiles is {Count:>0} && j.ResultFiles.Select(e=>e.Path).ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(j.Entries.Select(e=>e.Path)))state=j.ResultFiles;
        if(state==null || !FilesMatch(target,state))return false;
        if(Hash(marker)!=markerHash)throw new IOException("Pending transaction changed during verification");
        File.Copy(marker,Path.Combine(backup,"finalized-pending.json"),true); File.Delete(marker);
        (log ?? InstallerTrace.Status)(U.T("已核实上次操作完成，仅清除了遗留事务标记，未回退插件。", "Verified the previous operation completed. Cleared only its stale marker; plugin files were not reverted."));return true;
    }
    static void ValidateRebuild(string target,string expectedMarkerHash)
    {
        var marker=SafePath(target,Pending);
        if(expectedMarkerHash=="" || !File.Exists(marker) || Hash(marker)!=expectedMarkerHash)throw new IOException(U.T("未完成事务已变化，请重新确认。", "Pending transaction changed. Review recovery again."));
    }
}
