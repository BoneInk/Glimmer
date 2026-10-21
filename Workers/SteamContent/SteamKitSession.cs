using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.Internal;
using SteamKit2.CDN;

namespace Glimmer.SteamContent;

internal sealed class CDNTokenGatePool : IDisposable
{
    private readonly object gate = new();
    private readonly Dictionary<(uint Depot, string Host), SemaphoreSlim> entries = [];
    internal async ValueTask<IDisposable> Enter((uint Depot, string Host) key, CancellationToken token)
    {
        SemaphoreSlim entry;
        lock (gate) { if (!entries.TryGetValue(key, out entry!)) entries[key] = entry = new(1, 1); }
        await entry.WaitAsync(token);
        return new Lease(entry);
    }
    public void Dispose() { lock (gate) { foreach (var entry in entries.Values) entry.Dispose(); entries.Clear(); } }
    private sealed class Lease(SemaphoreSlim entry) : IDisposable
    {
        private int released;
        public void Dispose() { if (Interlocked.Exchange(ref released, 1) == 0) entry.Release(); }
    }
}

// Direct official SteamKit2 calls only. Construction does NOT connect; Login is the sole network
// entry point. This adapter does not inspect SteamCMD/Steam GUI account, cache or content directories.
internal sealed class SteamKitSession : ISteamContentSession
{
    public string ID { get; }
    public bool Authenticated => authenticated && !lifetimeToken.IsCancellationRequested && client.IsConnected;
    private volatile bool authenticated;
    private readonly SteamConfiguration configuration;
    private readonly SteamClient client;
    private readonly SteamUser user;
    private readonly SteamApps apps;
    private readonly SteamKit2.SteamContent content;
    private readonly SteamUnifiedMessages unified;
    private readonly CallbackManager callbacks;
    private readonly CancellationTokenSource lifetime = new();
    private readonly CancellationToken lifetimeToken;
    private readonly AsyncLocal<CDNRequestScope?> currentHTTP = new();
    private readonly TaskCompletionSource connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource<SteamUser.LoggedOnCallback> loggedOn = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly List<IDisposable> subscriptions = [];
    private readonly Task pump;
    private uint cellID;
    private readonly Dictionary<(uint Depot, string Host), SteamKit2.SteamContent.CDNAuthToken> cdnTokens = [];
    private readonly CDNTokenGatePool cdnTokenGates = new();
    private int disposed;
    internal SteamKitSession(string id)
    {
        ID = id; lifetimeToken = lifetime.Token;
        configuration = SteamConfiguration.Create(builder => builder
            .WithProtocolTypes(ProtocolTypes.WebSocket)
            .WithHttpClientFactory(purpose =>
            {
                if (purpose == HttpClientPurpose.CDN)
                {
                    var scope = currentHTTP.Value ?? throw new ContentFailure("cdn_context_missing");
                    return new HttpClient(new CDNBoundaryHandler(scope, SteamHTTP.Handler())) { Timeout = TimeSpan.FromSeconds(90) };
                }
                return CreateNonCDNHTTPClient(purpose);
            }));
        client = new SteamClient(configuration);
        user = client.GetHandler<SteamUser>()!; apps = client.GetHandler<SteamApps>()!;
        content = client.GetHandler<SteamKit2.SteamContent>()!; unified = client.GetHandler<SteamUnifiedMessages>()!;
        callbacks = new CallbackManager(client);
        subscriptions.Add(callbacks.Subscribe<SteamClient.ConnectedCallback>(_ => connected.TrySetResult()));
        subscriptions.Add(callbacks.Subscribe<SteamClient.DisconnectedCallback>(_ =>
        {
            authenticated = false;
            connected.TrySetException(new ContentFailure("steam_disconnected"));
            loggedOn.TrySetException(new ContentFailure("steam_disconnected"));
            lifetime.Cancel();
        }));
        subscriptions.Add(callbacks.Subscribe<SteamUser.LoggedOnCallback>(result =>
        {
            if (result.Result == EResult.OK) { cellID = result.CellID; authenticated = true; }
            loggedOn.TrySetResult(result);
        }));
        subscriptions.Add(callbacks.Subscribe<SteamUser.LoggedOffCallback>(_ => { authenticated = false; lifetime.Cancel(); }));
        pump = Task.Run(async () =>
        {
            try
            {
                while (!lifetimeToken.IsCancellationRequested)
                { callbacks.RunCallbacks(); await Task.Delay(10, lifetimeToken); }
            }
            catch (OperationCanceledException) { }
        });
    }
    internal static HttpClient CreateNonCDNHTTPClient(HttpClientPurpose purpose = HttpClientPurpose.WebAPI) =>
        new(purpose == HttpClientPurpose.CMWebSocket ? SteamHTTP.CMWebSocketHandler() : SteamHTTP.Handler())
        { Timeout = TimeSpan.FromSeconds(30) };
    public async Task<AuthResult> Login(AuthRequest input, AuthChallengeBroker challenges, CancellationToken token)
    {
        input.Validate();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(token, lifetimeToken);
        var ct = cancellation.Token;
        client.Connect();
        await connected.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
        string account;
        string refresh;
        string? guard = null;
        if (input.Method == "refresh") { account = input.Username!; refresh = input.RefreshToken!; }
        else
        {
            var details = new AuthSessionDetails { Username = input.Username, Password = input.Password,
                IsPersistentSession = true, DeviceFriendlyName = "Glimmer Steam Content",
                Authenticator = challenges, GuardData = input.GuardData };
            AuthSession auth;
            if (input.Method == "qr")
            {
                var qr = await client.Authentication.BeginAuthSessionViaQRAsync(details).WaitAsync(ct);
                qr.ChallengeURLChanged = () => challenges.QR(qr.ChallengeURL);
                challenges.QR(qr.ChallengeURL); auth = qr;
            }
            else auth = await client.Authentication.BeginAuthSessionViaCredentialsAsync(details).WaitAsync(ct);
            var result = await auth.PollingWaitForResultAsync(ct);
            account = result.AccountName; refresh = result.RefreshToken; guard = result.NewGuardData;
        }
        ct.ThrowIfCancellationRequested();
        // A distinct login ID is not a guarantee against all Steam account restrictions, but avoids
        // reusing another local client's LoginID. No persistent Steam config is read or modified.
        uint loginID = BitConverter.ToUInt32(RandomNumberGenerator.GetBytes(4));
        user.LogOn(new SteamUser.LogOnDetails { Username = account, AccessToken = refresh,
            ShouldRememberPassword = true, LoginID = loginID == 0 ? 1 : loginID });
        var logged = await loggedOn.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
        if (logged.Result != EResult.OK) throw new ContentFailure("steam_logon_" + (int)logged.Result);
        ct.ThrowIfCancellationRequested();
        return new(account, client.SteamID?.ConvertToUInt64().ToString() ?? throw new ContentFailure("steam_identity_missing"), refresh, guard);
    }
    private CancellationTokenSource Link(CancellationToken token)
    {
        if (!Authenticated) throw new ContentFailure("session_not_authenticated");
        return CancellationTokenSource.CreateLinkedTokenSource(token, lifetimeToken);
    }
    private Client CDN(CDNRequestScope scope)
    {
        var previous = currentHTTP.Value; currentHTTP.Value = scope;
        try { return new Client(client); } finally { currentHTTP.Value = previous; }
    }
    public async Task<AuthorizedManifest> Resolve(ulong publishedFileID, CancellationToken token)
    {
        using var cancellation = Link(token); cancellation.CancelAfter(TimeSpan.FromMinutes(2)); var ct = cancellation.Token;
        if (publishedFileID == 0) throw new ContentFailure("invalid_published_file_id");
        var request = new CPublishedFile_GetDetails_Request { appid = 431960, includechildren = true };
        request.publishedfileids.Add(publishedFileID);
        var response = await unified.CreateService<PublishedFile>().GetDetails(request).ToTask().WaitAsync(ct);
        if (response.Result != EResult.OK || response.Body.publishedfiledetails.Count != 1) throw new ContentFailure("ugc_lookup_failed");
        var details = response.Body.publishedfiledetails[0]; AuthorizedManifest.CheckDetails(details, publishedFileID);
        var tokens = await apps.PICSGetAccessTokens(431960u, null).ToTask().WaitAsync(ct);
        if (tokens.AppTokensDenied.Contains(431960u)) throw new ContentFailure("app_token_denied");
        tokens.AppTokens.TryGetValue(431960u, out ulong access);
        var product = await apps.PICSGetProductInfo(new SteamApps.PICSRequest(431960, access), null).ToTask().WaitAsync(ct);
        if (product.Results is null) throw new ContentFailure("appinfo_not_available");
        var info = product.Results.SelectMany(r => r.Apps).Where(p => p.Key == 431960u).Select(p => p.Value).LastOrDefault();
        if (info is null || info.MissingToken || !product.Complete || product.Failed) throw new ContentFailure("appinfo_not_available");
        if (info.UseHttp && info.KeyValues.Children.Count == 0) throw new ContentFailure("appinfo_http_delivery_not_supported");
        if (info.KeyValues["depots"].Children.Count == 0) throw new ContentFailure("appinfo_depots_missing");
        var depotValue = info.KeyValues["depots"]["workshopdepot"].Value;
        uint depot = 431960;
        if (depotValue is not null && (!uint.TryParse(depotValue, out depot) || depot == 0)) throw new ContentFailure("workshop_depot_invalid");
        var key = await apps.GetDepotDecryptionKey(depot, 431960).ToTask().WaitAsync(ct);
        if (key.Result != EResult.OK || key.DepotKey?.Length != 32 || key.DepotID != depot) throw new ContentFailure("depot_key_denied");
        try
        {
            ulong code = await content.GetManifestRequestCode(depot, 431960, details.hcontent_file).WaitAsync(ct);
            if (code == 0) throw new ContentFailure("manifest_access_denied");
            var selection = await CDNServerDirectory.Find(cellID, async requestedCell =>
            {
                var directory = await unified.CreateService<ContentServerDirectory>().GetServersForSteamPipe(
                    new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = requestedCell, max_servers = 64 }).ToTask().WaitAsync(ct);
                if (directory.Result != EResult.OK) throw new ContentFailure("cdn_directory_denied");
                return directory.Body;
            }, async () =>
            {
                ct.ThrowIfCancellationRequested();
                using var directory = configuration.GetAsyncWebAPIInterface("IContentServerDirectoryService");
                var response = await directory.CallProtobufAsync<CContentServerDirectory_GetServersForSteamPipe_Response,
                    CContentServerDirectory_GetServersForSteamPipe_Request>(HttpMethod.Get,
                    nameof(ContentServerDirectory.GetServersForSteamPipe),
                    new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = 0, max_servers = 64 }, version: 1).WaitAsync(ct);
                ct.ThrowIfCancellationRequested();
                return response.Body;
            }, ct);
            var servers = selection.Servers;
            if (servers.Length == 0) throw new ContentFailure("no_supported_https_cdn", selection.Diagnostics);
            for (int attempt = 0; attempt < Math.Max(3, servers.Length); attempt++)
            {
                var server = servers[attempt % servers.Length];
                ct.ThrowIfCancellationRequested();
                try
                {
                    string? authToken = CachedCDNToken(depot, server);
                    DepotManifest manifest;
                    try { manifest = await DownloadManifest(depot, details.hcontent_file, code, server, key.DepotKey, authToken, ct); }
                    catch (HttpRequestException e) when (NeedsToken(e, authToken, ct))
                    {
                        authToken = await CDNToken(depot, server, ct);
                        manifest = await DownloadManifest(depot, details.hcontent_file, code, server, key.DepotKey, authToken, ct);
                    }
                    ct.ThrowIfCancellationRequested();
                    return AuthorizedManifest.FromSDK(ID, details, publishedFileID, depot, manifest, key.DepotKey, servers);
                }
                catch (Exception e) when (Retryable(e, ct)) { InvalidateToken(depot, server, e); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (ContentFailure) { throw; }
                catch (Exception) { throw new ContentFailure("manifest_protocol_failed"); }
            }
            throw new ContentFailure("manifest_download_failed");
        }
        finally { CryptographicOperations.ZeroMemory(key.DepotKey); }
    }
    public async Task<EngineAssetResolution> ResolveEngineAssets(IReadOnlyList<string> resources, CancellationToken token)
    {
        var requested = EngineAssetCatalog.Validate(resources);
        using var cancellation = Link(token); cancellation.CancelAfter(TimeSpan.FromMinutes(2)); var ct = cancellation.Token;
        var tokens = await apps.PICSGetAccessTokens(EngineAssetCatalog.AppID, null).ToTask().WaitAsync(ct);
        if (tokens.AppTokensDenied.Contains(EngineAssetCatalog.AppID)) throw new ContentFailure("app_token_denied");
        tokens.AppTokens.TryGetValue(EngineAssetCatalog.AppID, out ulong access);
        var product = await apps.PICSGetProductInfo(new SteamApps.PICSRequest(EngineAssetCatalog.AppID, access), null).ToTask().WaitAsync(ct);
        if (product.Results is null) throw new ContentFailure("appinfo_not_available");
        var info = product.Results.SelectMany(r => r.Apps).Where(p => p.Key == EngineAssetCatalog.AppID).Select(p => p.Value).LastOrDefault();
        if (info is null || info.MissingToken || !product.Complete || product.Failed) throw new ContentFailure("appinfo_not_available");
        if (info.UseHttp && info.KeyValues.Children.Count == 0) throw new ContentFailure("appinfo_http_delivery_not_supported");
        var depots = EngineAssetCatalog.PublicWindowsDepots(info.KeyValues);
        var selection = await CDNServerDirectory.Find(cellID, async requestedCell =>
        {
            var directory = await unified.CreateService<ContentServerDirectory>().GetServersForSteamPipe(
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = requestedCell, max_servers = 64 }).ToTask().WaitAsync(ct);
            if (directory.Result != EResult.OK) throw new ContentFailure("cdn_directory_denied");
            return directory.Body;
        }, async () =>
        {
            ct.ThrowIfCancellationRequested();
            using var directory = configuration.GetAsyncWebAPIInterface("IContentServerDirectoryService");
            var response = await directory.CallProtobufAsync<CContentServerDirectory_GetServersForSteamPipe_Response,
                CContentServerDirectory_GetServersForSteamPipe_Request>(HttpMethod.Get,
                nameof(ContentServerDirectory.GetServersForSteamPipe),
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = 0, max_servers = 64 }, version: 1).WaitAsync(ct);
            ct.ThrowIfCancellationRequested(); return response.Body;
        }, ct);
        if (selection.Servers.Length == 0) throw new ContentFailure("no_supported_https_cdn", selection.Diagnostics);
        bool authorizedDepot = false;
        foreach (var candidate in depots)
        {
            ct.ThrowIfCancellationRequested();
            var key = await apps.GetDepotDecryptionKey(candidate.DepotID, EngineAssetCatalog.AppID).ToTask().WaitAsync(ct);
            if (key.Result != EResult.OK || key.DepotKey?.Length != 32 || key.DepotID != candidate.DepotID) continue;
            authorizedDepot = true;
            try
            {
                ulong code = await content.GetManifestRequestCode(candidate.DepotID, EngineAssetCatalog.AppID, candidate.ManifestID).WaitAsync(ct);
                if (code == 0) continue;
                for (int attempt = 0; attempt < Math.Max(3, selection.Servers.Length); attempt++)
                {
                    var server = selection.Servers[attempt % selection.Servers.Length];
                    try
                    {
                        string? authToken = CachedCDNToken(candidate.DepotID, server);
                        DepotManifest manifest;
                        try { manifest = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct); }
                        catch (HttpRequestException e) when (NeedsToken(e, authToken, ct))
                        {
                            authToken = await CDNToken(candidate.DepotID, server, ct);
                            manifest = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct);
                        }
                        var matched = EngineAssetCatalog.Match(manifest, requested);
                        if (matched is null) break;
                        var authorized = AuthorizedManifest.FromAppDepot(ID, candidate.DepotID, candidate.ManifestID,
                            manifest, key.DepotKey, selection.Servers, matched.Values.ToHashSet(StringComparer.Ordinal));
                        return new(authorized, matched);
                    }
                    catch (Exception e) when (Retryable(e, ct)) { InvalidateToken(candidate.DepotID, server, e); }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (ContentFailure) { throw; }
                    catch (Exception) { throw new ContentFailure("manifest_protocol_failed"); }
                }
            }
            finally { CryptographicOperations.ZeroMemory(key.DepotKey); }
        }
        throw new ContentFailure(authorizedDepot ? "engine_assets_not_found" : "engine_depot_key_denied");
    }
    public async Task<EngineAssetInspection> InspectEngineAssets(IReadOnlyList<string> resources, CancellationToken token)
    {
        var requested = EngineAssetCatalog.Validate(resources);
        using var cancellation = Link(token); cancellation.CancelAfter(TimeSpan.FromMinutes(2)); var ct = cancellation.Token;
        var tokens = await apps.PICSGetAccessTokens(EngineAssetCatalog.AppID, null).ToTask().WaitAsync(ct);
        if (tokens.AppTokensDenied.Contains(EngineAssetCatalog.AppID)) throw new ContentFailure("app_token_denied");
        tokens.AppTokens.TryGetValue(EngineAssetCatalog.AppID, out ulong access);
        var product = await apps.PICSGetProductInfo(new SteamApps.PICSRequest(EngineAssetCatalog.AppID, access), null).ToTask().WaitAsync(ct);
        if (product.Results is null) throw new ContentFailure("appinfo_not_available");
        var info = product.Results.SelectMany(r => r.Apps).Where(p => p.Key == EngineAssetCatalog.AppID).Select(p => p.Value).LastOrDefault();
        if (info is null || info.MissingToken || !product.Complete || product.Failed) throw new ContentFailure("appinfo_not_available");
        var depots = EngineAssetCatalog.PublicWindowsDepots(info.KeyValues);
        var selection = await CDNServerDirectory.Find(cellID, async requestedCell =>
        {
            var directory = await unified.CreateService<ContentServerDirectory>().GetServersForSteamPipe(
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = requestedCell, max_servers = 64 }).ToTask().WaitAsync(ct);
            if (directory.Result != EResult.OK) throw new ContentFailure("cdn_directory_denied"); return directory.Body;
        }, async () =>
        {
            ct.ThrowIfCancellationRequested(); using var directory = configuration.GetAsyncWebAPIInterface("IContentServerDirectoryService");
            var response = await directory.CallProtobufAsync<CContentServerDirectory_GetServersForSteamPipe_Response,
                CContentServerDirectory_GetServersForSteamPipe_Request>(HttpMethod.Get,
                nameof(ContentServerDirectory.GetServersForSteamPipe),
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = 0, max_servers = 64 }, version: 1).WaitAsync(ct);
            ct.ThrowIfCancellationRequested(); return response.Body;
        }, ct);
        if (selection.Servers.Length == 0) throw new ContentFailure("no_supported_https_cdn", selection.Diagnostics);
        bool authorizedDepot = false;
        var manifests = new List<AppDepotManifest>(); var paths = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var candidate in depots)
        {
            ct.ThrowIfCancellationRequested();
            var key = await apps.GetDepotDecryptionKey(candidate.DepotID, EngineAssetCatalog.AppID).ToTask().WaitAsync(ct);
            if (key.Result != EResult.OK || key.DepotKey?.Length != 32 || key.DepotID != candidate.DepotID) continue;
            authorizedDepot = true;
            try
            {
                ulong code = await content.GetManifestRequestCode(candidate.DepotID, EngineAssetCatalog.AppID, candidate.ManifestID).WaitAsync(ct);
                if (code == 0) continue;
                DepotManifest? loaded = null;
                for (int attempt = 0; attempt < Math.Max(3, selection.Servers.Length); attempt++)
                {
                    var server = selection.Servers[attempt % selection.Servers.Length];
                    try
                    {
                        string? authToken = CachedCDNToken(candidate.DepotID, server);
                        try { loaded = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct); }
                        catch (HttpRequestException e) when (NeedsToken(e, authToken, ct))
                        {
                            authToken = await CDNToken(candidate.DepotID, server, ct);
                            loaded = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct);
                        }
                        break;
                    }
                    catch (Exception e) when (Retryable(e, ct)) { InvalidateToken(candidate.DepotID, server, e); }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (ContentFailure) { throw; }
                    catch (Exception) { throw new ContentFailure("manifest_protocol_failed"); }
                }
                if (loaded is null) continue;
                foreach (string path in EngineAssetCatalog.Inspect(loaded, requested))
                {
                    paths.Add(path);
                    if (paths.Count > 192 || paths.Sum(p => p.Length) > 64 * 1024)
                        throw new ContentFailure("engine_asset_inspection_limit");
                }
                manifests.Add(candidate);
            }
            finally { CryptographicOperations.ZeroMemory(key.DepotKey); }
        }
        if (!authorizedDepot) throw new ContentFailure("engine_depot_key_denied");
        if (manifests.Count == 0) throw new ContentFailure("manifest_access_denied");
        return new(manifests.AsReadOnly(), paths.ToArray());
    }
    public async Task<AuthorizedManifest> ResolveSceneRuntimeAssets(CancellationToken token)
    {
        using var cancellation = Link(token); cancellation.CancelAfter(TimeSpan.FromMinutes(2)); var ct = cancellation.Token;
        var tokens = await apps.PICSGetAccessTokens(EngineAssetCatalog.AppID, null).ToTask().WaitAsync(ct);
        if (tokens.AppTokensDenied.Contains(EngineAssetCatalog.AppID)) throw new ContentFailure("app_token_denied");
        tokens.AppTokens.TryGetValue(EngineAssetCatalog.AppID, out ulong access);
        var product = await apps.PICSGetProductInfo(new SteamApps.PICSRequest(EngineAssetCatalog.AppID, access), null).ToTask().WaitAsync(ct);
        if (product.Results is null) throw new ContentFailure("appinfo_not_available");
        var info = product.Results.SelectMany(r => r.Apps).Where(p => p.Key == EngineAssetCatalog.AppID).Select(p => p.Value).LastOrDefault();
        if (info is null || info.MissingToken || !product.Complete || product.Failed) throw new ContentFailure("appinfo_not_available");
        var depots = EngineAssetCatalog.PublicWindowsDepots(info.KeyValues);
        var selection = await CDNServerDirectory.Find(cellID, async requestedCell =>
        {
            var directory = await unified.CreateService<ContentServerDirectory>().GetServersForSteamPipe(
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = requestedCell, max_servers = 64 }).ToTask().WaitAsync(ct);
            if (directory.Result != EResult.OK) throw new ContentFailure("cdn_directory_denied"); return directory.Body;
        }, async () =>
        {
            ct.ThrowIfCancellationRequested(); using var directory = configuration.GetAsyncWebAPIInterface("IContentServerDirectoryService");
            var response = await directory.CallProtobufAsync<CContentServerDirectory_GetServersForSteamPipe_Response,
                CContentServerDirectory_GetServersForSteamPipe_Request>(HttpMethod.Get,
                nameof(ContentServerDirectory.GetServersForSteamPipe),
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = 0, max_servers = 64 }, version: 1).WaitAsync(ct);
            ct.ThrowIfCancellationRequested(); return response.Body;
        }, ct);
        if (selection.Servers.Length == 0) throw new ContentFailure("no_supported_https_cdn", selection.Diagnostics);
        AuthorizedManifest? selected = null;
        try
        {
            foreach (var candidate in depots)
            {
                ct.ThrowIfCancellationRequested();
                var key = await apps.GetDepotDecryptionKey(candidate.DepotID, EngineAssetCatalog.AppID).ToTask().WaitAsync(ct);
                if (key.Result != EResult.OK || key.DepotKey?.Length != 32 || key.DepotID != candidate.DepotID)
                    throw new ContentFailure("scene_runtime_manifest_incomplete");
                try
                {
                    ulong code = await content.GetManifestRequestCode(candidate.DepotID, EngineAssetCatalog.AppID, candidate.ManifestID).WaitAsync(ct);
                    if (code == 0) throw new ContentFailure("scene_runtime_manifest_incomplete");
                    DepotManifest? loaded = null;
                    for (int attempt = 0; attempt < Math.Max(3, selection.Servers.Length); attempt++)
                    {
                        var server = selection.Servers[attempt % selection.Servers.Length];
                        try
                        {
                            string? authToken = CachedCDNToken(candidate.DepotID, server);
                            try { loaded = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct); }
                            catch (HttpRequestException e) when (NeedsToken(e, authToken, ct))
                            {
                                authToken = await CDNToken(candidate.DepotID, server, ct);
                                loaded = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct);
                            }
                            break;
                        }
                        catch (Exception e) when (Retryable(e, ct)) { InvalidateToken(candidate.DepotID, server, e); }
                        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                        catch (ContentFailure) { throw; }
                        catch (Exception) { throw new ContentFailure("manifest_protocol_failed"); }
                    }
                    if (loaded is null) throw new ContentFailure("scene_runtime_manifest_incomplete");
                    if (!SceneRuntimeAssetCatalog.HasSafeAssetFiles(candidate.DepotID, candidate.ManifestID, loaded)) continue;
                    if (selected is not null) throw new ContentFailure("scene_runtime_manifest_ambiguous");
                    selected = AuthorizedManifest.FromSceneRuntimeAssets(ID, candidate.DepotID, candidate.ManifestID,
                        loaded, key.DepotKey, selection.Servers);
                }
                finally { CryptographicOperations.ZeroMemory(key.DepotKey); }
            }
        }
        catch { if (selected is not null) CryptographicOperations.ZeroMemory(selected.DepotKey); throw; }
        return selected ?? throw new ContentFailure("engine_assets_not_found");
    }
    public async Task<EngineManifestInventory> InspectEngineAssetInventory(CancellationToken token)
    {
        using var cancellation = Link(token); cancellation.CancelAfter(TimeSpan.FromMinutes(2)); var ct = cancellation.Token;
        var tokens = await apps.PICSGetAccessTokens(EngineAssetCatalog.AppID, null).ToTask().WaitAsync(ct);
        if (tokens.AppTokensDenied.Contains(EngineAssetCatalog.AppID)) throw new ContentFailure("app_token_denied");
        tokens.AppTokens.TryGetValue(EngineAssetCatalog.AppID, out ulong access);
        var product = await apps.PICSGetProductInfo(new SteamApps.PICSRequest(EngineAssetCatalog.AppID, access), null).ToTask().WaitAsync(ct);
        if (product.Results is null) throw new ContentFailure("appinfo_not_available");
        var info = product.Results.SelectMany(r => r.Apps).Where(p => p.Key == EngineAssetCatalog.AppID).Select(p => p.Value).LastOrDefault();
        if (info is null || info.MissingToken || !product.Complete || product.Failed) throw new ContentFailure("appinfo_not_available");
        var depots = EngineAssetCatalog.PublicWindowsDepots(info.KeyValues);
        var selection = await CDNServerDirectory.Find(cellID, async requestedCell =>
        {
            var directory = await unified.CreateService<ContentServerDirectory>().GetServersForSteamPipe(
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = requestedCell, max_servers = 64 }).ToTask().WaitAsync(ct);
            if (directory.Result != EResult.OK) throw new ContentFailure("cdn_directory_denied"); return directory.Body;
        }, async () =>
        {
            ct.ThrowIfCancellationRequested(); using var directory = configuration.GetAsyncWebAPIInterface("IContentServerDirectoryService");
            var response = await directory.CallProtobufAsync<CContentServerDirectory_GetServersForSteamPipe_Response,
                CContentServerDirectory_GetServersForSteamPipe_Request>(HttpMethod.Get,
                nameof(ContentServerDirectory.GetServersForSteamPipe),
                new CContentServerDirectory_GetServersForSteamPipe_Request { cell_id = 0, max_servers = 64 }, version: 1).WaitAsync(ct);
            ct.ThrowIfCancellationRequested(); return response.Body;
        }, ct);
        if (selection.Servers.Length == 0) throw new ContentFailure("no_supported_https_cdn", selection.Diagnostics);
        var loadedManifests = new List<(uint, ulong, DepotManifest)>();
        foreach (var candidate in depots)
        {
            ct.ThrowIfCancellationRequested();
            var key = await apps.GetDepotDecryptionKey(candidate.DepotID, EngineAssetCatalog.AppID).ToTask().WaitAsync(ct);
            if (key.Result != EResult.OK || key.DepotKey?.Length != 32 || key.DepotID != candidate.DepotID)
                throw new ContentFailure("engine_inventory_incomplete");
            try
            {
                ulong code = await content.GetManifestRequestCode(candidate.DepotID, EngineAssetCatalog.AppID, candidate.ManifestID).WaitAsync(ct);
                if (code == 0) throw new ContentFailure("engine_inventory_incomplete");
                DepotManifest? loaded = null;
                for (int attempt = 0; attempt < Math.Max(3, selection.Servers.Length); attempt++)
                {
                    var server = selection.Servers[attempt % selection.Servers.Length];
                    try
                    {
                        string? authToken = CachedCDNToken(candidate.DepotID, server);
                        try { loaded = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct); }
                        catch (HttpRequestException e) when (NeedsToken(e, authToken, ct))
                        {
                            authToken = await CDNToken(candidate.DepotID, server, ct);
                            loaded = await DownloadManifest(candidate.DepotID, candidate.ManifestID, code, server, key.DepotKey, authToken, ct);
                        }
                        break;
                    }
                    catch (Exception e) when (Retryable(e, ct)) { InvalidateToken(candidate.DepotID, server, e); }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (ContentFailure) { throw; }
                    catch (Exception) { throw new ContentFailure("manifest_protocol_failed"); }
                }
                if (loaded is null) throw new ContentFailure("engine_inventory_incomplete");
                loadedManifests.Add((candidate.DepotID, candidate.ManifestID, loaded));
            }
            finally { CryptographicOperations.ZeroMemory(key.DepotKey); }
        }
        ct.ThrowIfCancellationRequested();
        return EngineManifestInventoryBuilder.Build(loadedManifests);
    }
    private async Task<string?> CDNToken(uint depot, Server server, CancellationToken token)
    {
        var identity = (depot, TokenHost(server));
        lock (cdnTokens)
        {
            if (cdnTokens.TryGetValue(identity, out var cached) && cached.Expiration.ToUniversalTime() > DateTime.UtcNow.AddSeconds(30))
                return cached.Token;
        }
        using (await cdnTokenGates.Enter(identity, token))
        {
            lock (cdnTokens)
                if (cdnTokens.TryGetValue(identity, out var cached) && cached.Expiration.ToUniversalTime() > DateTime.UtcNow.AddSeconds(30))
                    return cached.Token;
            SteamKit2.SteamContent.CDNAuthToken result;
            try { result = await content.GetCDNAuthToken(431960, depot, identity.Item2).WaitAsync(token); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception) { throw new ContentFailure("cdn_auth_failed"); }
            if (result.Result != EResult.OK) throw new ContentFailure("cdn_auth_denied");
            token.ThrowIfCancellationRequested();
            lock (cdnTokens) { if (Authenticated) cdnTokens[identity] = result; }
            return result.Token;
        }
    }
    private string? CachedCDNToken(uint depot, Server server)
    {
        lock (cdnTokens)
        {
            return cdnTokens.TryGetValue((depot, TokenHost(server)), out var cached) &&
                cached.Expiration.ToUniversalTime() > DateTime.UtcNow.AddSeconds(30) ? cached.Token : null;
        }
    }
    internal static string TokenHost(Server server) => server.Host ?? throw new ContentFailure("cdn_sdk_adapter_contract");
    internal static bool NeedsToken(HttpRequestException error, string? token, CancellationToken cancellation) =>
        !cancellation.IsCancellationRequested && token is null &&
        error.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden;
    private async Task<DepotManifest> DownloadManifest(uint depot, ulong manifest, ulong code, Server server,
        byte[] key, string? authToken, CancellationToken token)
    {
        var scope = new CDNRequestScope(server.VHost!, $"/depot/{depot}/manifest/{manifest}/5/{code}", 32 * 1024 * 1024, true, token);
        using var cdn = CDN(scope);
        return await DrainCDN(cdn, cdn.DownloadManifestAsync(depot, manifest, code, server, key, cdnAuthToken: authToken), token);
    }
    public async Task DownloadChunk(AuthorizedManifest authorized, DepotChunkEntry chunk, byte[] output, Action<int> received, CancellationToken token)
    {
        using var cancellation = Link(token); var ct = cancellation.Token;
        if (authorized.SessionID != ID || !authorized.Files.Any(f => f.Chunks.Contains(chunk)) || output.Length != chunk.Length)
            throw new ContentFailure("chunk_outside_authorized_manifest");
        for (int attempt = 0; attempt < 3; attempt++)
        {
            var server = authorized.Servers[attempt % authorized.Servers.Count];
            ct.ThrowIfCancellationRequested();
            if (!CDNBoundary.ValidServer(server)) throw new ContentFailure("cdn_server_mutated");
            try
            {
                string? auth = CachedCDNToken(authorized.DepotID, server);
                int count;
                try { count = await DownloadChunkBody(authorized, chunk, output, received, server, auth, ct); }
                catch (HttpRequestException e) when (NeedsToken(e, auth, ct))
                {
                    auth = await CDNToken(authorized.DepotID, server, ct);
                    count = await DownloadChunkBody(authorized, chunk, output, received, server, auth, ct);
                }
                ct.ThrowIfCancellationRequested();
                if (count != chunk.Length || !CryptographicOperations.FixedTimeEquals(SHA1.HashData(output), Convert.FromHexString(chunk.SHA1)))
                    throw new InvalidDataException("chunk_sha1_or_length");
                return;
            }
            catch (Exception e) when (Retryable(e, ct))
            { InvalidateToken(authorized.DepotID, server, e); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (ContentFailure) { throw; }
            catch (Exception) { throw new ContentFailure("chunk_protocol_failed"); }
        }
        throw new ContentFailure("chunk_download_failed");
    }
    private async Task<int> DownloadChunkBody(AuthorizedManifest authorized, DepotChunkEntry chunk, byte[] output,
        Action<int> received, Server server, string? auth, CancellationToken token)
    {
        var scope = new CDNRequestScope(server.VHost!, $"/depot/{authorized.DepotID}/chunk/{chunk.SHA1}", chunk.CompressedLength, false, token, received);
        using var cdn = CDN(scope);
        return await DrainCDN(cdn, cdn.DownloadDepotChunkAsync(authorized.DepotID, chunk.SDK, server, output, authorized.DepotKey, cdnAuthToken: auth), token);
    }
    internal static bool Retryable(Exception error, CancellationToken token) => !token.IsCancellationRequested &&
        (error is HttpRequestException or IOException or CryptographicException or TaskCanceledException or SteamKitWebRequestException ||
         error is ContentFailure { Code: "cdn_auth_denied" or "cdn_auth_failed" });
    private void InvalidateToken(uint depot, Server server, Exception error)
    {
        if (error is HttpRequestException { StatusCode: System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden })
            lock (cdnTokens) cdnTokens.Remove((depot, TokenHost(server)));
    }
    private static async Task<T> DrainCDN<T>(Client cdn, Task<T> operation, CancellationToken token)
    {
        try { return await operation.WaitAsync(token); }
        catch
        {
            cdn.Dispose();
            try { await operation; } catch (Exception) { }
            throw;
        }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        authenticated = false; lifetime.Cancel(); client.Disconnect();
        try { await pump; } catch (Exception) { }
        foreach (var subscription in subscriptions) subscription.Dispose();
        lock (cdnTokens) cdnTokens.Clear();
        cdnTokenGates.Dispose();
        lifetime.Dispose();
        // SDK client owns no disk login cache. Its callbacks and auth requests die with this session.

    }
}
