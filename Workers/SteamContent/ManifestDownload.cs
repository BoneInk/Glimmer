using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Glimmer.SteamContent;

internal sealed record VerifiedContentFile(string Path, long Length, string SHA256);

internal static class RuntimeFailureCodes
{
    internal static ContentFailure Classify(string phase, Exception error)
    {
        if (error is ContentFailure content) return content;
        string category = error switch
        {
            UnauthorizedAccessException => "access",
            IOException => "io",
            ObjectDisposedException => "disposed",
            InvalidOperationException => "state",
            ArgumentException => "argument",
            CryptographicException => "crypto",
            OutOfMemoryException => "memory",
            _ => "unexpected"
        };
        return new ContentFailure("scene_runtime_" + phase + "_" + category);
    }
}

internal sealed class RuntimeTransferBudget
{
    internal const long CapacityBytes = 128L * 1024 * 1024;
    private const int UnitBytes = 1024 * 1024;
    private readonly SemaphoreSlim units = new((int)(CapacityBytes / UnitBytes));
    private readonly SemaphoreSlim acquisition = new(1, 1);
    internal async ValueTask<IDisposable> Acquire(long bytes, CancellationToken token)
    {
        if (bytes is < 1 or > CapacityBytes) throw new ContentFailure("scene_runtime_memory_budget");
        int wanted = checked((int)((bytes + UnitBytes - 1) / UnitBytes)), held = 0;
        await acquisition.WaitAsync(token);
        try
        {
            for (; held < wanted; held++) await units.WaitAsync(token);
            return new Lease(units, wanted);
        }
        catch
        {
            if (held != 0) units.Release(held);
            throw;
        }
        finally { acquisition.Release(); }
    }
    private sealed class Lease(SemaphoreSlim units, int count) : IDisposable
    {
        private int released;
        public void Dispose() { if (Interlocked.Exchange(ref released, 1) == 0) units.Release(count); }
    }
}

internal sealed class ManagedContentDirectory : IDisposable
{
    private readonly SafeFileHandle root;
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int EntryCallback([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int directory);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_validate_content_tree(int directory, EntryCallback callback);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_open_private_root(string path);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_open_private_subdirectory(int parent, string name);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_open_content_file(int parent, string name);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_write_checkpoint(int parent, string temporary, byte[] bytes, int length);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_engine_cache_admit(int directory, string fingerprint, int maximum);
    internal ManagedContentDirectory(string path)
    {
        int fd = gw_open_private_root(Path.GetFullPath(path));
        if (fd < 0) throw new ContentFailure("workspace_not_private_canonical_directory");
        root = new(fd, true);
    }
    private ManagedContentDirectory(SafeFileHandle root) { this.root = root; }
    internal ManagedContentDirectory Directory(string path)
    {
        string normalized = AuthorizedManifest.ValidatePath(path);
        SafeFileHandle? current = null;
        try
        {
            foreach (string part in normalized.Split('/'))
            {
                int fd = gw_open_private_subdirectory((int)(current ?? root).DangerousGetHandle(), part);
                if (fd < 0) throw new ContentFailure("managed_directory_not_private_or_link");
                current?.Dispose(); current = new(fd, true);
            }
            return new(current!);
        }
        catch { current?.Dispose(); throw; }
    }
    internal SafeFileHandle File(string path)
    {
        string normalized = AuthorizedManifest.ValidatePath(path);
        int slash = normalized.LastIndexOf('/');
        using var parent = slash < 0 ? null : Directory(normalized[..slash]);
        int fd = gw_open_content_file((int)(parent?.root ?? root).DangerousGetHandle(), normalized[(slash+1)..]);
        if (fd < 0) throw new ContentFailure("managed_file_not_owned_regular");
        return new(fd, true);
    }
    internal void ValidateTree(AuthorizedManifest plan)
    {
        var expected = new Dictionary<string, bool>(StringComparer.Ordinal);
        void Include(string path, bool directory)
        {
            expected[path] = directory;
            int slash;
            while ((slash = path.LastIndexOf('/')) >= 0) { path = path[..slash]; expected.TryAdd(path, true); }
        }
        foreach (var f in plan.Files) Include(f.Path, false);
        foreach (var d in plan.Directories) Include(d, true);
        if (expected.Count > 40000) throw new ContentFailure("manifest_tree_limit");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        EntryCallback callback = (path, directory) => expected.TryGetValue(path, out var wanted) && wanted == (directory != 0) && seen.Add(path) ? 1 : 0;
        if (gw_validate_content_tree((int)root.DangerousGetHandle(), callback) != 0 || seen.Count != expected.Count)
            throw new ContentFailure("final_content_tree_mismatch");
        GC.KeepAlive(callback);
    }
    internal void Checkpoint(object checkpoint)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(checkpoint, Wire.Json);
        if (gw_write_checkpoint((int)root.DangerousGetHandle(), "checkpoint-" + Guid.NewGuid().ToString("N") + ".tmp", bytes, bytes.Length) != 0)
            throw new ContentFailure("checkpoint_write_failed");
    }
    internal void AdmitEngineCache(string fingerprint, int maximum = 8)
    {
        int result = gw_engine_cache_admit((int)root.DangerousGetHandle(), fingerprint, maximum);
        if (result == -2) throw new ContentFailure("engine_asset_cache_limit");
        if (result != 0) throw new ContentFailure("engine_asset_cache_invalid");
    }
    public void Dispose() => root.Dispose();
}

internal sealed class ManifestDownload(ISteamContentSession session, string workspace, Action<TransferCounters> progress)
{
    private long received, downloaded, reused, compressed, total, lastProgress, lastJournal;
    private readonly object reportGate = new();
    internal TransferCounters Counters => new(total.ToString(), Interlocked.Read(ref received).ToString(),
        Interlocked.Read(ref downloaded).ToString(), Interlocked.Read(ref reused).ToString(), Interlocked.Read(ref compressed).ToString());
    internal IReadOnlyList<VerifiedContentFile> VerifiedFiles { get; private set; } = [];
    internal async Task<string> Run(AuthorizedManifest plan, CancellationToken token, string? destination = null)
    {
        if (plan.SessionID != session.ID || !session.Authenticated) throw new ContentFailure("manifest_session_mismatch");
        total = plan.TotalBytes;
        string relative = destination is null ? $"items/{plan.PublishedFileID}/{plan.ManifestID}" : AuthorizedManifest.ValidatePath(destination);
        string expectedDestination = plan.Dataset == "scene_runtime_assets" ? $"scene-runtime-assets/{plan.Fingerprint}" : $"engine-assets/{plan.Fingerprint}";
        if (destination is not null && relative != expectedDestination)
            throw new ContentFailure("engine_asset_destination_invalid");
        using var root = new ManagedContentDirectory(workspace);
        if (destination is not null) { using var cache = root.Directory(plan.Dataset == "scene_runtime_assets" ? "scene-runtime-assets" : "engine-assets"); cache.AdmitEngineCache(plan.Fingerprint); }
        using var item = root.Directory(relative);
        using var content = item.Directory("content");
        var completed = new List<int>();
        var journalGate = new object();
        void Save(bool force)
        {
            try
            {
                lock (journalGate)
                {
                    long now = Environment.TickCount64;
                    if (!force && now - lastJournal < 1000) return;
                    lastJournal = now;
                    int[] snapshot = completed.Order().ToArray();
                    // Deliberately no depot key, token, URL, username or source path. The journal is only a hint;
                    // resume always reads and hashes actual bytes before advertising any reused completion.
                    object checkpoint = plan.PublishedFileID == 0
                        ? new { v = 1, kind = plan.Dataset, appID = 431960, depotID = plan.DepotID,
                            manifestID = plan.ManifestID.ToString(), planFingerprint = plan.Fingerprint, completedChunkIndices = snapshot }
                        : new { v = 1, kind = "workshop", appID = 431960, publishedFileID = plan.PublishedFileID.ToString(),
                            depotID = plan.DepotID, manifestID = plan.ManifestID.ToString(), planFingerprint = plan.Fingerprint,
                            completedChunkIndices = snapshot };
                    item.Checkpoint(checkpoint);
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (plan.Dataset == "scene_runtime_assets") { throw RuntimeFailureCodes.Classify("checkpoint", error); }
        }
        void Completed(int index) { lock (journalGate) completed.Add(index); }
        try
        {
            foreach (string directory in plan.Directories) { token.ThrowIfCancellationRequested(); using var _ = content.Directory(directory); }
            Save(true);
            var verifiedFiles = new List<VerifiedContentFile>(plan.Files.Count);
            async Task TransferFile(DepotFileEntry file, RuntimeTransferBudget? budget, CancellationToken transferToken)
            {
                transferToken.ThrowIfCancellationRequested();
                using var output = content.File(file.Path);
                // Preallocation/length changes are never counted. Hashes below are the only reuse proof.
                if (RandomAccess.GetLength(output) > file.Length) throw new ContentFailure("existing_content_length_changed");
                foreach (var chunk in file.Chunks)
                {
                    transferToken.ThrowIfCancellationRequested();
                    using var lease = budget is null ? null : await budget.Acquire((long)chunk.Length + chunk.CompressedLength, transferToken);
                    var buffer = new byte[chunk.Length];
                    bool valid = await ReadExact(output, buffer, chunk.Offset, transferToken) && Verify(buffer, chunk.SHA1);
                    if (valid) Interlocked.Add(ref reused, chunk.Length);
                    else
                    {
                        await session.DownloadChunk(plan, chunk, buffer, n => { Interlocked.Add(ref received, n); Report(false); }, transferToken);
                        transferToken.ThrowIfCancellationRequested();
                        if (!Verify(buffer, chunk.SHA1)) throw new ContentFailure("downloaded_chunk_hash_mismatch");
                        await RandomAccess.WriteAsync(output, buffer, chunk.Offset, transferToken);
                        RandomAccess.FlushToDisk(output);
                        transferToken.ThrowIfCancellationRequested();
                        Interlocked.Add(ref downloaded, chunk.Length); Interlocked.Add(ref compressed, chunk.CompressedLength);
                    }
                    Completed(chunk.Index); Report(false); Save(false);
                }
                transferToken.ThrowIfCancellationRequested();
                if (RandomAccess.GetLength(output) != file.Length) throw new ContentFailure("final_file_length");
                RandomAccess.FlushToDisk(output);
            }
            if (plan.Dataset == "scene_runtime_assets")
            {
                using var workersCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
                var budget = new RuntimeTransferBudget(); int next = -1;
                ExceptionDispatchInfo? failure = null;
                async Task Worker()
                {
                    try
                    {
                        while (true)
                        {
                            int index = Interlocked.Increment(ref next);
                            if (index >= plan.Files.Count) return;
                            await TransferFile(plan.Files[index], budget, workersCancellation.Token);
                        }
                    }
                    catch (Exception error)
                    {
                        if (error is not (ContentFailure or OperationCanceledException))
                            error = RuntimeFailureCodes.Classify("transfer", error);
                        if (Interlocked.CompareExchange(ref failure, ExceptionDispatchInfo.Capture(error), null) is null)
                            workersCancellation.Cancel();
                    }
                }
                var workers = Enumerable.Range(0, Math.Min(8, plan.Files.Count)).Select(_ => Worker()).ToArray();
                await Task.WhenAll(workers);
                token.ThrowIfCancellationRequested(); failure?.Throw();
            }
            else
                foreach (var file in plan.Files) await TransferFile(file, null, token);
            // Whole-file hashes run only after ALL writes, so case/normalization aliases or a later
            // file write cannot invalidate a previously accepted earlier file unnoticed.
            try { foreach (var file in plan.Files)
            {
                token.ThrowIfCancellationRequested();
                using var output = content.File(file.Path);
                if (RandomAccess.GetLength(output) != file.Length) throw new ContentFailure("final_file_length");
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
                using var sha256 = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                byte[] block = new byte[65536]; long offset = 0;
                while (offset < file.Length)
                {
                    int n = await RandomAccess.ReadAsync(output, block.AsMemory(0, (int)Math.Min(block.Length, file.Length-offset)), offset, token);
                    if (n == 0) throw new ContentFailure("final_file_truncated");
                    hash.AppendData(block, 0, n); sha256.AppendData(block, 0, n); offset += n;
                }
                if (!CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(file.SHA1)))
                    throw new ContentFailure("final_file_hash");
                verifiedFiles.Add(new(file.Path, file.Length, Convert.ToHexString(sha256.GetHashAndReset()).ToLowerInvariant()));
            } }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (plan.Dataset == "scene_runtime_assets") { throw RuntimeFailureCodes.Classify("validation", error); }
            token.ThrowIfCancellationRequested(); content.ValidateTree(plan); VerifiedFiles = verifiedFiles.AsReadOnly(); Save(true); Report(true);
            return relative + "/content";
        }
        finally
        {
            try { Save(true); }
            finally { CryptographicOperations.ZeroMemory(plan.DepotKey); }
        }
    }
    private static bool Verify(byte[] value, string hash) => CryptographicOperations.FixedTimeEquals(SHA1.HashData(value), Convert.FromHexString(hash));
    private static async Task<bool> ReadExact(SafeFileHandle file, byte[] buffer, long offset, CancellationToken token)
    {
        int count = 0;
        while (count < buffer.Length)
        {
            int n = await RandomAccess.ReadAsync(file, buffer.AsMemory(count), offset+count, token);
            if (n == 0) return false;
            count += n;
        }
        return true;
    }
    private void Report(bool force)
    {
        lock (reportGate)
        {
            long now = Environment.TickCount64; if (!force && now-lastProgress < 200) return;
            lastProgress = now; progress(Counters);
        }
    }
}
