using System.Text.Json;

namespace StarLux.Installer;

static class Program
{
    [STAThread]
    static int Main(string[] args)
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
