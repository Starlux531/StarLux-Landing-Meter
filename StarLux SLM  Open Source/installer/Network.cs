using System.Net.Http;
using System.Text.Json;

namespace StarLux.Installer;

public sealed partial class Network : IDisposable
{
    public const string GithubRepo = "https://github.com/Starlux531/StarLux-Landing-Meter";
    public const string GiteeRepo = "https://gitee.com/starlux531/starluxlmm";
    public const string FwlPage = "https://forums.x-plane.org/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/";
    public const string FwlCommit = "453f6a22de4fde15a9c960588690f4780d7d7bf0";
    // Fixed official commit, not the outdated GitHub 'latest' release (XP11).
    public static readonly DownloadSource OfficialFwl = new("GitHub", "https://codeload.github.com/X-Friese/FlyWithLua/zip/" + FwlCommit, "c6e1a4517328c4df20887bba4b6bb40a375344ec5230a39cfd35a99c9708819f");
    readonly HttpClient client;
    readonly Action<string> log;
    public bool PluginCatalogAvailable { get; private set; }
    public Network(Action<string> log, HttpMessageHandler? handler = null)
    {
        this.log = log;
        client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false });
        client.Timeout = Timeout.InfiniteTimeSpan;
        client.DefaultRequestHeaders.UserAgent.ParseAdd("StarLux-LMM-Installer/" + SelfUpdater.Version);
    }
    public void Dispose() => client.Dispose();
    public static bool TrustedInitial(Uri u)
    {
        if (u.Scheme != "https" || !u.IsDefaultPort || u.UserInfo != "") return false;
        var text = u.AbsoluteUri;
        return new[] {
            GithubRepo + "/", GiteeRepo + "/",
            "https://api.github.com/repos/Starlux531/StarLux-Landing-Meter/",
            "https://gitee.com/api/v5/repos/starlux531/starluxlmm/",
            "https://codeload.github.com/X-Friese/FlyWithLua/zip/",
            "https://github.com/X-Friese/FlyWithLua/releases/"
        }.Any(p => text.StartsWith(p, StringComparison.OrdinalIgnoreCase));
    }
    static bool TrustedRedirect(Uri u) => TrustedInitial(u) || (u.Scheme == "https" && u.IsDefaultPort && u.UserInfo == "" &&
        new[] { "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com", "gitee.com", "giteeusercontent.com", "gitee.cn" }.Any(h => u.Host == h || u.Host.EndsWith("." + h, StringComparison.OrdinalIgnoreCase)));
    async Task<HttpResponseMessage> Open(string url, CancellationToken token)
    {
        var uri = new Uri(url);
        if (!TrustedInitial(uri)) throw new IOException(U.T("不可信下载地址","Untrusted download URL: ") + url);
        for (int i = 0; i < 6; i++)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(25));
            var endpoint=uri.GetLeftPart(UriPartial.Path);InstallerTrace.Event("HTTP_REQUEST",new {endpoint,redirect=i});
            var elapsed=System.Diagnostics.Stopwatch.StartNew();HttpResponseMessage response;
            try {response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, timeout.Token);}
            catch(OperationCanceledException e) when(!token.IsCancellationRequested)
            {throw new DiagnosticFailure("NETWORK_TIMEOUT",U.T("连接请求超时：","Connection request timed out: ")+endpoint,U.T("检查网络连接；可切换下载源或使用完整本地安装包。","Check connectivity; use another source or a complete local bundle."),endpoint,e);}
            catch(HttpRequestException e)
            {throw new DiagnosticFailure("NETWORK_CONNECTION",U.T("网络请求失败：","Network request failed: ")+e.Message,U.T("检查网络、代理或 TLS 错误；可使用其他源或本地包。","Check connectivity, proxy or TLS errors; another source or a local bundle may work."),endpoint,e);}
            InstallerTrace.Event("HTTP_RESPONSE",new {endpoint,status=(int)response.StatusCode,milliseconds=elapsed.ElapsedMilliseconds});
            if ((int)response.StatusCode is >= 300 and < 400)
            {
                var location = response.Headers.Location; response.Dispose();
                if (location == null) throw new IOException(U.T("缺少重定向地址","Missing redirect"));
                uri = location.IsAbsoluteUri ? location : new Uri(uri, location);
                if (!TrustedRedirect(uri)) throw new IOException(U.T("下载重定向到未信任站点","Untrusted redirect: ") + uri.Host);
                continue;
            }
            if (!response.IsSuccessStatusCode) { var status = (int)response.StatusCode; response.Dispose(); throw new DiagnosticFailure("HTTP_"+status,"HTTP " + status+" | "+endpoint,
                U.T("该下载源返回错误；这本身不代表插件文件损坏。可等待重试、切换来源或使用本地包。","This source returned an error; it does not itself indicate damaged plugin files. Retry later, change source or use a local bundle."),endpoint); }
            return response;
        }
        throw new IOException(U.T("过多下载重定向","Too many redirects"));
    }
    public async Task<List<Release>> Catalog(CancellationToken token)
    {
        PluginCatalogAvailable = false;
        async Task<List<Release>> Source(string name, string url)
        {
            var list = new List<Release>();
            try
            {
                // Bounded pagination rather than assuming API order (Gitee is not newest-first).
                for (int page = 1; page <= 5; page++)
                {
                    using var limit = CancellationTokenSource.CreateLinkedTokenSource(token); limit.CancelAfter(TimeSpan.FromSeconds(25));
                    using var response = await Open(url + $"?per_page=100&page={page}", limit.Token);
                    using var bytes = new MemoryStream();
                    using var stream = await response.Content.ReadAsStreamAsync(limit.Token);
                    await CopyBounded(stream, bytes, 8 * 1024 * 1024, limit.Token, null, null);
                    using var doc = JsonDocument.Parse(bytes.ToArray());
                    if (doc.RootElement.ValueKind != JsonValueKind.Array) throw new IOException(U.T("发布列表格式无效","Invalid release list"));
                    foreach (var r in doc.RootElement.EnumerateArray())
                    {
                        if (r.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) continue;
                        var tag = r.GetProperty("tag_name").GetString() ?? "";
                        if (tag.StartsWith("installer-", StringComparison.OrdinalIgnoreCase)) continue;
                        var version = Core.ExtractVersion(tag); if (version == "") continue;
                        if (!r.TryGetProperty("assets", out var assets)) continue;
                        if (assets.ValueKind == JsonValueKind.Object && assets.TryGetProperty("links", out var links)) assets = links;
                        if (assets.ValueKind != JsonValueKind.Array) continue;
                        foreach (var a in assets.EnumerateArray())
                        {
                            var filename = a.GetProperty("name").GetString() ?? "";
                            // Exclude source snapshots, unrelated assets and the installer distribution itself.
                            if (!filename.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || !(filename.StartsWith("StarLux-Landing-Meter", StringComparison.OrdinalIgnoreCase) || filename.StartsWith("StarLux_LMM_v", StringComparison.OrdinalIgnoreCase)) || filename.Contains("installer", StringComparison.OrdinalIgnoreCase)) continue;
                            var download = a.GetProperty("browser_download_url").GetString() ?? "";
                            if (!Uri.TryCreate(download, UriKind.Absolute, out var uri) || !TrustedInitial(uri)) continue;
                            var hash = a.TryGetProperty("digest", out var digest) && digest.ValueKind == JsonValueKind.String ? digest.GetString() ?? "" : "";
                            if (!hash.StartsWith("sha256:")) hash = ""; else hash = hash[7..];
                            list.Add(new Release { Version = version, Variant = filename, Sources = [new(name, download, hash)] });
                        }
                    }
                    if (doc.RootElement.GetArrayLength() < 100) break;
                }
                log(U.T($"{name}: 找到 {list.Count} 个安装包", $"{name}: {list.Count} packages found"));
                PluginCatalogAvailable = true;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception e) { InstallerTrace.Fault(name+" plugin catalog",e);log(name + U.T(": 暂不可用，继续使用其他源与本地版本：", ": unavailable; using other sources and local packages: ") + e.Message); }
            return list;
        }
        var results = await Task.WhenAll(Source("GitHub", "https://api.github.com/repos/Starlux531/StarLux-Landing-Meter/releases"), Source("Gitee", "https://gitee.com/api/v5/repos/starlux531/starluxlmm/releases"));
        return results.SelectMany(x => x).GroupBy(r => r.Version + "|" + r.Variant, StringComparer.OrdinalIgnoreCase).Select(g => new Release { Version = g.First().Version, Variant = g.First().Variant, Sources = g.SelectMany(r => r.Sources).ToList() }).OrderByDescending(r => r.Version, Comparer<string>.Create(Core.CompareVersion)).ToList();
    }
    static async Task CopyBounded(Stream input, Stream output, long maximum, CancellationToken token, long? size, Action<int>? progress)
    {
        byte[] buffer = new byte[65536]; long total = 0;
        while (true)
        {
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(token); idle.CancelAfter(TimeSpan.FromSeconds(25));
            int count = await input.ReadAsync(buffer, idle.Token); if (count == 0) break;
            if ((total += count) > maximum) throw new IOException(U.T("下载超过大小限制","Download size limit"));
            await output.WriteAsync(buffer.AsMemory(0, count), token);
            if (size > 0) progress?.Invoke((int)Math.Min(99, total * 100 / size.Value));
        }
        if (size.HasValue && total != size.Value) throw new IOException(U.T("下载不完整","Incomplete download"));
    }
    public async Task<string> Download(IEnumerable<DownloadSource> sources, string destination, string preferred, Action<int> progress, CancellationToken token)
    {
        var list = sources.ToList();
        // If the same named asset has an authenticated GitHub digest, also verify mirror bytes against it.
        var sharedHash = list.Select(s => s.Sha256).FirstOrDefault(s => s.Length == 64) ?? "";
        var errors = new List<string>();
        foreach (var source in list.OrderBy(s => preferred != "Auto" ? (s.Name == preferred ? 0 : 1) : (System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh") && s.Name == "Gitee" ? 0 : 1)))
        {
            try
            {
                log(U.T("下载","Download: ") + source.Name + " · " + source.Url); progress(0);
                InstallerTrace.Event("DOWNLOAD_BEGIN",new {source=source.Name,url=source.Url,destination});
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromMinutes(8));
                using var response = await Open(source.Url, deadline.Token);
                var length = response.Content.Headers.ContentLength;
                if (length > 256L * 1024 * 1024) throw new IOException(U.T("下载包过大","Package too large"));
                using (var input = await response.Content.ReadAsStreamAsync(deadline.Token))
                using (var output = File.Create(destination)) await CopyBounded(input, output, 256L * 1024 * 1024, deadline.Token, length, progress);
                var expected = source.Sha256.Length > 0 ? source.Sha256 : sharedHash;
                var actual=Core.Hash(destination);InstallerTrace.Event("DOWNLOAD_HASH",new {destination,expected,actual});
                if (expected.Length > 0 && !actual.Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new DiagnosticFailure("DOWNLOAD_HASH_MISMATCH",U.T("下载文件 SHA256 校验失败。","Downloaded archive SHA256 mismatch.")+$"\nExpected: {expected}\nActual: {actual}",U.T("文件不会安装，将尝试同版本备用源；若重复失败请导出诊断包。","The file will not be installed; a same-version fallback source will be tried. Export diagnostics if repeated."),destination);
                using (var zip = System.IO.Compression.ZipFile.OpenRead(destination)) { if (zip.Entries.Count == 0) throw new IOException(U.T("空 ZIP","Empty ZIP")); }
                progress(100); InstallerTrace.Event("DOWNLOAD_COMPLETE",new {source=source.Name,destination,bytes=new FileInfo(destination).Length});return destination;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception e) { InstallerTrace.Fault(source.Name+" download",e);errors.Add(source.Name + ": " + e.Message); log(U.T("切换备用源","Trying fallback: ") + e.Message); }
        }
        throw new IOException(U.T("所有下载源均不可用","All sources failed\n") + string.Join("\n", errors));
    }
}
