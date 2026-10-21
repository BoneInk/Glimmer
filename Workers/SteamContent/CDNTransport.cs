using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Glimmer.SteamContent;

internal sealed record CDNRequestScope(string Host, string Path, int BodyLimit, bool Manifest,
    CancellationToken Cancellation, Action<int>? Received = null, bool Fixture = false);

// The scope is created by the authenticated SDK adapter, never by JSON input. Every CDN client has
// its own immutable scope, so old requests cannot inherit a new item's counter or cancellation token.
internal sealed class CDNBoundaryHandler(CDNRequestScope scope, HttpMessageHandler inner) : DelegatingHandler(inner)
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        var u = request.RequestUri;
        bool allowedScheme = scope.Fixture ? u?.Scheme == "http" && u.IsLoopback : u?.Scheme == "https" && u.Port == 443;
        if (!allowedScheme || u is null || request.Method != HttpMethod.Get || !u.Host.Equals(scope.Host, StringComparison.OrdinalIgnoreCase) ||
            u.AbsolutePath != scope.Path || !string.IsNullOrEmpty(u.UserInfo) || !string.IsNullOrEmpty(u.Fragment))
            throw new ContentFailure("cdn_request_outside_authorized_scope");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, scope.Cancellation);
        var response = await base.SendAsync(request, linked.Token);
        try
        {
            if (!response.IsSuccessStatusCode) throw new HttpRequestException("cdn_http_failure", null, response.StatusCode);
            if (response.Content.Headers.ContentLength is long length && (length < 0 || length > scope.BodyLimit))
                throw new ContentFailure("cdn_response_limit");
            if (scope.Manifest)
            {
                // The SDK parses a ZIP internally. Bound and fully inspect its only entry first so an
                // untrusted ZIP cannot make its inner parser read unbounded decompressed input.
                byte[] bytes = await BoundedRead(response.Content, scope.BodyLimit, linked.Token);
                ValidateManifestEnvelope(bytes);
                response.Content.Dispose(); response.Content = new ByteArrayContent(bytes);
            }
            else response.Content = new CountedContent(response.Content, scope);
            return response;
        }
        catch { response.Dispose(); throw; }
    }
    internal static async Task<byte[]> BoundedRead(HttpContent content, int limit, CancellationToken token)
    {
        await using var source = await content.ReadAsStreamAsync(token);
        using var destination = new MemoryStream();
        var buffer = new byte[32768]; int n;
        while ((n = await source.ReadAsync(buffer, token)) != 0)
        { if (destination.Length + n > limit) throw new ContentFailure("cdn_response_limit"); destination.Write(buffer, 0, n); }
        return destination.ToArray();
    }
    internal static void ValidateManifestEnvelope(byte[] data)
    {
        using var stream = new MemoryStream(data, writable: false);
        using var zip = new ZipArchive(stream, ZipArchiveMode.Read);
        if (zip.Entries.Count != 1 || zip.Entries[0].Length is < 1 or > 16 * 1024 * 1024)
            throw new ContentFailure("manifest_zip_limit");
        using var source = zip.Entries[0].Open(); using var uncompressed = new MemoryStream();
        var buffer = new byte[32768]; long count = 0; int n;
        while ((n = source.Read(buffer)) != 0)
        {
            count += n; if (count > 16 * 1024 * 1024) throw new ContentFailure("manifest_zip_limit");
            uncompressed.Write(buffer, 0, n);
        }
        if (count != zip.Entries[0].Length) throw new ContentFailure("manifest_zip_length");
        ValidateManifestFraming(uncompressed.ToArray());
    }
    internal static void ValidateManifestFraming(byte[] bytes)
    {
        // Original framing preflight from documented upstream format constants, not a copied parser.
        // Version 5 endpoint requires bounded payload, metadata and signature sections then EOF.
        using var stream = new MemoryStream(bytes, writable: false);
        using var reader = new BinaryReader(stream);
        uint[] sections = [0x71f617d0, 0x1f4812be, 0x1b81b817];
        foreach (uint expected in sections)
        {
            if (stream.Length - stream.Position < 8 || reader.ReadUInt32() != expected) throw new ContentFailure("manifest_section_bounds");
            uint size = reader.ReadUInt32();
            if (size > stream.Length - stream.Position) throw new ContentFailure("manifest_section_bounds");
            stream.Position += size;
        }
        if (stream.Length - stream.Position != 4 || reader.ReadUInt32() != 0x32c415ab) throw new ContentFailure("manifest_section_bounds");
    }
    private sealed class CountedContent : HttpContent
    {
        private readonly HttpContent source;
        private readonly CDNRequestScope scope;
        internal CountedContent(HttpContent source, CDNRequestScope scope)
        { this.source = source; this.scope = scope; foreach (var h in source.Headers) Headers.TryAddWithoutValidation(h.Key, h.Value); }
        protected override Task SerializeToStreamAsync(Stream target, TransportContext? context) => SerializeToStreamAsync(target, context, CancellationToken.None);
        protected override async Task SerializeToStreamAsync(Stream target, TransportContext? context, CancellationToken token)
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, scope.Cancellation);
            await using var input = await source.ReadAsStreamAsync(linked.Token);
            byte[] buffer = new byte[32768]; int count = 0, n;
            while ((n = await input.ReadAsync(buffer, linked.Token)) != 0)
            {
                scope.Received?.Invoke(n); count = checked(count + n);
                if (count > scope.BodyLimit) throw new ContentFailure("cdn_response_limit");
                await target.WriteAsync(buffer.AsMemory(0, n), linked.Token);
            }
        }
        protected override bool TryComputeLength(out long length) { length = Headers.ContentLength ?? 0; return Headers.ContentLength.HasValue; }
        protected override void Dispose(bool disposing) { if (disposing) source.Dispose(); base.Dispose(disposing); }
    }
}

internal static class SteamHTTP
{
    internal static SocketsHttpHandler Handler(bool fixture = false) => new()
    {
        AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None, UseCookies = false,
        ConnectTimeout = TimeSpan.FromSeconds(10), MaxConnectionsPerServer = 4, UseProxy = false,
        ConnectCallback = fixture ? null : ConnectPublic
    };
    internal static SocketsHttpHandler CMWebSocketHandler() => new()
    {
        AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None, UseCookies = false,
        ConnectTimeout = TimeSpan.FromSeconds(10), MaxConnectionsPerServer = 4, UseProxy = false,
        ConnectCallback = ConnectCMWebSocket
    };
    private static async ValueTask<Stream> ConnectPublic(SocketsHttpConnectionContext context, CancellationToken token)
    {
        return await ConnectPublic(context, cmWebSocket: false, token);
    }
    private static async ValueTask<Stream> ConnectCMWebSocket(SocketsHttpConnectionContext context, CancellationToken token)
    {
        return await ConnectPublic(context, cmWebSocket: true, token);
    }
    private static async ValueTask<Stream> ConnectPublic(SocketsHttpConnectionContext context, bool cmWebSocket, CancellationToken token)
    {
        string host = context.DnsEndPoint.Host.TrimEnd('.');
        int port = context.DnsEndPoint.Port;
        if (cmWebSocket)
        {
            if (!TrustedCMHost(host) || port != 443 && port is not (>= 27000 and <= 27050))
                throw new HttpRequestException("cm_websocket_endpoint_required");
        }
        else if (port != 443) throw new HttpRequestException("https_port_required");
        var addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, token);
        var targets = addresses.Where(IsPublic).Distinct().Take(8).ToArray();
        if (targets.Length == 0) throw new HttpRequestException("no_public_cdn_address");
        var proxy = await ResolveLoopbackProxy(new UriBuilder(Uri.UriSchemeHttps,
            host, port).Uri, HttpClient.DefaultProxy, token);
        foreach (var ip in targets)
        {
            try
            {
                return proxy is null
                    ? await ConnectDirect(ip, port, token)
                    : await ConnectTunnel(ip, port, proxy, token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (ContentFailure) { throw; }
            catch { token.ThrowIfCancellationRequested(); }
        }
        throw new HttpRequestException(proxy is null ? "public_connect_failed" : "proxy_connect_failed");
    }
    internal static bool TrustedCMHost(string host) =>
        host.Equals("steamserver.net", StringComparison.OrdinalIgnoreCase) ||
        host.EndsWith(".steamserver.net", StringComparison.OrdinalIgnoreCase);
    internal sealed record LoopbackProxy(IPAddress Address, int Port);
    internal static async Task<LoopbackProxy?> ResolveLoopbackProxy(Uri target, IWebProxy configured, CancellationToken token)
    {
        Uri? uri;
        try
        {
            if (configured.Credentials is not null || configured.IsBypassed(target)) return null;
            uri = configured.GetProxy(target);
        }
        catch { return null; }
        if (uri is null || uri == target || uri.Scheme != Uri.UriSchemeHttp || !string.IsNullOrEmpty(uri.UserInfo) ||
            uri.Port is < 1 or > 65535) return null;
        IPAddress[] addresses;
        try { addresses = await Dns.GetHostAddressesAsync(uri.Host, token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch { return null; }
        // Fail closed if a proxy hostname can resolve anywhere except this machine.
        if (addresses.Length == 0 || addresses.Any(x => !IPAddress.IsLoopback(x))) return null;
        return new LoopbackProxy(addresses[0], uri.Port);
    }
    private static async Task<Stream> ConnectDirect(IPAddress address, int port, CancellationToken token)
    {
        var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(new IPEndPoint(address, port), token);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch { socket.Dispose(); throw; }
    }
    internal static async Task<Stream> ConnectTunnel(IPAddress target, int port, LoopbackProxy proxy, CancellationToken token)
    {
        if (!IsPublic(target) || port != 443 && port is not (>= 27000 and <= 27050) ||
            !IPAddress.IsLoopback(proxy.Address) || proxy.Port is < 1 or > 65535)
            throw new ContentFailure("proxy_connect_boundary");
        var socket = new Socket(proxy.Address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(new IPEndPoint(proxy.Address, proxy.Port), token);
            var stream = new NetworkStream(socket, ownsSocket: true);
            string authority = target.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{target}]:{port}" : $"{target}:{port}";
            byte[] request = Encoding.ASCII.GetBytes($"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: Keep-Alive\r\n\r\n");
            await stream.WriteAsync(request, token);
            int status = await ReadConnectStatus(stream, token);
            if (status == 200) return stream;
            stream.Dispose();
            if (status is 401 or 407) throw new ContentFailure("proxy_auth_required");
            throw new ContentFailure("proxy_connect_failed");
        }
        catch { socket.Dispose(); throw; }
    }
    private static async Task<int> ReadConnectStatus(Stream stream, CancellationToken token)
    {
        byte[] header = new byte[8192]; int count = 0, matched = 0;
        while (count < header.Length)
        {
            int n = await stream.ReadAsync(header.AsMemory(count, 1), token);
            if (n == 0) throw new ContentFailure("proxy_connect_failed");
            byte b = header[count++];
            matched = (matched, b) switch { (0, 13) => 1, (1, 10) => 2, (2, 13) => 3, (3, 10) => 4, (_, 13) => 1, _ => 0 };
            if (matched == 4) break;
        }
        if (matched != 4) throw new ContentFailure("proxy_connect_failed");
        int lineEnd = Array.IndexOf(header, (byte)'\r', 0, count);
        if (lineEnd < 12 || !header.AsSpan(0, 9).SequenceEqual("HTTP/1.1 "u8) &&
            !header.AsSpan(0, 9).SequenceEqual("HTTP/1.0 "u8)) throw new ContentFailure("proxy_connect_failed");
        return int.TryParse(Encoding.ASCII.GetString(header, 9, 3), out int status) ? status : 0;
    }
    internal static bool IsPublic(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || address.IsIPv6LinkLocal || address.IsIPv6Multicast || address.IsIPv6SiteLocal) return false;
        var b = address.GetAddressBytes();
        if (b.Length == 16) return b.Any(x => x != 0) && (b[0] & 0xfe) != 0xfc && b[0] != 0xff && !address.Equals(IPAddress.IPv6None);
        return b[0] is not (0 or 10 or 127) && b[0] < 224 && !(b[0] == 169 && b[1] == 254) &&
            !(b[0] == 172 && b[1] is >= 16 and <= 31) && !(b[0] == 192 && b[1] == 168) &&
            !(b[0] == 100 && b[1] is >= 64 and <= 127) && !(b[0] == 198 && b[1] is 18 or 19);
    }
}
