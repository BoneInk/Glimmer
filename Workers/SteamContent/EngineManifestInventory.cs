using System.Security.Cryptography;
using System.Text;
using SteamKit2;

namespace Glimmer.SteamContent;

internal sealed record InventoryManifest(uint DepotID, ulong ManifestID);
internal sealed record InventoryFile(string LogicalPath, string ManifestPath, uint DepotID, ulong ManifestID,
    ulong SizeBytes, string SHA1, string Category, string Extension, bool ArchiveCandidate);
internal sealed record InventoryGroup(string Category, int FileCount, ulong TotalBytes, ulong MaximumFileBytes);
internal sealed record EngineManifestInventory(bool Complete, IReadOnlyList<InventoryManifest> Manifests,
    IReadOnlyList<InventoryFile> Files, IReadOnlyList<InventoryGroup> Groups, IReadOnlyList<InventoryGroup> Extensions,
    int TotalFileCount, ulong TotalBytes, ulong MaximumFileBytes,
    int ExcludedExecutableCount, ulong ExcludedExecutableBytes, string ReportSHA256);

/// Builds a diagnostic metadata inventory only. It never selects or downloads content chunks.
internal static class EngineManifestInventoryBuilder
{
    private static readonly HashSet<string> resourceRoots = new(StringComparer.Ordinal)
        { "shaders", "effects", "materials", "particles", "fonts", "scripts", "models" };
    private static readonly HashSet<string> forbiddenExtensions = new(StringComparer.OrdinalIgnoreCase)
        { ".exe", ".dll", ".dylib", ".so" };
    internal const int MaximumFiles = 20_000;
    internal const int MaximumReportPathBytes = 4 * 1024 * 1024;

    internal static EngineManifestInventory Build(IEnumerable<(uint DepotID, ulong ManifestID, DepotManifest Manifest)> sourceManifests)
    {
        var files = new List<InventoryFile>();
        var manifests = new List<InventoryManifest>();
        var identities = new HashSet<(uint, ulong)>();
        var entries = new HashSet<(uint, ulong, string)>();
        var pathBytes = 0; var excludedCount = 0; ulong excludedBytes = 0;
        foreach (var value in sourceManifests)
        {
            if (value.DepotID == 0 || value.ManifestID == 0 || value.Manifest.DepotID != value.DepotID ||
                value.Manifest.ManifestGID != value.ManifestID || value.Manifest.FilenamesEncrypted ||
                value.Manifest.Files is null || value.Manifest.Files.Count > MaximumFiles ||
                !identities.Add((value.DepotID, value.ManifestID)))
                throw new ContentFailure("engine_inventory_manifest_invalid");
            manifests.Add(new(value.DepotID, value.ManifestID));
            foreach (var source in value.Manifest.Files)
            {
                string path = AuthorizedManifest.ValidatePath(source.FileName);
                if ((source.Flags & EDepotFileFlag.Directory) != 0) continue;
                if ((source.Flags & EDepotFileFlag.Symlink) != 0 || !string.IsNullOrEmpty(source.LinkTarget) ||
                    source.FileHash?.Length != 20 || source.TotalSize > 2UL * 1024 * 1024 * 1024)
                    throw new ContentFailure("engine_inventory_manifest_invalid");
                if (path.StartsWith("assets/", StringComparison.OrdinalIgnoreCase) &&
                    !path.StartsWith("assets/", StringComparison.Ordinal))
                    throw new ContentFailure("engine_inventory_manifest_invalid");
                if (!path.StartsWith("assets/", StringComparison.Ordinal)) continue;
                string extension = Path.GetExtension(path).ToLowerInvariant();
                if (forbiddenExtensions.Contains(extension))
                {
                    excludedCount = checked(excludedCount + 1);
                    excludedBytes = checked(excludedBytes + source.TotalSize);
                    continue;
                }
                if (!entries.Add((value.DepotID, value.ManifestID, path)))
                    throw new ContentFailure("engine_inventory_manifest_invalid");
                pathBytes = checked(pathBytes + Encoding.UTF8.GetByteCount(path));
                if (files.Count >= MaximumFiles || pathBytes > MaximumReportPathBytes)
                    throw new ContentFailure("engine_inventory_limit");
                string logical = path["assets/".Length..];
                int slash = logical.IndexOf('/');
                string first = slash < 0 ? "" : logical[..slash];
                string category = slash < 0 ? "assets-root" : resourceRoots.Contains(first) ? first : "other-assets";
                files.Add(new(logical, path, value.DepotID, value.ManifestID, source.TotalSize,
                    Convert.ToHexString(source.FileHash).ToLowerInvariant(), category,
                    extension.Length == 0 ? "(none)" : extension, extension == ".pkg"));
            }
        }
        if (manifests.Count == 0) throw new ContentFailure("engine_inventory_manifest_invalid");
        manifests.Sort((a,b) => a.DepotID != b.DepotID ? a.DepotID.CompareTo(b.DepotID) : a.ManifestID.CompareTo(b.ManifestID));
        files.Sort((a, b) => { int p = StringComparer.Ordinal.Compare(a.ManifestPath, b.ManifestPath); if (p != 0) return p;
            int d = a.DepotID.CompareTo(b.DepotID); return d != 0 ? d : a.ManifestID.CompareTo(b.ManifestID); });
        static InventoryGroup Make(IGrouping<string, InventoryFile> group) => new(group.Key, group.Count(),
            group.Aggregate(0UL, (sum, file) => checked(sum + file.SizeBytes)), group.Max(file => file.SizeBytes));
        var groups = files.GroupBy(f => f.Category, StringComparer.Ordinal).Select(Make).OrderBy(g => g.Category, StringComparer.Ordinal).ToArray();
        var extensions = files.GroupBy(f => f.Extension, StringComparer.Ordinal).Select(Make).OrderBy(g => g.Category, StringComparer.Ordinal).ToArray();
        ulong total = files.Aggregate(0UL, (sum, file) => checked(sum + file.SizeBytes));
        ulong maximum = files.Count == 0 ? 0 : files.Max(file => file.SizeBytes);
        string hash = Hash(manifests, files, groups, extensions, excludedCount, excludedBytes);
        return new(true, manifests.AsReadOnly(), files.AsReadOnly(), groups, extensions, files.Count, total, maximum,
            excludedCount, excludedBytes, hash);
    }

    internal static string Hash(IEnumerable<InventoryManifest> manifests, IEnumerable<InventoryFile> files,
        IEnumerable<InventoryGroup> groups, IEnumerable<InventoryGroup> extensions, int excludedCount, ulong excludedBytes)
    {
        var text = new StringBuilder("gw-engine-inventory-v1\n");
        foreach (var m in manifests) text.Append("m\0").Append(m.DepotID).Append('\0').Append(m.ManifestID).Append('\n');
        foreach (var f in files) text.Append("f\0").Append(f.LogicalPath).Append('\0').Append(f.ManifestPath).Append('\0')
            .Append(f.DepotID).Append('\0').Append(f.ManifestID).Append('\0').Append(f.SizeBytes).Append('\0')
            .Append(f.SHA1).Append('\0').Append(f.Category).Append('\0').Append(f.Extension).Append('\0')
            .Append(f.ArchiveCandidate ? '1' : '0').Append('\n');
        foreach (var g in groups) AppendGroup(text, "g", g);
        foreach (var g in extensions) AppendGroup(text, "x", g);
        text.Append("e\0").Append(excludedCount).Append('\0').Append(excludedBytes).Append('\n');
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString()))).ToLowerInvariant();
    }
    private static void AppendGroup(StringBuilder text, string prefix, InventoryGroup g) => text.Append(prefix).Append('\0')
        .Append(g.Category).Append('\0').Append(g.FileCount).Append('\0').Append(g.TotalBytes).Append('\0').Append(g.MaximumFileBytes).Append('\n');
}

internal static class SceneRuntimeAssetCatalog
{
    internal static bool HasSafeAssetFiles(uint depotID, ulong manifestID, DepotManifest manifest) =>
        EngineManifestInventoryBuilder.Build([(depotID, manifestID, manifest)]).Files.Count != 0;
}
