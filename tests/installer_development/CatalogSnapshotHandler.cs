using System.Net;
using System.Net.Http;

// Replay the public GitHub response through the actual installer parser.
sealed class CatalogSnapshotHandler(string githubJson) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) {
            Content=new StringContent(request.RequestUri!.Host=="api.github.com" ? githubJson : "[]")
        });
}
