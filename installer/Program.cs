using System.Text.Json;

namespace StarLux.Installer;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
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
        using var form = new MainForm();
        if (args.Length == 2 && args[0] == "--render")
        {
            form.Show(); Application.DoEvents(); using var bitmap = new Bitmap(form.Width, form.Height);
            form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(args[1]); return 0;
        }
        Application.Run(form); return 0;
    }
}
