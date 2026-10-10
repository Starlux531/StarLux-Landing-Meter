using System.Diagnostics;
using System.Reflection;
using System.Text.Json;

namespace StarLux.Installer;

// Off-screen UI checks: no downloads, simulator discovery, or real installation.
internal static class UiTests
{
    static IEnumerable<Control> Descendants(Control c) => c.Controls.Cast<Control>().SelectMany(x => new[] { x }.Concat(Descendants(x)));
    static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
    static void Invoke(object target, string name, params object[] args) => target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(target, args);
    static void Show(Form form) { form.ShowInTaskbar = false; form.StartPosition = FormStartPosition.Manual; form.Location = new(-30000,-30000); form.Show(); Application.DoEvents(); }
    internal static int Run(string path)
    {
        var results = new List<object>(); bool passed = true;
        void Test(string name, Action test) { try { test(); results.Add(new { name, passed = true }); } catch(Exception e) { passed = false; results.Add(new { name, passed = false, error = e.ToString() }); } }
        Test("card ignores clicks while inactive; labels and keyboard activate exactly once", () => {
            using var card = new StateCard(); int calls = 0; card.Activated += (_,_) => calls++;
            Invoke(card,"OnClick",EventArgs.Empty); Check(calls == 0,"inactive card clicked");
            card.SetAction(true); Invoke(card,"OnClick",EventArgs.Empty);
            Invoke(card.Controls[0],"OnClick",EventArgs.Empty);
            Invoke(card,"OnKeyDown",new KeyEventArgs(Keys.Enter)); Check(calls == 3,"activation count");
            card.SetAction(false); Invoke(card.Controls[1],"OnClick",EventArgs.Empty); Check(calls == 3 && !card.TabStop,"disabled card active");
        });
        Test("update card enabled only for a newer release while idle", () => {
            using var form = new MainForm(true); form.PreviewState(false);
            var card = Descendants(form).OfType<StateCard>().Last(); Check(!card.ActionEnabled && !card.Flash,"current version clickable");
            form.PreviewState(true); Check(card.ActionEnabled && card.Flash,"update missing");
            Invoke(form,"SetBusy",true); Check(!card.ActionEnabled,"busy update permitted");
            Invoke(form,"SetBusy",false); Check(card.ActionEnabled,"update not restored");
            Check(!Descendants(form).OfType<Button>().Any(b => b.Text is "更新安装器" or "Update installer"),"duplicate update entry");
        });
        foreach (var language in new[] { "zh", "en" }) Test(language + " review sorting, fold, full copy and destructive record visibility", () => {
            U.Language = language;
            var d = new Diagnosis { Files = [
                new() {Path="replace.lua",Exists=true,Bytes=1000}, new() {Path="old.lua",Exists=true,Bytes=20},
                new() {Path="settings.cfg",Category="settings",Exists=true,Bytes=300},
                new() {Path="preserved.txt",Category="reports",Exists=true,Bytes=9999},
                new() {Path="removed-report.txt",Category="reports",Exists=true,Bytes=77}] };
            using var form = new MaintenanceReview("D:/Fixture",d,"Review", plan:new() { ["replace.lua"]="payload",["old.lua"]="",["add.lua"]="payload",["settings.cfg"]="",["removed-report.txt"]="" });
            Show(form);
            var grid = Descendants(form).OfType<DataGridView>().Single();
            string[] Paths() => grid.Rows.Cast<DataGridViewRow>().Select(r => ((InstalledFile)r.Tag!).Path).ToArray();
            Check(Paths().SequenceEqual(new[] {"replace.lua","old.lua","removed-report.txt","add.lua","settings.cfg"}),"action priorities / changed report hidden");
            Check(form.FullListText().Contains("preserved.txt"),"collapsed record omitted from copy");
            var fold = Descendants(form).OfType<LinkLabel>().Single(); Invoke(fold,"OnLinkClicked",new LinkLabelLinkClickedEventArgs(fold.Links[0])); Check(Paths().Length==6,"fold failed to expand");
            void Sort(int column) => Invoke(grid,"OnColumnHeaderMouseClick",new DataGridViewCellMouseEventArgs(column,-1,1,1,new MouseEventArgs(MouseButtons.Left,1,1,1,0)));
            Sort(3); Check(Paths().SequenceEqual(new[] {"add.lua","old.lua","removed-report.txt","settings.cfg","replace.lua","preserved.txt"}),"byte sort is lexical");
            Sort(3); Check(Paths()[0]=="preserved.txt" && Paths()[^1]=="add.lua","descending size sort");
            Sort(2); Check(Paths().SequenceEqual(Paths().OrderBy(x=>x,StringComparer.OrdinalIgnoreCase)),"path sort");
            Invoke(fold,"OnLinkClicked",new LinkLabelLinkClickedEventArgs(fold.Links[0])); Check(Paths().Length==5 && Paths().Contains("removed-report.txt"),"collapse hid change");
            var buttons = Descendants(form).OfType<Button>().ToArray(); Check(buttons[0].DialogResult==DialogResult.OK && buttons[^1].DialogResult==DialogResult.Cancel,"confirmation order");
            Check(form.AcceptButton==null,"automatic destructive default introduced"); form.Close();
        });
        Test("uninstall record selection expands affected records without changing approval scope", () => {
            var d = new Diagnosis { Files=[new() {Path="record.txt",Category="reports",Exists=true},new() {Path="program.lua",Exists=true}] };
            using var form = new MaintenanceReview("D:/Fixture",d,"Uninstall",removal:true,complete:true); Show(form);
            var grid=Descendants(form).OfType<DataGridView>().Single(); Check(grid.Rows.Count==1 && form.SelectedFiles.Count==1,"kept report shown or selected");
            Descendants(form).OfType<CheckBox>().Single().Checked=true;
            Check(grid.Rows.Count==2 && form.SelectedFiles.Count==2,"removed report hidden"); form.Close();
        });
        Test("startup completes within two seconds and retains frosted main background", () => {
            using var form = new MainForm(true); Show(form);
            using var splash = new StartupScene(); var watch = Stopwatch.StartNew(); var task = splash.PlayAsync(form);
            Check(splash.Visible && splash.Width == form.ClientSize.Width && Descendants(form).OfType<FrostedBackground>().All(b=>!b.Visible),"startup not covering main controls");
            while(!task.IsCompleted && watch.ElapsedMilliseconds < 2200) { Application.DoEvents(); Thread.Sleep(2); }
            Check(task.IsCompleted && watch.ElapsedMilliseconds < 2000,"startup duration " + watch.ElapsedMilliseconds);
            Check(!form.Controls.Contains(splash) && Descendants(form).OfType<FrostedBackground>().Any(),"background lost after animation");
            form.Close();
        });
        File.WriteAllText(path,JsonSerializer.Serialize(new {passed,results},Core.Json)); return passed ? 0 : 1;
    }
}
