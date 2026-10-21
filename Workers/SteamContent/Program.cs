using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using Glimmer.SteamContent;

internal static class Program
{
    private static readonly Wire wire = new();
    private static readonly object gate = new();
    private static ActiveJob? active;
    private static readonly SessionController sessions = new(id => new SteamKitSession(id));
    private static Task? authTask;
    private static bool authCancelRequested;
    private static readonly Dictionary<string, ulong> epochs = new(StringComparer.Ordinal);
    private sealed record ActiveJob(string JobID, ulong Epoch, TransferPlan? Plan, EngineJob? Engine,
        CancellationTokenSource Cancellation, Task Completion);
    internal static async Task<int> Main(string[] args)
    {
        string? workspace = null;
        string? productionRoot = null;
        if (args.Length == 2 && args[0] == "--fixture-root" && Path.IsPathFullyQualified(args[1]))
        {
            workspace = Path.GetFullPath(args[1]);
            SecurePaths.EnsureDirectory(workspace);
        }
        else if (args.Length == 2 && args[0] == "--workspace-root" && Path.IsPathFullyQualified(args[1]))
        {
            productionRoot = Path.GetFullPath(args[1]);
            try { using var validated = new ManagedContentDirectory(productionRoot); }
            catch (ContentFailure) { wire.Emit("fatal", "startup", detail: new { reason = "workspace_not_private_canonical_directory" }); return 64; }
        }
        else if (args.Length != 0) return 64;
        using var client = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false,
            AutomaticDecompression = System.Net.DecompressionMethods.None, MaxConnectionsPerServer = 4,
            ConnectTimeout = TimeSpan.FromSeconds(5), UseProxy = false }) { Timeout = TimeSpan.FromSeconds(30) };
        wire.Emit("ready", "startup", detail: new { architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            steamKitVersion = typeof(SteamKit2.SteamClient).Assembly.GetName().Version?.ToString(),
            productionWorkshopDownload = productionRoot is not null, fixtureTransfer = workspace is not null,
            productionAuthentication = productionRoot is not null, productionEngineAssets = productionRoot is not null,
            liveAccountAcceptance = "not_run",
            supportedUGC = "authorized_steampipe_manifest_only",
            counterSemantics = "received-body/retry-inclusive;verified-after-checksum-and-flush;reuse-revalidated" });
        try
        {
            await foreach (string line in ReadLines(Console.OpenStandardInput()))
            {
                Command? c;
                try { c = JsonSerializer.Deserialize<Command>(line, Wire.Json); }
                catch (JsonException) { wire.Emit("rejected", "invalid", detail: new { reason = "invalid_json" }); continue; }
                if (c is null || c.V != 1 || !Guid.TryParseExact(c.RequestID, "D", out _))
                { wire.Emit("rejected", "invalid", detail: new { reason = "invalid_envelope" }); continue; }
                if (c.CommandName == "shutdown") { await StopAll(); wire.Emit("stopped", c.RequestID); return 0; }
                if (productionRoot is not null && c.CommandName is "login" or "auth_response" or "auth_cancel" or "logout" or "download" or "engine_assets" or "engine_assets_inventory" or "scene_runtime_assets")
                {
                    try
                    {
                        switch (c.CommandName)
                        {
                            case "login": BeginAuth(c); break;
                            case "auth_response":
                                if (c.Response is null || !sessions.Respond(c.Response)) throw new ContentFailure("stale_or_invalid_auth_response");
                                wire.Emit("auth_response_accepted", c.RequestID, detail: new { sessionID = c.Response.SessionID }); break;
                            case "auth_cancel": case "logout":
                                if (c.SessionID is null || sessions.ID != c.SessionID) throw new ContentFailure("stale_session");
                                await CloseSession(); wire.Emit("logged_out", c.RequestID, detail: new { sessionID = c.SessionID }); break;
                            case "download": BeginProduction(c, productionRoot); break;
                            case "engine_assets": BeginEngineAssets(c, productionRoot); break;
                            case "engine_assets_inventory": BeginEngineAssetInventory(c); break;
                            case "scene_runtime_assets": BeginSceneRuntimeAssets(c, productionRoot); break;
                        }
                    }
                    catch (ContentFailure error) { c.Auth?.ReleaseSecrets(); wire.Emit("rejected", c.RequestID, detail: new { reason = error.Code }); }
                    continue;
                }
                if (c.CommandName == "cancel")
                {
                    lock (gate)
                    {
                        if (active is not null && c.JobID == active.JobID && c.Epoch == active.Epoch)
                        {
                            active.Cancellation.Cancel();
                            if (active.Plan is not null) wire.Emit("cancel_requested", c.RequestID, active.Plan);
                            else wire.EmitEngine("cancel_requested", c.RequestID, active.Engine!);
                        }
                        else wire.Emit("rejected", c.RequestID, detail: new { reason = "stale_job" });
                    }
                    continue;
                }
                if (c.CommandName != "fixture_transfer" || workspace is null || c.Plan is null)
                { wire.Emit("rejected", c.RequestID, detail: new { reason = "command_not_available" }); continue; }
                try { TransferEngine.Validate(c.Plan); }
                catch (Exception e) when (e is InvalidDataException or OverflowException)
                { wire.Emit("rejected", c.RequestID, detail: new { reason = "invalid_plan" }); continue; }
                lock (gate)
                {
                    var plan = c.Plan;
                    if (active is not null) { wire.Emit("rejected", c.RequestID, detail: new { reason = "busy" }); continue; }
                    if (epochs.TryGetValue(plan.JobID, out ulong old) && plan.Epoch <= old)
                    { wire.Emit("rejected", c.RequestID, detail: new { reason = "stale_epoch" }); continue; }
                    if (epochs.Count >= 1024 && !epochs.ContainsKey(plan.JobID))
                    { wire.Emit("rejected", c.RequestID, detail: new { reason = "session_job_limit" }); continue; }
                    epochs[plan.JobID] = plan.Epoch;
                    var cts = new CancellationTokenSource();
                    wire.Emit("started", c.RequestID, plan);
                    // Task.Run prevents asynchronous filesystem/library setup from blocking the stdin
                    // cancel reader. A single active transfer owns all writes and progress callbacks.
                    Task task = Task.Run(async () =>
                    {
                        var engine = new TransferEngine(client, workspace, counters => wire.Emit("progress", c.RequestID, plan, counters));
                        string terminal;
                        object detail;
                        try
                        {
                            await engine.RunAsync(plan, cts.Token);
                            terminal = "transfer_complete"; detail = engine.Counters;
                        }
                        catch (OperationCanceledException) when (cts.IsCancellationRequested)
                        { terminal = "cancelled"; detail = engine.Counters; }
                        catch (Exception error)
                        { terminal = "failed"; detail = new { reason = "content_transfer_failed", errorType = error.GetType().Name, code = FailureCode(error), counters = engine.Counters }; }
                        lock (gate)
                        {
                            // Terminal ACK means writes/handles have stopped AND a new job can start.
                            // Emit while holding the command gate so shutdown cannot overtake it.
                            active = null; cts.Dispose();
                            wire.Emit(terminal, c.RequestID, plan, detail);
                        }
                    });
                    active = new ActiveJob(plan.JobID, plan.Epoch, plan, null, cts, task);
                }
            }
            await StopAll(); return 0;
        }
        catch (InvalidDataException) { await StopAll(); wire.Emit("fatal", "invalid", detail: new { reason = "input_line_limit_or_utf8" }); return 65; }
    }
    private static void BeginAuth(Command c)
    {
        if (c.Auth is null) throw new ContentFailure("auth_request_missing");
        lock (gate)
        {
            if (active is not null || authTask is not null) throw new ContentFailure("busy");
            var operation = sessions.BeginLogin(c.Auth, challenge => wire.Emit("auth_challenge", c.RequestID, detail: challenge));
            string id = sessions.ID!; authCancelRequested = false;
            wire.Emit("auth_started", c.RequestID, detail: new { sessionID = id });
            authTask = Task.Run(async () =>
            {
                string terminal; object detail;
                try
                {
                    var result = await operation;
                    lock (gate)
                    {
                        if (authCancelRequested) throw new OperationCanceledException();
                        _ = sessions.Require(id);
                        // This is an explicitly designated secret-bearing pipe message, never a log.
                        terminal = "auth_result"; detail = new { sessionID = id, result.AccountName, result.SteamID, result.RefreshToken, result.GuardData };
                    }
                }
                catch (Exception error)
                {
                    try { if (sessions.ID == id) await sessions.Close(id); } catch (ContentFailure) { }
                    bool cancelled; lock (gate) cancelled = authCancelRequested;
                    terminal = cancelled ? "auth_cancelled" : "auth_failed";
                    detail = new { sessionID = id, reason = AuthFailureCode(error, cancelled) };
                }
                lock (gate)
                {
                    // Recheck cancellation at emission, after the final async boundary.
                    if (authCancelRequested && terminal == "auth_result")
                    { terminal = "auth_cancelled"; detail = new { sessionID = id, reason = "cancelled" }; }
                    authTask = null; wire.Emit(terminal, c.RequestID, detail: detail);
                }
            });
        }
    }
    private static void BeginProduction(Command c, string workspace)
    {
        if (c.Plan is not null || !Guid.TryParseExact(c.JobID, "D", out _) || c.Epoch is null or 0 ||
            !ulong.TryParse(c.PublishedFileID, out ulong item) || item == 0) throw new ContentFailure("invalid_download_request");
        var session = sessions.Require(c.SessionID);
        lock (gate)
        {
            if (active is not null || authTask is not null) throw new ContentFailure("busy");
            if (epochs.TryGetValue(c.JobID!, out ulong old) && c.Epoch <= old) throw new ContentFailure("stale_epoch");
            if (epochs.Count >= 1024 && !epochs.ContainsKey(c.JobID!)) throw new ContentFailure("session_job_limit");
            epochs[c.JobID!] = c.Epoch.Value;
            var metadata = new TransferPlan(c.JobID!, c.Epoch.Value, 431960, item.ToString(), "0", 0, []);
            var cts = new CancellationTokenSource();
            wire.Emit("resolving", c.RequestID, metadata, new { sessionID = session.ID });
            Task operation = Task.Run(async () =>
            {
                AuthorizedManifest? plan = null;
                var engine = new ManifestDownload(session, workspace, counters => wire.Emit("progress", c.RequestID, metadata, counters));
                string terminal; object detail;
                try
                {
                    plan = await session.Resolve(item, cts.Token);
                    cts.Token.ThrowIfCancellationRequested();
                    _ = sessions.Require(c.SessionID);
                    metadata = metadata with { ManifestID = plan.ManifestID.ToString(), DepotID = plan.DepotID };
                    lock (gate) { if (active is not null) active = active with { Plan = metadata }; }
                    wire.Emit("started", c.RequestID, metadata, new { sessionID = session.ID });
                    string path = await engine.Run(plan, cts.Token);
                    cts.Token.ThrowIfCancellationRequested();
                    terminal = "transfer_complete"; detail = new { counters = engine.Counters, contentRelativePath = path,
                        validationRequired = true, planFingerprint = plan.Fingerprint, sessionID = session.ID };
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested)
                { terminal = "cancelled"; detail = engine.Counters; }
                catch (Exception error)
                { terminal = "failed"; detail = new { reason = error is ContentFailure f ? f.Code : "steam_content_failed", cdnDirectory = (error as ContentFailure)?.CDNDirectory, counters = engine.Counters }; }
                finally { if (plan is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(plan.DepotKey); }
                lock (gate) { active = null; cts.Dispose(); wire.Emit(terminal, c.RequestID, metadata, detail); }
            });
            active = new(metadata.JobID, metadata.Epoch, metadata, null, cts, operation);
        }
    }
    private static void BeginEngineAssets(Command c, string workspace)
    {
        if (c.Plan is not null || c.PublishedFileID is not null || c.AppID != EngineAssetCatalog.AppID ||
            !Guid.TryParseExact(c.JobID, "D", out _) || c.Epoch is null or 0)
            throw new ContentFailure("invalid_engine_asset_request");
        var requested = EngineAssetCatalog.Validate(c.DesiredResources);
        var session = sessions.Require(c.SessionID);
        lock (gate)
        {
            if (active is not null || authTask is not null) throw new ContentFailure("busy");
            if (epochs.TryGetValue(c.JobID!, out ulong old) && c.Epoch <= old) throw new ContentFailure("stale_epoch");
            if (epochs.Count >= 1024 && !epochs.ContainsKey(c.JobID!)) throw new ContentFailure("session_job_limit");
            epochs[c.JobID!] = c.Epoch.Value;
            var metadata = new EngineJob(c.JobID!, c.Epoch.Value);
            var cts = new CancellationTokenSource();
            wire.EmitEngine("engine_assets_resolving", c.RequestID, metadata,
                new { sessionID = session.ID, resourceCount = requested.Count });
            Task operation = Task.Run(async () =>
            {
                AuthorizedManifest? plan = null;
                var engine = new ManifestDownload(session, workspace,
                    counters => wire.EmitEngine("progress", c.RequestID, metadata, counters));
                string terminal; object detail;
                try
                {
                    if (c.InspectOnly == true)
                    {
                        var inspection = await session.InspectEngineAssets(requested.Keys.ToArray(), cts.Token);
                        cts.Token.ThrowIfCancellationRequested(); _ = sessions.Require(c.SessionID);
                        terminal = "engine_assets_inspection";
                        detail = new { sessionID = session.ID, manifests = inspection.Manifests.Select(m => new
                            { depotID = m.DepotID, manifestID = m.ManifestID.ToString() }).ToArray(), paths = inspection.Paths };
                    }
                    else
                    {
                        var resolution = await session.ResolveEngineAssets(requested.Keys.ToArray(), cts.Token);
                        plan = resolution.Manifest;
                        cts.Token.ThrowIfCancellationRequested(); _ = sessions.Require(c.SessionID);
                        metadata = metadata with { ManifestID = plan.ManifestID.ToString(), DepotID = plan.DepotID };
                        lock (gate) { if (active is not null) active = active with { Engine = metadata }; }
                        var planned = resolution.Resources.Select(resource =>
                        {
                            var file = plan.Files.Single(f => f.Path == resource.Value);
                            return new { logicalPath = resource.Key, relativePath = resource.Value,
                                sha1 = file.SHA1, sizeBytes = file.Length.ToString() };
                        }).ToArray();
                        wire.EmitEngine("engine_assets_plan", c.RequestID, metadata,
                            new { sessionID = session.ID, manifestIdentity = new { sha256 = plan.Fingerprint,
                                depotID = plan.DepotID, manifestID = plan.ManifestID.ToString() }, files = planned });
                        string path = await engine.Run(plan, cts.Token, $"engine-assets/{plan.Fingerprint}");
                        cts.Token.ThrowIfCancellationRequested();
                        terminal = "engine_assets_complete";
                        var verified = engine.VerifiedFiles.ToDictionary(f => f.Path, StringComparer.Ordinal);
                        var files = resolution.Resources.Select(resource => new { logicalPath = resource.Key,
                            relativePath = resource.Value, sha256 = verified[resource.Value].SHA256,
                            sizeBytes = verified[resource.Value].Length.ToString() }).ToArray();
                        detail = new { counters = engine.Counters, cacheRelativePath = path,
                            manifestIdentity = new { sha256 = plan.Fingerprint, depotID = plan.DepotID,
                                manifestID = plan.ManifestID.ToString() }, files, sessionID = session.ID };
                    }
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested)
                { terminal = "cancelled"; detail = engine.Counters; }
                catch (Exception error)
                { terminal = "failed"; detail = new { reason = error is ContentFailure f ? f.Code : "steam_content_failed",
                    cdnDirectory = (error as ContentFailure)?.CDNDirectory, counters = engine.Counters }; }
                finally { if (plan is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(plan.DepotKey); }
                lock (gate) { active = null; cts.Dispose(); wire.EmitEngine(terminal, c.RequestID, metadata, detail); }
            });
            active = new(metadata.JobID, metadata.Epoch, null, metadata, cts, operation);
        }
    }
    private static void BeginEngineAssetInventory(Command c)
    {
        if (c.Plan is not null || c.PublishedFileID is not null || c.AppID != EngineAssetCatalog.AppID ||
            c.DesiredResources is not null || c.InspectOnly is not null || !Guid.TryParseExact(c.JobID, "D", out _) || c.Epoch is null or 0)
            throw new ContentFailure("invalid_engine_inventory_request");
        var session = sessions.Require(c.SessionID);
        lock (gate)
        {
            if (active is not null || authTask is not null) throw new ContentFailure("busy");
            if (epochs.TryGetValue(c.JobID!, out ulong old) && c.Epoch <= old) throw new ContentFailure("stale_epoch");
            if (epochs.Count >= 1024 && !epochs.ContainsKey(c.JobID!)) throw new ContentFailure("session_job_limit");
            epochs[c.JobID!] = c.Epoch.Value;
            var metadata = new EngineJob(c.JobID!, c.Epoch.Value);
            var cts = new CancellationTokenSource();
            wire.EmitEngine("engine_inventory_resolving", c.RequestID, metadata, new { sessionID = session.ID });
            Task operation = Task.Run(async () =>
            {
                string terminal; object detail;
                try
                {
                    var inventory = await session.InspectEngineAssetInventory(cts.Token);
                    cts.Token.ThrowIfCancellationRequested(); _ = sessions.Require(c.SessionID);
                    wire.EmitEngine("engine_inventory_begin", c.RequestID, metadata, new { sessionID = session.ID,
                        complete = inventory.Complete,
                        manifests = inventory.Manifests.Select(m => new { depotID = m.DepotID, manifestID = m.ManifestID.ToString() }).ToArray(),
                        groups = inventory.Groups.Select(g => new { category = g.Category, fileCount = g.FileCount,
                            totalBytes = g.TotalBytes.ToString(), maximumFileBytes = g.MaximumFileBytes.ToString() }).ToArray(),
                        extensions = inventory.Extensions.Select(g => new { category = g.Category, fileCount = g.FileCount,
                            totalBytes = g.TotalBytes.ToString(), maximumFileBytes = g.MaximumFileBytes.ToString() }).ToArray(),
                        totalFileCount = inventory.TotalFileCount, totalBytes = inventory.TotalBytes.ToString(),
                        maximumFileBytes = inventory.MaximumFileBytes.ToString(), excludedExecutableCount = inventory.ExcludedExecutableCount,
                        excludedExecutableBytes = inventory.ExcludedExecutableBytes.ToString() });
                    for (int offset = 0; offset < inventory.Files.Count; offset += 4)
                    {
                        cts.Token.ThrowIfCancellationRequested();
                        var files = inventory.Files.Skip(offset).Take(4).Select(f => new { logicalPath = f.LogicalPath,
                            manifestPath = f.ManifestPath, depotID = f.DepotID, manifestID = f.ManifestID.ToString(),
                            sizeBytes = f.SizeBytes.ToString(), sha1 = f.SHA1, category = f.Category,
                            extension = f.Extension, archiveCandidate = f.ArchiveCandidate }).ToArray();
                        wire.EmitEngine("engine_inventory_chunk", c.RequestID, metadata, new { sessionID = session.ID, offset, inventoryFiles = files });
                    }
                    cts.Token.ThrowIfCancellationRequested();
                    terminal = "engine_inventory_complete";
                    detail = new { sessionID = session.ID, complete = true, reportSHA256 = inventory.ReportSHA256 };
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested)
                { terminal = "cancelled"; detail = new { }; }
                catch (Exception error)
                { terminal = "failed"; detail = new { reason = error is ContentFailure f ? f.Code : "steam_content_failed",
                    cdnDirectory = (error as ContentFailure)?.CDNDirectory }; }
                lock (gate) { active = null; cts.Dispose(); wire.EmitEngine(terminal, c.RequestID, metadata, detail); }
            });
            active = new(metadata.JobID, metadata.Epoch, null, metadata, cts, operation);
        }
    }
    private static void BeginSceneRuntimeAssets(Command c, string workspace)
    {
        if (c.Plan is not null || c.PublishedFileID is not null || c.AppID != EngineAssetCatalog.AppID ||
            c.DesiredResources is not null || c.InspectOnly is not null || !Guid.TryParseExact(c.JobID, "D", out _) || c.Epoch is null or 0)
            throw new ContentFailure("invalid_scene_runtime_asset_request");
        var session = sessions.Require(c.SessionID);
        lock (gate)
        {
            if (active is not null || authTask is not null) throw new ContentFailure("busy");
            if (epochs.TryGetValue(c.JobID!, out ulong old) && c.Epoch <= old) throw new ContentFailure("stale_epoch");
            if (epochs.Count >= 1024 && !epochs.ContainsKey(c.JobID!)) throw new ContentFailure("session_job_limit");
            epochs[c.JobID!] = c.Epoch.Value;
            var metadata = new EngineJob(c.JobID!, c.Epoch.Value); var cts = new CancellationTokenSource();
            wire.EmitEngine("scene_runtime_assets_resolving", c.RequestID, metadata, new { sessionID = session.ID });
            Task operation = Task.Run(async () =>
            {
                AuthorizedManifest? plan = null;
                var engine = new ManifestDownload(session, workspace, counters => wire.EmitEngine("progress", c.RequestID, metadata, counters));
                string terminal; object detail;
                try
                {
                    plan = await session.ResolveSceneRuntimeAssets(cts.Token); cts.Token.ThrowIfCancellationRequested(); _ = sessions.Require(c.SessionID);
                    metadata = metadata with { ManifestID = plan.ManifestID.ToString(), DepotID = plan.DepotID };
                    lock (gate) { if (active is not null) active = active with { Engine = metadata }; }
                    var identity = new { sha256 = plan.Fingerprint, depotID = plan.DepotID, manifestID = plan.ManifestID.ToString() };
                    wire.EmitEngine("scene_runtime_assets_plan", c.RequestID, metadata, new { sessionID = session.ID,
                        manifestIdentity = identity, fileCount = plan.Files.Count, totalBytes = plan.TotalBytes.ToString() });
                    for (int offset = 0; offset < plan.Files.Count; offset += 4)
                    {
                        cts.Token.ThrowIfCancellationRequested(); var files = plan.Files.Skip(offset).Take(4).Select(file => new
                        { logicalPath = file.Path["assets/".Length..], relativePath = file.Path, sha1 = file.SHA1, sizeBytes = file.Length.ToString() }).ToArray();
                        wire.EmitEngine("scene_runtime_assets_plan_chunk", c.RequestID, metadata,
                            new { sessionID = session.ID, offset, files });
                    }
                    string path = await engine.Run(plan, cts.Token, $"scene-runtime-assets/{plan.Fingerprint}");
                    cts.Token.ThrowIfCancellationRequested();
                    wire.EmitEngine("scene_runtime_assets_verified_begin", c.RequestID, metadata,
                        new { sessionID = session.ID, fileCount = engine.VerifiedFiles.Count });
                    for (int offset = 0; offset < engine.VerifiedFiles.Count; offset += 4)
                    {
                        cts.Token.ThrowIfCancellationRequested(); var files = engine.VerifiedFiles.Skip(offset).Take(4).Select(file => new
                        { logicalPath = file.Path["assets/".Length..], relativePath = file.Path, sha256 = file.SHA256, sizeBytes = file.Length.ToString() }).ToArray();
                        wire.EmitEngine("scene_runtime_assets_verified_chunk", c.RequestID, metadata,
                            new { sessionID = session.ID, offset, files });
                    }
                    terminal = "scene_runtime_assets_complete";
                    detail = new { sessionID = session.ID, counters = engine.Counters, cacheRelativePath = path,
                        manifestIdentity = identity, fileCount = engine.VerifiedFiles.Count };
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested)
                { terminal = "cancelled"; detail = engine.Counters; }
                catch (Exception error)
                { terminal = "failed"; detail = new { reason = error is ContentFailure f ? f.Code : "steam_content_failed",
                    cdnDirectory = (error as ContentFailure)?.CDNDirectory, counters = engine.Counters }; }
                finally { if (plan is not null) CryptographicOperations.ZeroMemory(plan.DepotKey); }
                lock (gate) { active = null; cts.Dispose(); wire.EmitEngine(terminal, c.RequestID, metadata, detail); }
            });
            active = new(metadata.JobID, metadata.Epoch, null, metadata, cts, operation);
        }
    }
    private static async Task CloseSession()
    {
        Task? ownAuth;
        lock (gate) { authCancelRequested = true; ownAuth = authTask; }
        await Stop();
        string? id = sessions.ID;
        if (id is not null) { try { await sessions.Close(id); } catch (ContentFailure error) when (error.Code == "session_closing") { } }
        if (ownAuth is not null) await ownAuth;
    }
    private static async Task StopAll() { await Stop(); await CloseSession(); }
    internal static string AuthFailureCode(Exception error, bool explicitlyCancelled) => explicitlyCancelled ? "cancelled" : error switch
    {
        ContentFailure f => f.Code,
        TimeoutException or OperationCanceledException => "steam_auth_timeout",
        _ => "steam_auth_failed"
    };
    private static string FailureCode(Exception error)
    {
        string[] codes = ["symlink_directory", "directory_anchor_changed", "open_destination_failed", "destination_not_owned_regular_single_link", "invalid_destination", "file_length_mismatch", "final_content_verification", "chunk_failed_after_retries"];
        return codes.Contains(error.Message, StringComparer.Ordinal) ? error.Message : "io_or_validation";
    }
    private static async Task Stop()
    {
        Task? task;
        lock (gate) { active?.Cancellation.Cancel(); task = active?.Completion; }
        if (task is not null) await task;
    }
    private static async IAsyncEnumerable<string> ReadLines(Stream input)
    {
        var buffer = new byte[4096];
        using var pending = new MemoryStream();
        var utf8 = new UTF8Encoding(false, true);
        int n;
        while ((n = await input.ReadAsync(buffer)) > 0)
        {
            for (int i = 0; i < n; i++)
            {
                byte b = buffer[i];
                if (b == 10)
                {
                    string line;
                    try { line = utf8.GetString(pending.GetBuffer(), 0, (int)pending.Length).TrimEnd('\r'); }
                    catch (DecoderFallbackException) { throw new InvalidDataException("utf8"); }
                    pending.SetLength(0);
                    if (line.Length != 0) yield return line;
                }
                else
                {
                    if (pending.Length >= 65536) throw new InvalidDataException("line_limit");
                    pending.WriteByte(b);
                }
            }
        }
        if (pending.Length != 0) throw new InvalidDataException("truncated_line");
    }
}
