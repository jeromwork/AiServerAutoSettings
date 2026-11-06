using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace RemoteAgents.Core;

// Own lightweight REST transport; no browser or credentials in URLs.
public sealed class SyncthingClient : IDisposable
{
    readonly HttpClient http;
    public SyncthingClient(int port, string apiKey)
    {
        http = new(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false }) { BaseAddress = new Uri($"http://127.0.0.1:{port}/rest/"), Timeout = TimeSpan.FromSeconds(10) };
        http.DefaultRequestHeaders.Add("X-API-Key",apiKey);
    }
    public async Task<JsonElement> GetAsync(string route, CancellationToken token = default)
    {
        using var response = await http.GetAsync(route,token); response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<JsonElement>(token));
    }
    public async Task SendAsync(string route, HttpMethod method, object? body = null, CancellationToken token = default)
    {
        using var request = new HttpRequestMessage(method,route) { Content = body is null ? null : JsonContent.Create(body) };
        using var response = await http.SendAsync(request,token); response.EnsureSuccessStatusCode();
    }
    public Task PauseAsync(string folder, bool paused) => SendAsync("config/folders/"+Uri.EscapeDataString(folder),HttpMethod.Patch,new { paused });
    public Task SetRatesAsync(int send, int receive) => send<0||receive<0 ? throw new ArgumentOutOfRangeException() : SendAsync("config/options",HttpMethod.Patch,new { maxSendKbps=send, maxRecvKbps=receive });
    public Task SetIgnoresAsync(string folder, IEnumerable<string> additional) => SendAsync("db/ignores?folder="+Uri.EscapeDataString(folder),HttpMethod.Post,new { ignore = IgnorePolicy.Generate(additional).Split('\n',StringSplitOptions.RemoveEmptyEntries) });
    public Task<JsonElement> VersionsAsync(string folder) => GetAsync("folder/versions?folder="+Uri.EscapeDataString(folder));
    public Task<JsonElement> EventsAsync(long since) => GetAsync("events?since="+since+"&timeout=1&limit=100");
    public async Task<SyncStatus> StatusAsync(string folder, string peer)
    {
        var config = await GetAsync("config/folders/"+Uri.EscapeDataString(folder));
        if(config.GetProperty("paused").GetBoolean()) return new(SyncState.Paused);
        var s = await GetAsync("db/status?folder="+Uri.EscapeDataString(folder));
        var c = await GetAsync("system/connections");
        bool connected=c.GetProperty("connections").TryGetProperty(peer,out var p)&&p.GetProperty("connected").GetBoolean();
        long N(string n) => s.TryGetProperty(n,out var v)?v.GetInt64():0;
        var mapped=SyncStatusMapper.Map(new(s.GetProperty("state").GetString()!,N("needBytes"),N("needTotalItems"),N("pullErrors"),N("receiveOnlyTotalItems"),connected,N("inSyncBytes"),N("globalBytes")));
        if(mapped.State==SyncState.Synced) {
            var completion=await GetAsync("db/completion?folder="+Uri.EscapeDataString(folder)+"&device="+Uri.EscapeDataString(peer));
            if(completion.GetProperty("needItems").GetInt64()>0) return new(SyncState.Transferring,completion.GetProperty("completion").GetDouble(),Detail:"Ожидается получение другой стороной");
        }
        return mapped;
    }
    public void Dispose() => http.Dispose();
}
