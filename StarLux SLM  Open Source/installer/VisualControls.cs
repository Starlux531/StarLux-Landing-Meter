using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace StarLux.Installer;

// Border-only emphasis keeps action text readable throughout the animation.
internal sealed class AccentButton : Button
{
    readonly System.Windows.Forms.Timer animation = new() { Interval = 40 };
    readonly Stopwatch clock = new();
    readonly Color accent;
    readonly bool pulse;
    public AccentButton(string text, DialogResult result, Color accent, bool pulse = false)
    {
        this.accent = accent; this.pulse = pulse;
        Text = text; DialogResult = result; AutoSize = true; MinimumSize = new(116, 40);
        Padding = new(12, 5, 12, 5); Margin = new(0, 0, 8, 0);
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        BackColor = Color.FromArgb(28, 66, 104); ForeColor = Color.FromArgb(238, 247, 255);
        FlatAppearance.MouseOverBackColor = Color.FromArgb(42, 89, 128);
        Cursor = Cursors.Hand; DoubleBuffered = true;
        animation.Tick += (_, _) => Invalidate();
    }
    void RefreshAnimation()
    {
        if (pulse && Visible && Enabled && IsHandleCreated) { clock.Start(); animation.Start(); }
        else animation.Stop();
    }
    protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); RefreshAnimation(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); RefreshAnimation(); }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); RefreshAnimation(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Width < 4 || Height < 4) return;
        var strength = pulse ? 0.62 + 0.38 * (Math.Sin(clock.Elapsed.TotalSeconds * Math.PI * 1.5) + 1) / 2 : 1;
        Color Shade(double factor) => Color.FromArgb((int)(accent.R * factor), (int)(accent.G * factor), (int)(accent.B * factor));
        var rect = new Rectangle(1, 1, Width - 3, Height - 3);
        using var brush = new LinearGradientBrush(rect, Shade(strength), Shade(pulse ? 0.5 + (1 - strength) : strength), 25f);
        using var pen = new Pen(brush, Math.Max(2, DeviceDpi / 48f));
        e.Graphics.DrawRectangle(pen, rect);
    }
    protected override void Dispose(bool disposing) { if (disposing) animation.Dispose(); base.Dispose(disposing); }
}

internal sealed class FrostedBackground : BluePanel
{
    readonly Bitmap photo;
    Bitmap? surface;
    internal static Bitmap LoadPhoto()
    {
        using var stream = typeof(StartupScene).Assembly.GetManifestResourceStream("StarLux.Startup.jpg")
            ?? throw new IOException("Missing embedded startup image");
        using var source = Image.FromStream(stream);
        return new Bitmap(source);
    }
    internal FrostedBackground()
    {
        using var source = LoadPhoto();
        // The low-resolution cache softens detail once, without a per-frame blur.
        photo = new Bitmap(200, Math.Max(1, source.Height * 200 / source.Width));
        using var g = Graphics.FromImage(photo);
        g.InterpolationMode = InterpolationMode.HighQualityBilinear;
        g.DrawImage(source, 0, 0, photo.Width, photo.Height);
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (Width < 1 || Height < 1) return;
        if (surface?.Size != ClientSize)
        {
            surface?.Dispose(); surface = new Bitmap(Width, Height);
            using var g = Graphics.FromImage(surface);
            var scale = Math.Max((float)Width / photo.Width, (float)Height / photo.Height);
            var w = (int)(photo.Width * scale); var h = (int)(photo.Height * scale);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(photo, (Width - w) / 2, (Height - h) / 2, w, h);
            using var tint = new LinearGradientBrush(ClientRectangle, Color.FromArgb(204, 8, 22, 42), Color.FromArgb(185, 24, 59, 91), 30f);
            g.FillRectangle(tint, ClientRectangle);
        }
        e.Graphics.DrawImageUnscaled(surface, 0, 0);
    }
    protected override void Dispose(bool disposing) { if (disposing) { photo.Dispose(); surface?.Dispose(); } base.Dispose(disposing); }
}

internal sealed class StartupScene : Control
{
    internal const int DurationMs = 1500;
    readonly Bitmap photo;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 30 };
    readonly Stopwatch clock = new();
    TaskCompletionSource? completion;
    Control[] covered = [];
    double? previewTime;
    internal StartupScene()
    {
        Dock = DockStyle.Fill; DoubleBuffered = true; TabStop = false; BackColor = Color.FromArgb(8, 22, 42);
        photo = FrostedBackground.LoadPhoto();
        timer.Tick += (_, _) => { if (clock.ElapsedMilliseconds >= DurationMs) Finish(); else Invalidate(); };
    }
    internal Task PlayAsync(Control owner)
    {
        completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        clock.Start();
        covered = owner.Controls.Cast<Control>().Where(c => c.Visible).ToArray();
        foreach (var control in covered) control.Visible = false;
        owner.Controls.Add(this); BringToFront(); timer.Start();
        return completion.Task;
    }
    internal void Preview(double milliseconds) { previewTime = milliseconds; Invalidate(); }
    void Finish()
    {
        timer.Stop(); Visible = false; Parent?.Controls.Remove(this);
        foreach (var control in covered) if (!control.IsDisposed) control.Visible = true;
        covered = []; completion?.TrySetResult();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var elapsed = previewTime ?? clock.Elapsed.TotalMilliseconds;
        var opacity = (float)Math.Clamp(Math.Min(elapsed / 220, (DurationMs - elapsed) / 260), 0, 1);
        var g = e.Graphics;
        var scale = Math.Min((float)Width / photo.Width, (float)Height / photo.Height);
        var w = (int)(photo.Width * scale); var h = (int)(photo.Height * scale);
        using var attrs = new ImageAttributes(); attrs.SetColorMatrix(new ColorMatrix { Matrix33 = opacity });
        g.DrawImage(photo, new Rectangle((Width - w) / 2, (Height - h) / 2, w, h), 0, 0, photo.Width, photo.Height, GraphicsUnit.Pixel, attrs);
        using var tint = new SolidBrush(Color.FromArgb(35, 8, 22, 42)); g.FillRectangle(tint, ClientRectangle);
        using var font = new Font("Segoe UI", 36, FontStyle.Bold);
        using var ink = new SolidBrush(Color.FromArgb((int)(255 * opacity), 233, 249, 255));
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.DrawString("starlux slm", font, ink, new RectangleF(0, Height / 2f - 64, Width, 96), format);
        var lineWidth = Math.Min(240, Width / 3); var left = (Width - lineWidth) / 2;
        using var track = new SolidBrush(Color.FromArgb((int)(65 * opacity), 150, 225, 238));
        using var light = new SolidBrush(Color.FromArgb((int)(240 * opacity), 108, 232, 208));
        g.FillRectangle(track, left, Height / 2 + 46, lineWidth, 3);
        g.FillRectangle(light, left, Height / 2 + 46, (float)(lineWidth * Math.Clamp(elapsed / DurationMs, 0, 1)), 3);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Dispose(); photo.Dispose(); completion?.TrySetResult(); }
        base.Dispose(disposing);
    }
}
