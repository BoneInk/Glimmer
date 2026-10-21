using System.Text.Json;
using System.Text.Json.Serialization;

namespace Glimmer.SteamContent;

// UInt64 counters are decimal strings on the wire. JSON numbers lose precision in JS clients.
internal sealed record ChunkSpec(string File, long Offset, int Length, string Sha1, string Url,
    int? CompressedLength = null, string? DepotKey = null, uint? Adler32 = null);
internal sealed record TransferPlan(string JobID, ulong Epoch, uint AppID, string PublishedFileID,
    string ManifestID, uint DepotID, IReadOnlyList<ChunkSpec> Chunks);
internal sealed record EngineJob(string JobID, ulong Epoch, string? ManifestID = null, uint? DepotID = null);
internal sealed record Command(int V, string CommandName, string RequestID, string? JobID = null,
    ulong? Epoch = null, TransferPlan? Plan = null, string? SessionID = null, AuthRequest? Auth = null,
    AuthResponse? Response = null, string? PublishedFileID = null, uint? AppID = null,
    IReadOnlyList<string>? DesiredResources = null, bool? InspectOnly = null);
internal sealed class Wire
{
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    private readonly string nonce = Guid.NewGuid().ToString("N");
    private long seq;
    private readonly object gate = new();
    internal void Emit(string kind, string requestID, TransferPlan? p = null, object? detail = null)
    {
        lock (gate)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { v = 1, sessionNonce = nonce, seq = ++seq,
                kind, requestID, jobID = p?.JobID, epoch = p?.Epoch.ToString(), appID = p?.AppID,
                publishedFileID = p?.PublishedFileID, manifestID = p?.ManifestID, depotID = p?.DepotID, detail }, Json));
        }
    }
    internal void EmitEngine(string kind, string requestID, EngineJob p, object? detail = null)
    {
        lock (gate)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { v = 1, sessionNonce = nonce, seq = ++seq,
                kind, requestID, jobID = p.JobID, epoch = p.Epoch.ToString(), appID = EngineAssetCatalog.AppID,
                publishedFileID = (string?)null, manifestID = p.ManifestID, depotID = p.DepotID, detail }, Json));
        }
    }
}
