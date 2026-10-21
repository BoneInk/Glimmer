using System.Security.Cryptography;
using System.Text;
using SteamKit2;
using SteamKit2.Internal;

namespace Glimmer.SteamContent;

internal sealed record DepotChunkEntry(int Index, string Path, long Offset, int Length, int CompressedLength, string SHA1, uint Adler32)
{
    internal DepotManifest.ChunkData SDK => new(Convert.FromHexString(SHA1), Adler32, (ulong)Offset, (uint)CompressedLength, (uint)Length);
}
internal sealed record DepotFileEntry(string Path, long Length, string SHA1, IReadOnlyList<DepotChunkEntry> Chunks);
internal sealed class AuthorizedManifest
{
    internal string SessionID { get; }
    internal ulong PublishedFileID { get; }
    internal uint DepotID { get; }
    internal ulong ManifestID { get; }
    internal IReadOnlyList<DepotFileEntry> Files { get; }
    internal IReadOnlyList<string> Directories { get; }
    internal string Fingerprint { get; }
    internal string Dataset { get; }
    internal long TotalBytes { get; }
    internal byte[] DepotKey { get; }
    internal IReadOnlyList<SteamKit2.CDN.Server> Servers { get; }
    // Internal only: this type is never deserialized from stdin or a checkpoint. Its factory accepts
    // the matched CM details, expected IDs and SDK manifest from the SAME authenticated session.
    private AuthorizedManifest(string session, ulong item, uint depot, ulong manifest, List<DepotFileEntry> files,
        List<string> directories, byte[] key, IReadOnlyList<SteamKit2.CDN.Server> servers, string dataset)
    {
        SessionID = session; PublishedFileID = item; DepotID = depot; ManifestID = manifest;
        Files = files.AsReadOnly(); Directories = directories.AsReadOnly(); DepotKey = key.ToArray(); Servers = servers;
        TotalBytes = files.Sum(f => f.Length); Dataset = dataset;
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Add(string value) { hash.AppendData(Encoding.UTF8.GetBytes(value)); hash.AppendData([0]); }
        Add("431960"); Add(item.ToString()); Add(depot.ToString()); Add(manifest.ToString());
        foreach (var file in files.OrderBy(f => f.Path, StringComparer.Ordinal))
        {
            Add(file.Path); Add(file.Length.ToString()); Add(file.SHA1);
            foreach (var chunk in file.Chunks) { Add(chunk.Offset.ToString()); Add(chunk.SHA1); Add(chunk.Length.ToString()); Add(chunk.CompressedLength.ToString()); Add(chunk.Adler32.ToString()); }
        }
        Fingerprint = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
    internal static void CheckDetails(PublishedFileDetails details, ulong requested)
    {
        if (details.result != (uint)EResult.OK || details.publishedfileid != requested || details.consumer_appid != 431960 || details.banned)
            throw new ContentFailure("ugc_not_authorized_or_wrong_item");
        if (details.file_type != 0 || details.children.Count != 0) throw new ContentFailure("ugc_collection_or_filetype_not_supported");
        if (!string.IsNullOrEmpty(details.file_url)) throw new ContentFailure("legacy_ugc_http_not_supported");
        if (details.hcontent_file == 0) throw new ContentFailure("ugc_manifest_missing");
    }
    internal static AuthorizedManifest FromSDK(string session, PublishedFileDetails details, ulong requested, uint depot,
        DepotManifest manifest, byte[] key, IReadOnlyList<SteamKit2.CDN.Server> servers)
    {
        CheckDetails(details, requested);
        return FromManifest(session, requested, depot, details.hcontent_file, manifest, key, servers, null, "workshop");
    }
    internal static AuthorizedManifest FromAppDepot(string session, uint depot, ulong expectedManifest,
        DepotManifest manifest, byte[] key, IReadOnlyList<SteamKit2.CDN.Server> servers, IReadOnlySet<string> selectedPaths)
    {
        if (selectedPaths.Count is < 1 or > 32 || selectedPaths.Any(p => ValidatePath(p) != p))
            throw new ContentFailure("engine_asset_selection_invalid");
        return FromManifest(session, 0, depot, expectedManifest, manifest, key, servers, selectedPaths, "scene_engine_assets");
    }
    internal static AuthorizedManifest FromSceneRuntimeAssets(string session, uint depot, ulong expectedManifest,
        DepotManifest manifest, byte[] key, IReadOnlyList<SteamKit2.CDN.Server> servers)
    {
        EngineManifestInventory inventory;
        try { inventory = EngineManifestInventoryBuilder.Build([(depot, expectedManifest, manifest)]); }
        catch (ContentFailure error) when (error.Code == "engine_inventory_manifest_invalid") { throw new ContentFailure("scene_runtime_manifest_invalid"); }
        catch (ContentFailure error) when (error.Code == "engine_inventory_limit") { throw new ContentFailure("scene_runtime_manifest_limit"); }
        var selected = inventory.Files.Select(file => file.ManifestPath).ToHashSet(StringComparer.Ordinal);
        if (selected.Count is < 1 or > 4096) throw new ContentFailure("scene_runtime_manifest_limit");
        return FromManifest(session, 0, depot, expectedManifest, manifest, key, servers, selected, "scene_runtime_assets",
            maximumSelectedFiles: 4096, maximumSelectedBytes: 128L * 1024 * 1024, maximumSelectedFileBytes: 16L * 1024 * 1024);
    }
    private static AuthorizedManifest FromManifest(string session, ulong item, uint depot, ulong expectedManifest,
        DepotManifest manifest, byte[] key, IReadOnlyList<SteamKit2.CDN.Server> servers, IReadOnlySet<string>? selectedPaths,
        string dataset, int maximumSelectedFiles = 32, long maximumSelectedBytes = 64L * 1024 * 1024,
        long maximumSelectedFileBytes = 2L * 1024 * 1024 * 1024)
    {
        if (!Guid.TryParse(session, out _) || depot == 0 || key.Length != 32 || manifest.DepotID != depot ||
            manifest.ManifestGID != expectedManifest || manifest.FilenamesEncrypted || manifest.Files is null || manifest.Files.Count is < 1 or > 20000)
            throw new ContentFailure("manifest_identity_or_limit");
        if (servers.Count is < 1 or > 16 || servers.Any(s => !CDNBoundary.ValidServer(s))) throw new ContentFailure("cdn_servers_not_authorized");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new List<DepotFileEntry>(); var directories = new List<string>();
        int index = 0; long total = 0;
        foreach (var source in manifest.Files)
        {
            string path = ValidatePath(source.FileName);
            if (selectedPaths is not null && !selectedPaths.Contains(path)) continue;
            if (!paths.Add(path) || !string.IsNullOrEmpty(source.LinkTarget)) throw new ContentFailure("manifest_duplicate_or_link");
            if ((source.Flags & EDepotFileFlag.Symlink) != 0 || source.Chunks is null) throw new ContentFailure("manifest_file_invalid");
            bool directory = (source.Flags & EDepotFileFlag.Directory) != 0;
            if (directory)
            {
                if (source.Chunks.Count != 0 || source.TotalSize != 0) throw new ContentFailure("manifest_directory_data");
                directories.Add(path); continue;
            }
            // Executable/hidden/read-only file metadata is not acted upon. Explicit link flags/targets
            // never become links. No Unix mode or OS executable bit is imported from the manifest.
            if ((source.Flags & EDepotFileFlag.Symlink) != 0 || source.FileHash?.Length != 20 || source.Chunks.Count > 32768)
                throw new ContentFailure("manifest_file_invalid");
            if (source.TotalSize > 2UL * 1024 * 1024 * 1024 || (total = checked(total + (long)source.TotalSize)) > 2L * 1024 * 1024 * 1024)
                throw new ContentFailure("manifest_size_limit");
            var chunks = new List<DepotChunkEntry>(); ulong offset = 0;
            foreach (var c in source.Chunks.OrderBy(c => c.Offset))
            {
                if (c.ChunkID?.Length != 20 || c.Offset != offset || c.UncompressedLength is 0 or > 16 * 1024 * 1024 ||
                    c.CompressedLength is 0 or > 20 * 1024 * 1024 || ++index > 32768)
                    throw new ContentFailure("manifest_chunk_invalid");
                offset = checked(offset + c.UncompressedLength);
                chunks.Add(new(index - 1, path, (long)c.Offset, (int)c.UncompressedLength, (int)c.CompressedLength,
                    Convert.ToHexString(c.ChunkID).ToLowerInvariant(), c.Checksum));
            }
            if (offset != source.TotalSize) throw new ContentFailure("manifest_chunk_coverage");
            files.Add(new(path, (long)source.TotalSize, Convert.ToHexString(source.FileHash).ToLowerInvariant(), chunks.AsReadOnly()));
        }
        if (files.Count == 0) throw new ContentFailure("manifest_no_files");
        if (selectedPaths is not null && (selectedPaths.Count < 1 || selectedPaths.Count > maximumSelectedFiles ||
            !files.Select(f => f.Path).ToHashSet(StringComparer.Ordinal).SetEquals(selectedPaths)))
            throw new ContentFailure("engine_assets_not_found");
        if (selectedPaths is not null && (total > maximumSelectedBytes || files.Any(f => f.Length > maximumSelectedFileBytes)))
            throw new ContentFailure(dataset == "scene_runtime_assets" ? "scene_runtime_manifest_limit" : "engine_asset_size_limit");
        // Reject an explicit file used as an ancestor, case collisions included (typical macOS volume).
        var fileNames = files.Select(f => f.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (string path in paths)
        {
            var components = path.Split('/'); string prefix = "";
            foreach (string component in components.Take(components.Length - 1))
            { prefix = prefix.Length == 0 ? component : prefix + "/" + component; if (fileNames.Contains(prefix)) throw new ContentFailure("manifest_file_parent"); }
        }
        var allNodes = new HashSet<string>(paths, StringComparer.OrdinalIgnoreCase);
        foreach (string path in paths)
        {
            string parent = path; int slash;
            while ((slash = parent.LastIndexOf('/')) >= 0)
            { parent = parent[..slash]; allNodes.Add(parent); if (allNodes.Count > 40000) throw new ContentFailure("manifest_tree_limit"); }
        }
        index = 0;
        files = files.OrderBy(f => f.Path, StringComparer.Ordinal).Select(f => f with
        { Chunks = f.Chunks.Select(c => c with { Index = index++ }).ToList().AsReadOnly() }).ToList();
        return new(session, item, depot, expectedManifest, files, directories, key, servers, dataset);
    }
    internal static string ValidatePath(string? value)
    {
        // Steam manifests conventionally use backslash on Windows; normalize only that separator.
        if (string.IsNullOrEmpty(value) || value.Length > 1024 || value.StartsWith('/') || value.StartsWith('\\') || value.Any(char.IsControl))
            throw new ContentFailure("manifest_path_invalid");
        string path = value.Replace('\\', '/'); var parts = path.Split('/');
        if (parts.Length > 32 || parts.Any(p => p.Length is 0 or > 200 || p is "." or ".." || p.Contains(':') || p.EndsWith('.') || p.EndsWith(' ') || p.Normalize(NormalizationForm.FormC) != p))
            throw new ContentFailure("manifest_path_invalid");
        return path;
    }
}

internal static class CDNBoundary
{
    internal static bool ValidServer(SteamKit2.CDN.Server s) => s.Protocol == SteamKit2.CDN.Server.ConnectionProtocol.HTTPS &&
        s.Port == 443 && !s.UseAsProxy && s.Type is "CDN" or "SteamCache" &&
        ValidDNS(s.VHost) && ValidDNS(s.Host) && (s.AllowedAppIds is null || s.AllowedAppIds.Length == 0 || s.AllowedAppIds.Contains(431960u));
    internal static bool ValidDNS(string? name) => name is { Length: > 3 and <= 253 } && name.Contains('.') &&
        !name.EndsWith(".local", StringComparison.OrdinalIgnoreCase) && !name.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase) &&
        name.Split('.').All(p => p.Length is > 0 and <= 63 && char.IsAsciiLetterOrDigit(p[0]) && char.IsAsciiLetterOrDigit(p[^1]) && p.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')) &&
        !System.Net.IPAddress.TryParse(name, out _);
}
