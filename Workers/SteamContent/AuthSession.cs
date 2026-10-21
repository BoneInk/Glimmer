using SteamKit2.Authentication;

namespace Glimmer.SteamContent;

internal sealed class AuthRequest
{
    public string Method { get; set; } = "";
    public string? Username { get; set; }
    public string? Password { get; set; }
    public string? RefreshToken { get; set; }
    public string? GuardData { get; set; }
    internal void Validate()
    {
        if (Method is not ("credentials" or "qr" or "refresh") ||
            Username?.Length > 128 || Password?.Length > 512 || RefreshToken?.Length > 8192 || GuardData?.Length > 8192 ||
            Username?.Any(char.IsControl) == true ||
            (Method != "qr" && string.IsNullOrWhiteSpace(Username)) ||
            (Method == "credentials" && string.IsNullOrEmpty(Password)) ||
            (Method == "refresh" && string.IsNullOrEmpty(RefreshToken)) ||
            (Method == "qr" && (Password is not null || RefreshToken is not null)) ||
            (Method == "credentials" && RefreshToken is not null) || (Method == "refresh" && Password is not null))
            throw new ContentFailure("invalid_auth_request");
    }
    // Managed strings cannot be securely zeroed. Drop references promptly; never persist/log them.
    internal void ReleaseSecrets() { Password = null; RefreshToken = null; GuardData = null; }
}
internal sealed record AuthResponse(string SessionID, string ChallengeID, string? Code = null, bool? Accepted = null);
internal sealed record AuthChallenge(string SessionID, string ChallengeID, string Type, bool PreviousIncorrect = false,
    string? EmailHint = null, string? ChallengeURL = null);
internal sealed record AuthResult(string AccountName, string SteamID, string? RefreshToken, string? GuardData);
internal sealed class ContentFailure(string code, CDNDirectoryDiagnostics? cdnDirectory = null) : Exception(code)
{
    internal string Code { get; } = code;
    internal CDNDirectoryDiagnostics? CDNDirectory { get; } = cdnDirectory;
}

// One broker belongs to one authentication attempt, never a process-global console authenticator.
internal sealed class AuthChallengeBroker(string sessionID, Action<AuthChallenge> emit, CancellationToken token) : IAuthenticator, IDisposable
{
    private readonly object gate = new();
    private Pending? pending;
    private bool disposed;
    private sealed record Pending(string ID, string Type, TaskCompletionSource<AuthResponse> Completion);
    private async Task<AuthResponse> Ask(string type, bool previous = false, string? email = null)
    {
        Pending p;
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            if (disposed || pending is not null) throw new ContentFailure("auth_challenge_state");
            p = new(Guid.NewGuid().ToString("D"), type, new(TaskCreationOptions.RunContinuationsAsynchronously));
            pending = p;
            emit(new(sessionID, p.ID, type, previous, email is { Length: <= 256 } ? email : null));
        }
        try { return await p.Completion.Task.WaitAsync(token); }
        finally { lock (gate) { if (ReferenceEquals(pending, p)) pending = null; } }
    }
    public async Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect) =>
        (await Ask("device_code", previousCodeWasIncorrect)).Code!;
    public async Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect) =>
        (await Ask("email_code", previousCodeWasIncorrect, email)).Code!;
    public async Task<bool> AcceptDeviceConfirmationAsync() => (await Ask("device_confirmation")).Accepted!.Value;
    internal void QR(string url)
    {
        lock (gate)
        {
            if (disposed || token.IsCancellationRequested) return;
            if (url.Length > 8192 || !Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https")
                throw new ContentFailure("invalid_qr_challenge");
            // QR approval occurs in Steam's own polling session; a host response must never fake it.
            emit(new(sessionID, Guid.NewGuid().ToString("D"), "qr", ChallengeURL: url));
        }
    }
    internal bool Respond(AuthResponse r)
    {
        lock (gate)
        {
            if (disposed || token.IsCancellationRequested || r.SessionID != sessionID || pending is not { } p || p.ID != r.ChallengeID) return false;
            if (p.Type == "device_confirmation")
            { if (r.Accepted is null || r.Code is not null) return false; }
            else if (r.Code is null || r.Code.Length is < 4 or > 16 || !r.Code.All(char.IsAsciiLetterOrDigit) || r.Accepted is not null) return false;
            return p.Completion.TrySetResult(r);
        }
    }
    public void Dispose()
    {
        lock (gate) { disposed = true; pending?.Completion.TrySetCanceled(); pending = null; }
    }
}

internal interface ISteamContentSession : IAsyncDisposable
{
    string ID { get; }
    bool Authenticated { get; }
    Task<AuthResult> Login(AuthRequest input, AuthChallengeBroker challenges, CancellationToken token);
    Task<AuthorizedManifest> Resolve(ulong publishedFileID, CancellationToken token);
    Task<EngineAssetResolution> ResolveEngineAssets(IReadOnlyList<string> resources, CancellationToken token);
    Task<EngineAssetInspection> InspectEngineAssets(IReadOnlyList<string> resources, CancellationToken token);
    Task<EngineManifestInventory> InspectEngineAssetInventory(CancellationToken token);
    Task<AuthorizedManifest> ResolveSceneRuntimeAssets(CancellationToken token);
    Task DownloadChunk(AuthorizedManifest authorized, DepotChunkEntry chunk, byte[] output,
        Action<int> received, CancellationToken token);
}

internal sealed class SessionController(Func<string, ISteamContentSession> factory) : IAsyncDisposable
{
    private readonly object gate = new();
    private ISteamContentSession? session;
    private AuthChallengeBroker? broker;
    private CancellationTokenSource? lifetime;
    private Task<AuthResult>? login;
    private bool closing;
    internal string? ID { get { lock (gate) return session?.ID; } }
    internal Task<AuthResult> BeginLogin(AuthRequest request, Action<AuthChallenge> challenge)
    {
        request.Validate();
        lock (gate)
        {
            if (session is not null || closing) throw new ContentFailure("session_busy");
            var id = Guid.NewGuid().ToString("D");
            var cts = new CancellationTokenSource();
            lifetime = cts;
            var deadline = CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
            deadline.CancelAfter(TimeSpan.FromMinutes(5));
            broker = new AuthChallengeBroker(id, challenge, deadline.Token);
            ISteamContentSession created;
            try { created = factory(id); }
            catch
            {
                broker.Dispose(); deadline.Dispose(); cts.Dispose(); lifetime = null; broker = null;
                request.ReleaseSecrets(); throw;
            }
            session = created;
            var ownBroker = broker;
            login = Task.Run(async () =>
            {
                try
                {
                    var result = await created.Login(request, ownBroker, deadline.Token);
                    lock (gate)
                    {
                        if (!ReferenceEquals(session, created) || closing) throw new OperationCanceledException(cts.Token);
                        cts.Token.ThrowIfCancellationRequested();
                        if (!created.Authenticated) throw new ContentFailure("auth_adapter_not_authenticated");
                    }
                    return result;
                }
                finally { ownBroker.Dispose(); deadline.Dispose(); request.ReleaseSecrets(); }
            });
            return login;
        }
    }
    internal bool Respond(AuthResponse response) { lock (gate) return broker?.Respond(response) == true; }
    internal ISteamContentSession Require(string? id)
    {
        lock (gate)
        {
            if (closing || lifetime?.IsCancellationRequested != false || session is null || session.ID != id || !session.Authenticated)
                throw new ContentFailure("session_not_authenticated");
            return session;
        }
    }
    internal async Task Close(string? id)
    {
        ISteamContentSession? own; Task<AuthResult>? ownLogin; CancellationTokenSource? cts;
        lock (gate)
        {
            if (closing) throw new ContentFailure("session_closing");
            if (session is null || id != session.ID) throw new ContentFailure("stale_session");
            closing = true; own = session; ownLogin = login; cts = lifetime;
            cts?.Cancel(); broker?.Dispose();
        }
        try
        {
            // Disconnect first so SDK jobs waiting on CM/auth are actively stopped, not merely hidden.
            await own.DisposeAsync();
            if (ownLogin is not null) { try { await ownLogin; } catch (Exception) { } }
        }
        finally
        {
            lock (gate) { session = null; broker = null; login = null; lifetime = null; closing = false; cts?.Dispose(); }
        }
    }
    public async ValueTask DisposeAsync() { var id = ID; if (id is not null) await Close(id); }
}
