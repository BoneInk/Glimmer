using System.Reflection;
using SteamKit2.CDN;
using SteamKit2.Internal;

namespace Glimmer.SteamContent;

// SteamKit2 3.4.0's convenience converter loses "optional" HTTPS support. Read the
// same authenticated CM response directly, retaining that capability before conversion.
internal sealed record CDNDirectoryGroup(string Type, string HTTPSCapability, string Rejection, int Count);
internal sealed record CDNDirectoryDiagnostics(int Total, int Accepted, IReadOnlyList<CDNDirectoryGroup> Groups);
internal sealed record CDNDirectorySelection(Server[] Servers, CDNDirectoryDiagnostics Diagnostics);
internal static class CDNServerDirectory
{
    internal static async Task<CDNDirectorySelection> Find(uint preferredCell,
        Func<uint, Task<CContentServerDirectory_GetServersForSteamPipe_Response>> fetch,
        Func<Task<CContentServerDirectory_GetServersForSteamPipe_Response>>? fetchPublic,
        CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        var preferred = Select(await Fetch(() => fetch(preferredCell), "cdn_directory_cm_failed", cancellation));
        cancellation.ThrowIfCancellationRequested();
        if (preferred.Servers.Length != 0) return preferred;
        // A cell is a routing preference, not an authorization boundary. Ask the same CM
        // session for global candidates once; only directory-advertised TLS is ever used.
        var combined = preferred;
        if (preferredCell != 0)
        {
            var global = Select(await Fetch(() => fetch(0), "cdn_directory_cm_failed", cancellation));
            cancellation.ThrowIfCancellationRequested();
            combined = Merge(preferred, global);
        }
        if (combined.Servers.Length != 0 || fetchPublic is null) return combined;
        cancellation.ThrowIfCancellationRequested();
        // Discovery is public and carries no session material. Authorization remains on the
        // authenticated PublishedFile/depot/request-code/token path after this selection.
        var publicGlobal = Select(await Fetch(fetchPublic, "cdn_directory_public_failed", cancellation));
        cancellation.ThrowIfCancellationRequested();
        return Merge(combined, publicGlobal);
    }
    private static async Task<CContentServerDirectory_GetServersForSteamPipe_Response> Fetch(
        Func<Task<CContentServerDirectory_GetServersForSteamPipe_Response>> operation, string failureCode, CancellationToken cancellation)
    {
        try { return await operation().WaitAsync(cancellation); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
        catch (ContentFailure) { throw; }
        // Directory exceptions can contain request URLs. Collapse every SDK/HTTP/parser failure
        // to a fixed phase code before it reaches the pipe.
        catch (Exception) { throw new ContentFailure(failureCode); }
    }
    private static CDNDirectorySelection Merge(CDNDirectorySelection first, CDNDirectorySelection second)
    {
        var groups = first.Diagnostics.Groups.Concat(second.Diagnostics.Groups)
            .GroupBy(g => (g.Type, g.HTTPSCapability, g.Rejection))
            .OrderBy(g => g.Key.Type).ThenBy(g => g.Key.HTTPSCapability).ThenBy(g => g.Key.Rejection)
            .Select(g => new CDNDirectoryGroup(g.Key.Type, g.Key.HTTPSCapability, g.Key.Rejection, g.Sum(x => x.Count))).ToArray();
        return new(second.Servers, new(first.Diagnostics.Total + second.Diagnostics.Total,
            first.Diagnostics.Accepted + second.Diagnostics.Accepted, groups));
    }
    internal static CDNDirectorySelection Select(CContentServerDirectory_GetServersForSteamPipe_Response response)
    {
        if (response.servers.Count > 512) throw new ContentFailure("cdn_directory_limit");
        var servers = new List<Server>();
        var counts = new Dictionary<(string Type, string HTTPS, string Rejection), int>();
        foreach (var raw in response.servers)
        {
            string rejection = Rejection(raw);
            var group = (raw.type is "CDN" or "SteamCache" ? raw.type : "other",
                         raw.https_support is "mandatory" or "optional" or "unavailable" ? raw.https_support : "other", rejection);
            counts[group] = counts.GetValueOrDefault(group) + 1;
            if (rejection != "none") continue;
            var server = new Server();
            // The pinned library exposes getters but internal setters. This fixed-property
            // adapter preserves metadata, never loads code or reflects caller-selected names.
            Set(server, nameof(Server.Protocol), Server.ConnectionProtocol.HTTPS);
            Set(server, nameof(Server.Port), 443);
            Set(server, nameof(Server.Host), raw.host);
            Set(server, nameof(Server.VHost), raw.vhost);
            Set(server, nameof(Server.Type), raw.type);
            Set(server, nameof(Server.SourceID), raw.source_id);
            Set(server, nameof(Server.CellID), checked((uint)raw.cell_id));
            Set(server, nameof(Server.Load), raw.load);
            Set(server, nameof(Server.WeightedLoad), raw.weighted_load);
            Set(server, nameof(Server.NumEntries), raw.num_entries_in_client_list);
            Set(server, nameof(Server.SteamChinaOnly), raw.steam_china_only);
            Set(server, nameof(Server.UseAsProxy), raw.use_as_proxy);
            Set(server, nameof(Server.ProxyRequestPathTemplate), raw.proxy_request_path_template);
            Set(server, nameof(Server.AllowedAppIds), raw.allowed_app_ids.ToArray());
            if (!CDNBoundary.ValidServer(server)) throw new ContentFailure("cdn_sdk_adapter_contract");
            servers.Add(server);
        }
        var diagnostics = new CDNDirectoryDiagnostics(response.servers.Count, servers.Count,
            counts.OrderBy(x => x.Key.Type).ThenBy(x => x.Key.HTTPS).ThenBy(x => x.Key.Rejection)
                .Select(x => new CDNDirectoryGroup(x.Key.Type, x.Key.HTTPS, x.Key.Rejection, x.Value)).ToArray());
        return new(servers.OrderBy(s => s.WeightedLoad).Take(8).ToArray(), diagnostics);
    }
    private static string Rejection(CContentServerDirectory_ServerInfo s)
    {
        if (s.https_support is not ("optional" or "mandatory")) return "https_not_advertised";
        if (s.use_as_proxy) return "proxy";
        if (s.type is not ("CDN" or "SteamCache")) return "server_type";
        if (!CDNBoundary.ValidDNS(s.host) || !CDNBoundary.ValidDNS(s.vhost)) return "hostname";
        if (s.allowed_app_ids.Count > 1024 || s.allowed_app_ids.Count != 0 && !s.allowed_app_ids.Contains(431960u)) return "app_restricted";
        if (s.cell_id < 0 || !float.IsFinite(s.weighted_load)) return "metadata";
        return "none";
    }
    private static readonly Dictionary<string, PropertyInfo> Properties = typeof(Server).GetProperties()
        .Where(p => p.SetMethod is not null).ToDictionary(p => p.Name);
    private static void Set(Server server, string name, object value)
    {
        if (!Properties.TryGetValue(name, out var property)) throw new ContentFailure("cdn_sdk_adapter_contract");
        property.SetValue(server, value);
    }
}
