namespace StarLux.Installer;

public static class U
{
    public static string Language { get; set; } = System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh") ? "zh" : "en";
    public static string T(string zh, string en) => Language == "zh" ? zh : en;
    public static string Compatibility(Release r) => Core.Variant(r) switch
    {
        "sdk440" => T("标准版 · XP 12.4.4+", "Standard · XP 12.4.4+"),
        "legacy" => T("兼容版 · XP 12", "Compatibility · XP 12"),
        _ => T("历史版本", "Historical version")
    };
    public static string ReleaseName(Release r) => $"{(r.IsLatest ? T("[最新] ", "[Latest] ") : "")}{r.Version} · {Compatibility(r)} · " +
        (r.DefaultLanguage == "en" || r.Variant.Contains("International", StringComparison.OrdinalIgnoreCase) ? T("默认英文", "English default") : T("默认中文", "Chinese default")) +
        " · " + (r.LocalDirectory.Length > 0 ? T("本地", "Local") : string.Join(" + ", r.Sources.Select(s => s.Name).Distinct()));
}
