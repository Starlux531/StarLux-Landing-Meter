using System.Text.RegularExpressions;

namespace StarLux.Installer;

public static class LogPresentation
{
    public static string Render(string entry, bool detailed)
    {
        if (detailed) return entry;
        var match = Regex.Match(entry, @"\] \[(?<level>[A-Z_]+)\] (?<text>[\s\S]*)$");
        if (!match.Success) return "";
        var level = match.Groups["level"].Value; var message = match.Groups["text"].Value.Trim();
        if (level == "STATUS") return message + Environment.NewLine;
        if (level == "WARNING") return U.T("提示：", "Notice: ") + message.Split('\n')[0] + Environment.NewLine;
        if (level != "INFO") return "";
        if (message.StartsWith("开始：") || message.StartsWith("完成：") || message.StartsWith("失败：") ||
            message.StartsWith("BEGIN:") || message.StartsWith("OK:") || message.StartsWith("FAILED:") ||
            message.StartsWith("安装前不存在：") || message.StartsWith("Not present before installation:")) return "";
        return message.Split('\n')[0] + Environment.NewLine;
    }
}
