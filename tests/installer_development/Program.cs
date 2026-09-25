using System.Text.Json;
using StarLux.Installer;

var root = Path.GetFullPath(args[0]);
var version = JsonDocument.Parse(File.ReadAllText(Path.Combine(root,"development.json"))).RootElement.GetProperty("version").GetString()!;
var bundle = Path.Combine(root,"dist",version,"StarLux_LMM_Installer_"+version);
void Check(bool value,string message) { if(!value) throw new Exception(message); }
if(args.Length==3 && args[1]=="--withdrawn-119-catalog-json") {
    using var network=new Network(Console.WriteLine,new CatalogSnapshotHandler(File.ReadAllText(args[2])));
    var catalog=Core.LabelReleases(await network.Catalog(default));
    var current=catalog.Where(r=>r.Version=="1.1.9").ToList();
    Check(current.Count==2 && current.All(r=>Core.Variant(r)=="sdk440"),"1.1.9 must offer only two Standard language assets");
    Check(current.All(r=>r.Sources.All(s=>s.Sha256.Length==64)),"missing asset digests");
    foreach(var language in new[]{"CN","EN"}) {
        var offline=Core.LocalReleases(Path.Combine(root,".tools/withdraw-119/offline-"+language),Console.WriteLine);
        Check(offline.Count==2 && offline.All(r=>r.Version=="1.1.9" && r.UiVariant=="sdk440"),"offline bundle still offers Compatibility");
        foreach(var item in offline) Core.Prepare(item.LocalDirectory,"1.1.9");
    }
    Console.WriteLine("Withdrawal verified with production installer: online 1.1.9 has two Standard variants; CN/EN offline packages contain two valid Standard payloads each.");
    return;
}
if(args.Length==3 && args[1]=="--catalog-json") {
    using var network=new Network(Console.WriteLine,new CatalogSnapshotHandler(File.ReadAllText(args[2])));
    var catalog=Core.LabelReleases(await network.Catalog(default));
    var current=catalog.Where(r=>r.Version==version).ToList();
    Check(current.Count==4 && current.All(r=>r.IsLatest),"published stable release not discovered as four Latest variants");
    if(version=="1.1.9rc2") {
        var installers=await network.InstallerCatalog(default);
        Check(installers.Available && installers.Releases.First().Version=="1.0.2","installer 1.0.2 self-update not discovered");
        Check(catalog.Where(r=>r.Version=="1.1.9").All(r=>Core.Variant(r)=="sdk440"),"withdrawn original Compatibility returned");
    }
    foreach(var item in current) {
        Check(item.Sources.All(s=>s.Sha256.Length==64),"missing server asset digest");
        Console.WriteLine(item);
    }
    Console.WriteLine("Published GitHub catalog passed production installer discovery and Latest labeling.");
    return;
}
Check(Core.CompareVersion("1.1.9-beta10","1.1.9-beta2")>0,"beta numeric order");
Check(Core.CompareVersion("1.1.9","1.1.9-beta99")>0,"final outranks beta");
Check(Core.CompareVersion("1.1.10-beta1","1.1.9")>0,"repair preview must outrank stable");
Check(Core.CompareVersion("1.1.10-beta2","1.1.10-beta1")>0,"second repair preview must outrank first");
Check(Core.CompareVersion("1.1.9rc2","1.1.9")>0,"project rc2 maintenance revision must outrank 1.1.9");
Check(Core.CompareVersion("1.1.9-rc2","1.1.9")<0,"normal prerelease ordering must remain intact");
Check(Core.CompareVersion("1.1.10-beta2","1.1.9rc2")>0,"explicit renumbering from beta2 requires manual selection");
Check(Core.CompareVersion(version,"1.1.8")>0,"new base outranks 1.1.8");
var releases=Core.LocalReleases(bundle,Console.WriteLine);
if(version=="1.1.9rc2" && File.Exists(Path.Combine(root,"dist/installer/1.0.2/StarLux_LMM_Installer_Update_v1.0.2.zip"))) {
    var updateFixture=Directory.CreateTempSubdirectory("LMM-rc2-installer-update-").FullName;
    System.IO.Compression.ZipFile.ExtractToDirectory(Path.Combine(root,"dist/installer/1.0.2/StarLux_LMM_Installer_Update_v1.0.2.zip"),updateFixture);
    SelfUpdater.ValidatePayload(updateFixture,"1.0.2");
}
Check(releases.Count==4&&releases.All(r=>r.Version==version),"local discovery did not retain subversion");
var compatibilityBundle=Path.Combine(root,"dist",version,"StarLux_LMM_Compatibility_Repair_"+version);
if(Directory.Exists(compatibilityBundle)) {
    var local=Core.LocalReleases(compatibilityBundle,Console.WriteLine);
    Check(local.Count==2&&local.All(r=>r.Version==version&&r.UiVariant=="legacy"),"repair bundle must discover exactly two compatible language variants");
}
foreach(var release in releases) {
    var prepared=Core.Prepare(release.LocalDirectory,version);
    Check(prepared.Manifest.Files.Count(f=>Core.MainLua(f.Path))==1,"duplicate main scripts");
    Check(prepared.Manifest.Files.Any(f=>f.Path=="StarLux_LMM_v"+version+".lua"),"filename lacks subversion");
}
var fixture=Directory.CreateTempSubdirectory("LMM-development-version-").FullName;
var xp=Path.Combine(fixture,"XP" );var home=Path.Combine(fixture,"installer");
void Write(string p,string text) { var f=Path.Combine(xp,p);Directory.CreateDirectory(Path.GetDirectoryName(f)!);File.WriteAllText(f,text); }
Write("X-Plane.exe","fixture");Write("Log.txt","log.txt for X-Plane 12.4.3-r1\n");
Write(Core.Fwl+"/win_x64/FlyWithLua.xpl","runtime");Write(Core.Fwl+"/Internals/FlyWithLua.ini","ini");
var previousMain = version=="1.1.9" ? "StarLux_LMM_v1.1.9-beta10.lua" : "StarLux_LMM_v1.1.9.lua";
Write(Core.Scripts+"/"+previousMain,"previous development");
if(version=="1.1.10-beta2") Write(Core.Scripts+"/StarLux_LMM_v1.1.10-beta1.lua","previous repair preview");
if(version=="1.1.9rc2") Write(Core.Scripts+"/StarLux_LMM_v1.1.10-beta2.lua","previous repair preview");
Write(Core.Scripts+"/LMM_Settings.cfg","user-settings");Write(Core.Scripts+"/LMM_Log/flight.txt","flight");
var selected=releases.Single(r=>r.UiVariant=="legacy"&&r.DefaultLanguage=="zh");
var package=Core.Prepare(selected.LocalDirectory,version);
Core.Install(home,xp,package,null,_=>{},_=>{},false);
Check(!File.Exists(Path.Combine(xp,Core.Scripts,previousMain)),"old main remains active");
if(version=="1.1.10-beta2") Check(!File.Exists(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.10-beta1.lua")),"beta1 main remains active");
if(version=="1.1.9rc2") Check(!File.Exists(Path.Combine(xp,Core.Scripts,"StarLux_LMM_v1.1.10-beta2.lua")),"beta2 main remains active");
var diagnosis=Core.Diagnose(xp);
Check(diagnosis.Version==version&&diagnosis.Verified,string.Join(";",diagnosis.Issues));
var missing=Path.Combine(xp,Core.Scripts,"LMM_UI_119/core_experience.lua");File.Delete(missing);
diagnosis=Core.Diagnose(xp);Check(!diagnosis.Verified,"missing overlay not diagnosed");
Check(Core.RepairRelease(releases,diagnosis)?.Version==version,"repair lost subversion");
Core.Install(home,xp,package,null,_=>{},_=>{},false);
Check(Core.Diagnose(xp).Verified&&File.Exists(missing),"repair did not restore overlay");
Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"LMM_Settings.cfg"))=="user-settings","settings changed");
Check(File.ReadAllText(Path.Combine(xp,Core.Scripts,"LMM_Log/flight.txt"))=="flight","flight record changed");
Console.WriteLine($"{version}: sorting, 4 variants, old-main replacement, receipt, diagnosis and repair passed. Fixture: {fixture}");
