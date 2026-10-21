using SteamKit2;
using SteamKit2.CDN;

namespace Glimmer.SteamContent;

internal sealed record AppDepotManifest(uint DepotID, ulong ManifestID);
internal sealed record EngineAssetResolution(AuthorizedManifest Manifest, IReadOnlyDictionary<string, string> Resources);
internal sealed record EngineAssetInspection(IReadOnlyList<AppDepotManifest> Manifests, IReadOnlyList<string> Paths);

internal static class EngineAssetCatalog
{
    internal const uint AppID = 431960;
    private static readonly IReadOnlyDictionary<string, string> allowed = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["materials/particle/halo.tex"] = "assets/materials/particle/halo.tex",
        ["materials/particle/beam/beam_1.tex"] = "assets/materials/particle/beam/beam_1.tex",
        ["materials/particle/fog/fog1.tex"] = "assets/materials/particle/fog/fog1.tex",
        ["materials/particle/beam/hose_2.tex"] = "assets/materials/particle/beam/hose_2.tex",
        ["materials/particle/beam/hose_2_normal.tex"] = "assets/materials/particle/beam/hose_2_normal.tex",
        ["materials/util/noise.tex"] = "assets/materials/util/noise.tex",
        ["materials/gradient/gradient_iridescent.tex"] = "assets/materials/gradient/gradient_iridescent.tex",
        ["fonts/Alcubierre.otf"] = "assets/fonts/Alcubierre.otf",
        ["shaders/common_blending.h"] = "assets/shaders/common_blending.h"
    };
    internal static IReadOnlyDictionary<string, string> Validate(IReadOnlyList<string>? requested)
    {
        if (requested is null || requested.Count is < 1 or > 16) throw new ContentFailure("invalid_engine_asset_request");
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string name in requested)
        {
            if (!allowed.TryGetValue(name, out string? path) || !result.TryAdd(name, path))
                throw new ContentFailure("invalid_engine_asset_request");
        }
        return result;
    }
    internal static IReadOnlyList<AppDepotManifest> PublicWindowsDepots(KeyValue appInfo)
    {
        var depots = appInfo["depots"];
        if (depots.Children.Count is < 1 or > 256) throw new ContentFailure("appinfo_depots_missing");
        uint workshopDepot = 0;
        string? workshop = depots["workshopdepot"].Value;
        if (workshop is not null && (!uint.TryParse(workshop, out workshopDepot) || workshopDepot == 0))
            throw new ContentFailure("workshop_depot_invalid");
        var result = new List<AppDepotManifest>();
        foreach (var node in depots.Children)
        {
            if (!uint.TryParse(node.Name, out uint depot) || depot == 0 || depot == workshopDepot) continue;
            string? os = node["config"]["oslist"].Value;
            if (!string.IsNullOrEmpty(os) && !os.Split(',', StringSplitOptions.TrimEntries).Contains("windows", StringComparer.OrdinalIgnoreCase)) continue;
            var publicBranch = node["manifests"]["public"];
            string? gid = publicBranch["gid"].Value ?? publicBranch.Value;
            if (ulong.TryParse(gid, out ulong manifest) && manifest != 0) result.Add(new(depot, manifest));
        }
        if (result.Count is < 1 or > 32) throw new ContentFailure("public_windows_depot_manifest_unavailable");
        return result.OrderBy(x => x.DepotID).ToArray();
    }
    internal static IReadOnlyDictionary<string, string>? Match(DepotManifest manifest, IReadOnlyDictionary<string, string> requested)
    {
        if (manifest.Files is null || manifest.Files.Count > 20000) throw new ContentFailure("manifest_identity_or_limit");
        var actual = manifest.Files.Where(f => (f.Flags & SteamKit2.EDepotFileFlag.Directory) == 0)
            .Select(f => AuthorizedManifest.ValidatePath(f.FileName)).ToHashSet(StringComparer.Ordinal);
        return requested.Values.All(actual.Contains) ? requested : null;
    }
    internal static IReadOnlyList<string> Inspect(DepotManifest manifest, IReadOnlyDictionary<string, string> requested)
    {
        if (manifest.Files is null || manifest.Files.Count > 20000) throw new ContentFailure("manifest_identity_or_limit");
        var exact = requested.Values.ToHashSet(StringComparer.Ordinal);
        var paths = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var file in manifest.Files)
        {
            if ((file.Flags & EDepotFileFlag.Directory) != 0) continue;
            string path = AuthorizedManifest.ValidatePath(file.FileName);
            string lower = path.ToLowerInvariant();
            string name = lower[(lower.LastIndexOf('/') + 1)..];
            bool fixedArchiveRoot = lower.StartsWith("wallpaper_engine/", StringComparison.Ordinal) ||
                lower.StartsWith("bin/", StringComparison.Ordinal) || lower.StartsWith("resources/", StringComparison.Ordinal);
            bool rootArchive = !lower.Contains('/') &&
                (name.StartsWith("asset", StringComparison.Ordinal) || name.StartsWith("shader", StringComparison.Ordinal));
            bool archiveCandidate = lower.EndsWith(".pkg", StringComparison.Ordinal) &&
                (lower.StartsWith("assets/", StringComparison.Ordinal) || rootArchive || fixedArchiveRoot &&
                    (name.Contains("asset", StringComparison.Ordinal) || name.Contains("shader", StringComparison.Ordinal)));
            if (exact.Contains(path) || archiveCandidate)
            {
                if (!paths.Add(path) || paths.Count > 192 || paths.Sum(p => p.Length) > 64 * 1024)
                    throw new ContentFailure("engine_asset_inspection_limit");
            }
        }
        return paths.ToArray();
    }
}
