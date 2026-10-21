using System.Globalization;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using SteamKit2;

namespace Glimmer.SteamContent;

internal sealed record TransferCounters(string LogicalTotalBytes, string ReceivedPayloadBytes,
    string DownloadedVerifiedBytes, string ReusedVerifiedBytes, string SuccessfulCompressedPayloadBytes);

// Transport accepts an explicitly authorized immutable plan. It never discovers authorization from a URL
// or from SteamCMD files. The CLI exposes plans ONLY in isolated loopback fixture mode for this phase.
internal sealed class TransferEngine(HttpClient client, string workspace, Action<TransferCounters> progress)
{
    private long received, downloaded, reused, compressed;
    private long lastProgress;
    private long total;
    private string root = "";
    private readonly Dictionary<string, SafeFileHandle> files = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> lengths = new(StringComparer.Ordinal);
    internal TransferCounters Counters => new(S(total), S(received), S(downloaded), S(reused), S(compressed));
    private static string S(long n) => n.ToString(CultureInfo.InvariantCulture);
    internal static void Validate(TransferPlan p)
    {
        if (!Guid.TryParseExact(p.JobID, "D", out _) || p.Epoch == 0 || p.AppID != 431960 ||
            !ulong.TryParse(p.PublishedFileID, out var id) || id == 0 ||
            !ulong.TryParse(p.ManifestID, out var manifest) || manifest == 0 || p.DepotID == 0 ||
            p.Chunks is null || p.Chunks.Count is < 1 or > 8192) throw new InvalidDataException("invalid_plan");
        long size = 0;
        var ends = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var c in p.Chunks)
        {
            // This initial transport uses flat opaque file names. Steam manifest paths need a separate
            // no-follow component walker before native multi-directory production plans are enabled.
            if (c is null || string.IsNullOrEmpty(c.File) || c.File.Length > 128 || c.File is "." or ".." || c.File.Any(x => !(char.IsAsciiLetterOrDigit(x) || x is '.' or '-' or '_')) ||
                c.Offset < 0 || c.Length is < 1 or > 16 * 1024 * 1024 || c.Sha1 is null || c.Sha1.Length != 40 ||
                !c.Sha1.All(Uri.IsHexDigit) || c.CompressedLength is <= 0 or > 20 * 1024 * 1024 ||
                c.Offset != ends.GetValueOrDefault(c.File) ||
                !Uri.TryCreate(c.Url, UriKind.Absolute, out var uri) || !uri.IsLoopback || uri.Scheme != "http" ||
                !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment)) throw new InvalidDataException("invalid_chunk");
            if (c.DepotKey is not null && (c.DepotKey.Length != 64 || !c.DepotKey.All(Uri.IsHexDigit) || c.Adler32 is null || c.CompressedLength is null))
                throw new InvalidDataException("invalid_depot_key");
            ends[c.File] = checked(c.Offset + c.Length); size = checked(size + c.Length);
            if (size > 2L * 1024 * 1024 * 1024) throw new InvalidDataException("plan_limit");
        }
    }
    internal async Task RunAsync(TransferPlan p, CancellationToken token)
    {
        Validate(p);
        total = p.Chunks.Sum(x => (long)x.Length);
        root = Path.Combine(workspace, p.JobID, p.ManifestID);
        // Root is supplied by native launcher, never by stdin. Reject all pre-existing symlink components.
        SecurePaths.EnsureDirectory(root);
        try
        {
            foreach (var c in p.Chunks) lengths[c.File] = Math.Max(lengths.GetValueOrDefault(c.File), c.Offset + c.Length);
            foreach (var name in lengths.Keys) files[name] = SecurePaths.OpenFile(Path.Combine(root, name));
            foreach (var c in p.Chunks)
            {
                token.ThrowIfCancellationRequested();
                var handle = files[c.File];
                var existing = new byte[c.Length];
                int n = await RandomAccess.ReadAsync(handle, existing, c.Offset, token);
                if (n == c.Length && Verify(existing, c))
                {
                    reused += c.Length; Report(force: false); continue;
                }
                byte[]? content = null;
                int payload = 0;
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    token.ThrowIfCancellationRequested();
                    try
                    {
                        var bytes = await Receive(c, token);
                        payload = bytes.Length;
                        content = Decode(bytes, c);
                        if (!Verify(content, c)) throw new InvalidDataException("chunk_checksum");
                        break;
                    }
                    catch (Exception e) when (e is HttpRequestException or IOException or InvalidDataException && !token.IsCancellationRequested)
                    {
                        if (attempt == 2) throw new IOException("chunk_failed_after_retries", e);
                        await Task.Delay(TimeSpan.FromMilliseconds(30 * (attempt + 1)), token);
                    }
                }
                token.ThrowIfCancellationRequested();
                await RandomAccess.WriteAsync(handle, content!, c.Offset, token);
                // Flush is deliberately before committing a verified chunk counter. A failed write/flush
                // never advertises logical completion, even if an earlier network response was valid.
                RandomAccess.FlushToDisk(handle);
                token.ThrowIfCancellationRequested();
                downloaded += c.Length; compressed += payload; Report(force: false);
            }
            token.ThrowIfCancellationRequested();
            foreach (var (name, handle) in files)
            {
                if (RandomAccess.GetLength(handle) != lengths[name]) throw new IOException("file_length_mismatch");
                RandomAccess.FlushToDisk(handle);
            }
            // Revalidate all disk chunks; resume hints, file length and allocation are never evidence.
            foreach (var c in p.Chunks)
            {
                var bytes = new byte[c.Length];
                if (await RandomAccess.ReadAsync(files[c.File], bytes, c.Offset, token) != c.Length || !Verify(bytes, c))
                    throw new IOException("final_content_verification");
            }
            token.ThrowIfCancellationRequested();
            Report(force: true);
        }
        finally { foreach (var h in files.Values) h.Dispose(); files.Clear(); }
    }
    private async Task<byte[]> Receive(ChunkSpec c, CancellationToken token)
    {
        using var response = await client.GetAsync(c.Url, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        int limit = c.CompressedLength ?? c.Length;
        if (response.Content.Headers.ContentLength is long expected && expected != limit) throw new InvalidDataException("payload_length_header");
        await using var input = await response.Content.ReadAsStreamAsync(token);
        using var bytes = new MemoryStream(limit);
        byte[] buffer = new byte[32768];
        while (true)
        {
            int n = await input.ReadAsync(buffer, token);
            if (n == 0) break;
            received = checked(received + n); Report(force: false);
            if (bytes.Length + n > limit) throw new InvalidDataException("payload_limit");
            bytes.Write(buffer, 0, n);
        }
        if (bytes.Length != limit) throw new InvalidDataException("payload_length");
        return bytes.ToArray();
    }
    private static byte[] Decode(byte[] bytes, ChunkSpec c)
    {
        if (c.DepotKey is null) return bytes;
        var chunk = new DepotManifest.ChunkData { ChunkID = Convert.FromHexString(c.Sha1),
            Checksum = c.Adler32!.Value, Offset = (ulong)c.Offset,
            CompressedLength = (uint)c.CompressedLength!.Value, UncompressedLength = (uint)c.Length };
        var result = new byte[c.Length];
        int n = SteamKit2.CDN.DepotChunk.Process(chunk, bytes, result, Convert.FromHexString(c.DepotKey));
        if (n != c.Length) throw new InvalidDataException("decoded_length");
        return result;
    }
    private static bool Verify(byte[] bytes, ChunkSpec c) => bytes.Length == c.Length &&
        CryptographicOperations.FixedTimeEquals(SHA1.HashData(bytes), Convert.FromHexString(c.Sha1));
    private void Report(bool force)
    {
        long now = Environment.TickCount64;
        if (!force && now - lastProgress < 200) return;
        lastProgress = now; progress(Counters);
    }
}

internal static class SecurePaths
{
    // macOS constants; this build is exclusively osx-arm64. O_NOFOLLOW prevents leaf substitution.
    private const int NoFollow = 0x100, CloseOnExec = 0x1000000, NonBlock = 4, DirectoryFlag = 0x100000;
    [DllImport("libc", SetLastError = true)] private static extern int openat(int dir, string path, int flags, int mode);
    [DllImport("GlimmerSteamContentNative", SetLastError = true)] private static extern int gw_open_content_file(int directory, string name);
    [DllImport("libc", SetLastError = true)] private static extern int open(string path, int flags, int mode);
    internal static void EnsureDirectory(string path)
    {
        string full = Path.GetFullPath(path);
        string current = Path.GetPathRoot(full)!;
        foreach (string part in full.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            var info = new DirectoryInfo(current);
            if (info.LinkTarget is not null) throw new IOException("symlink_directory");
            if (!Directory.Exists(current)) Directory.CreateDirectory(current, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("symlink_directory");
        }
    }
    internal static SafeFileHandle OpenFile(string path)
    {
        using var directory = OpenDirectory(Path.GetDirectoryName(path)!);
        int fd = gw_open_content_file((int)directory.DangerousGetHandle(), Path.GetFileName(path)); //0600, no truncation
        if (fd < 0) throw new IOException("open_destination_failed");
        var handle = new SafeFileHandle(fd, ownsHandle: true);
        return handle; // C shim has already fstat-validated regular/current-user/single-link on this FD.
    }
    private static SafeFileHandle OpenDirectory(string path)
    {
        var current = new SafeFileHandle(open("/", DirectoryFlag | NoFollow | CloseOnExec, 0), true);
        try
        {
            foreach (string part in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
            {
                int next = openat((int)current.DangerousGetHandle(), part, DirectoryFlag | NoFollow | CloseOnExec | NonBlock, 0);
                if (next < 0) throw new IOException("directory_anchor_changed");
                current.Dispose(); current = new SafeFileHandle(next, true);
            }
            return current;
        }
        catch { current.Dispose(); throw; }
    }
}
