using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Glimmer.SteamContent;
using SteamKit2;
using SteamKit2.CDN;
using SteamKit2.Internal;
using ProtoBuf;
using System.Runtime.Versioning;
[assembly: SupportedOSPlatform("macos")]

internal static class SessionTests
{
    [DllImport("libSystem.B.dylib", SetLastError = true)] private static extern int link(string existing, string created);
    private static readonly List<string> passed = [];
    private static void Check(bool value, string name) { if (!value) throw new Exception(name); passed.Add(name); }
    private static async Task Reject(Func<Task> action, string name, string? code = null)
    {
        try { await action(); } catch (Exception e) when (e is ContentFailure or IOException or OperationCanceledException or HttpRequestException)
        { Check(code is null || e is ContentFailure f && f.Code == code, name); return; }
        throw new Exception("unexpected success: " + name);
    }
    private static async Task Until(Func<bool> condition)
    { using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3)); while (!condition()) await Task.Delay(5, deadline.Token); }
    private static void Set(object o, string name, object value) => o.GetType().GetProperty(name)!.SetValue(o, value);
    private static Server Server(bool fixture = false, int port = 443)
    {
        var s = new Server(); Set(s,"Protocol",fixture ? SteamKit2.CDN.Server.ConnectionProtocol.HTTP : SteamKit2.CDN.Server.ConnectionProtocol.HTTPS);
        Set(s,"Host",fixture ? "127.0.0.1" : "fixture.steamcontent.com"); Set(s,"VHost",fixture ? "127.0.0.1" : "fixture.steamcontent.com");
        Set(s,"Port",port); Set(s,"Type","CDN"); Set(s,"AllowedAppIds",new uint[]{431960}); return s;
    }
    private static readonly byte[] payload = Enumerable.Range(0,6144).SelectMany(i=>SHA256.HashData(BitConverter.GetBytes(i))).ToArray();
    private static readonly byte[] key = Enumerable.Range(0,32).Select(i=>(byte)i).ToArray();
    private static PublishedFileDetails Details(ulong item=123) => new() { result=1, publishedfileid=item, consumer_appid=431960, hcontent_file=456, file_type=0 };
    private static DepotManifest Manifest(string path="textures/original.bin", byte[]? data=null)
    {
        data ??= payload;
        var m = new DepotManifest { Files = [], CreationTime = DateTime.UnixEpoch }; Set(m,"DepotID",431960u); Set(m,"ManifestGID",456UL);
        Set(m,"TotalUncompressedSize",(ulong)data.Length); Set(m,"FilenamesEncrypted",false);
        var f = new DepotManifest.FileData(path, [], 0, (ulong)data.Length, SHA1.HashData(data), "", false, 0);
        var packed = Encrypt(data); m.TotalCompressedSize = (ulong)packed.Length;
        f.Chunks.Add(new DepotManifest.ChunkData(SHA1.HashData(data),DepotChunk.AdlerHash(data),0,(uint)packed.Length,(uint)data.Length));
        m.Files!.Add(f); return m;
    }
    private static AuthorizedManifest Plan(string session, DepotManifest? manifest=null) => AuthorizedManifest.FromSDK(session, Details(),123,431960,manifest??Manifest(),key,[Server()]);
    private static byte[] Zip(byte[] bytes)
    {
        using var m=new MemoryStream();
        using(var zip=new ZipArchive(m,ZipArchiveMode.Create,true)) { using var s=zip.CreateEntry("original",CompressionLevel.Fastest).Open();s.Write(bytes); }
        return m.ToArray();
    }
    private static byte[] Encrypt(byte[] bytes)
    {
        using var aes=Aes.Create();aes.Key=key;
        byte[] iv=Enumerable.Range(16,16).Select(i=>(byte)i).ToArray();
        return aes.EncryptEcb(iv,PaddingMode.None).Concat(aes.EncryptCbc(Zip(bytes),iv,PaddingMode.PKCS7)).ToArray();
    }
    public static async Task Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--public-cm-probe")
        {
            await PublicCMProbe();
            return;
        }
        if (args.Length is 1 or 2 && args[0] == "--public-directory-probe")
        {
            await PublicDirectoryProbe(args.Length == 2 ? uint.Parse(args[1]) : 0);
            return;
        }
        string root=Path.GetFullPath(args[0]);
        await Authentication();
        Boundaries();
        await DirectoryCapabilities();
        await ProxyTransport();
        await HTTPAndDisk(root);
        Console.WriteLine(JsonSerializer.Serialize(new { passed=passed.Count, checks=passed,
            scope="controlled own-session auth + real official SDK manifest/CDN loopback HTTP + actual POSIX disk, NO Steam connection or credentials" },new JsonSerializerOptions{WriteIndented=true}));
    }
    private static async Task PublicCMProbe()
    {
        var results = new List<object>();
        foreach (var fixedCM in new[] { false, true })
        {
            var protocol = fixedCM ? ProtocolTypes.WebSocket : ProtocolTypes.Tcp | ProtocolTypes.WebSocket;
            var configuration = SteamConfiguration.Create(builder => builder.WithProtocolTypes(protocol)
                .WithHttpClientFactory(purpose => SteamKitSession.CreateNonCDNHTTPClient(fixedCM ? purpose : HttpClientPurpose.WebAPI)));
            var client = new SteamClient(configuration);
            var callbacks = new CallbackManager(client);
            var outcome = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var connected = callbacks.Subscribe<SteamClient.ConnectedCallback>(_ => outcome.TrySetResult("connected"));
            using var disconnected = callbacks.Subscribe<SteamClient.DisconnectedCallback>(_ => outcome.TrySetResult("disconnected"));
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(35));
            var timer = System.Diagnostics.Stopwatch.StartNew();
            client.Connect();
            string state;
            try
            {
                while (!outcome.Task.IsCompleted) { callbacks.RunCallbacks(); await Task.Delay(10, deadline.Token); }
                state = await outcome.Task;
            }
            catch (OperationCanceledException) { state = "timeout"; }
            finally { client.Disconnect(); }
            results.Add(new { fixedCM, protocol = protocol.ToString(), state, seconds = Math.Round(timer.Elapsed.TotalSeconds, 2) });
        }
        Console.WriteLine(JsonSerializer.Serialize(new { results, scope = "public CM connection only; no login, account, Keychain or credentials" }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static async Task PublicDirectoryProbe(uint cell)
    {
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var safeProxy=await SteamHTTP.ResolveLoopbackProxy(new Uri("https://api.steampowered.com/"),HttpClient.DefaultProxy,deadline.Token);
        var configuration=SteamConfiguration.Create(builder=>builder.WithHttpClientFactory(purpose=>
        {
            if(purpose==HttpClientPurpose.CDN)throw new InvalidOperationException("probe_never_uses_cdn_transport");
            return SteamKitSession.CreateNonCDNHTTPClient();
        }));
        var request=new CContentServerDirectory_GetServersForSteamPipe_Request{cell_id=cell,max_servers=64};
        using var api=configuration.GetAsyncWebAPIInterface("IContentServerDirectoryService");
        var sdk=await api.CallProtobufAsync<CContentServerDirectory_GetServersForSteamPipe_Response,
            CContentServerDirectory_GetServersForSteamPipe_Request>(HttpMethod.Get,
            nameof(ContentServerDirectory.GetServersForSteamPipe),request,version:1).WaitAsync(deadline.Token);
        using var encoded=new MemoryStream();Serializer.Serialize(encoded,request);
        string base64=Uri.EscapeDataString(Convert.ToBase64String(encoded.ToArray()));
        using var rawClient=SteamKitSession.CreateNonCDNHTTPClient();
        byte[] raw=await rawClient.GetByteArrayAsync("https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?format=protobuf_raw&input_protobuf_encoded="+base64,deadline.Token);
        if(raw.Length>1024*1024)throw new InvalidDataException("public_probe_limit");
        var rawParsed=Serializer.Deserialize<CContentServerDirectory_GetServersForSteamPipe_Response>(raw.AsSpan());
        using var jsonClient=SteamKitSession.CreateNonCDNHTTPClient();
        using var jsonStream=await jsonClient.GetStreamAsync("https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id="+cell+"&max_servers=64",deadline.Token);
        using var json=await JsonDocument.ParseAsync(jsonStream,cancellationToken:deadline.Token);
        var jsonGroups=json.RootElement.GetProperty("response").GetProperty("servers").EnumerateArray()
            .GroupBy(x=>(x.GetProperty("type").GetString()??"",x.GetProperty("https_support").GetString()??""))
            .OrderBy(x=>x.Key.Item1).ThenBy(x=>x.Key.Item2)
            .Select(x=>new{type=x.Key.Item1,https=x.Key.Item2,count=x.Count()}).ToArray();
        object Summary(CContentServerDirectory_GetServersForSteamPipe_Response response)
        {
            var selected=CDNServerDirectory.Select(response);
            return new{total=response.servers.Count,httpsFieldPresent=response.servers.Count(x=>x.ShouldSerializehttps_support()),
                groups=selected.Diagnostics.Groups,accepted=selected.Diagnostics.Accepted,noChange=response.no_change};
        }
        Console.WriteLine(JsonSerializer.Serialize(new{requestedCell=cell,transport=safeProxy is null ? "direct" : "loopback_http_connect",
            proxyAddressClass=safeProxy is null ? "none" : "loopback",sdkEResult=(int)sdk.Result,sdk=Summary(sdk.Body),
            rawProtobufBytes=raw.Length,rawProtobuf=Summary(rawParsed),json=new{total=jsonGroups.Sum(x=>x.count),groups=jsonGroups},
            sameSDKAndRaw=JsonSerializer.Serialize(Summary(sdk.Body))==JsonSerializer.Serialize(Summary(rawParsed)),
            scope="public official API only; production WebAPI factory/SteamHTTP handler; no account, cache, Keychain, process or GUI"},
            new JsonSerializerOptions{WriteIndented=true}));
    }
    private static async Task Authentication()
    {
        foreach (var error in new Exception[] { new TimeoutException("private"), new OperationCanceledException("private"), new TaskCanceledException("private") })
        {
            Check(Program.AuthFailureCode(error, false) == "steam_auth_timeout", "internal timeout or disconnect cancellation is transient rather than user cancellation");
            Check(Program.AuthFailureCode(error, true) == "cancelled", "explicit user cancellation wins concurrent transport failure");
        }
        Check(Program.AuthFailureCode(new Exception("private credential text"), false) == "steam_auth_failed", "authentication errors never expose arbitrary exception text");
        var events=new ConcurrentQueue<AuthChallenge>(); var created=new List<FakeSession>();
        await using var controller=new SessionController(id=> {var s=new FakeSession(id);created.Add(s);return s;});
        var request=new AuthRequest{Method="credentials",Username="fixture-user",Password="fixture-password"};
        var login=controller.BeginLogin(request,events.Enqueue);string first=controller.ID!;
        await Until(()=>events.Count==1);events.TryPeek(out var challenge);
        Check(created.Count==1,"explicit login creates exactly one owned session; construction does not invoke real SDK network");
        Check(!controller.Respond(new(Guid.NewGuid().ToString(),challenge!.ChallengeID,"ABCDE")),"wrong-session Guard response rejected");
        Check(!controller.Respond(new(first,Guid.NewGuid().ToString(),"ABCDE")),"wrong challenge ID rejected");
        Check(!controller.Respond(new(first,challenge.ChallengeID,"bad\ncode")),"control characters in Guard code rejected");
        Check(controller.Respond(new(first,challenge.ChallengeID,"ABCDE")),"matching Guard response resolves its own challenge");
        var result=await login.WaitAsync(TimeSpan.FromSeconds(3));
        Check(result.RefreshToken=="fixture-refresh" && controller.Require(first).Authenticated,"auth success only after owned adapter authenticated");
        Check(request.Password is null && request.RefreshToken is null,"credential references released after auth");
        Check(!controller.Respond(new(first,challenge.ChallengeID,"ABCDE")),"completed challenge cannot replay");
        await Reject(()=>Task.Run(()=>controller.Require(Guid.NewGuid().ToString())),"wrong session cannot lease content adapter","session_not_authenticated");
        await Reject(()=>controller.BeginLogin(new(){Method="qr"},events.Enqueue),"second login cannot overwrite ready account","session_busy");
        await Reject(()=>controller.Close(Guid.NewGuid().ToString()),"stale logout cannot close current session","stale_session");
        Check(controller.Require(first).Authenticated,"stale logout preserves current authenticated session");
        await controller.Close(first);Check(created[0].Disposed,"logout disposes only its own adapter");
        await Reject(()=>Task.Run(()=>controller.Require(first)),"closed session no longer authorizes downloads","session_not_authenticated");
        events.Clear();var pending=controller.BeginLogin(new(){Method="credentials",Username="second",Password="dummy"},events.Enqueue);
        await Until(()=>events.Count==1);var second=controller.ID!;events.TryPeek(out var secondChallenge);
        Check(first!=second,"each login attempt gets new session identity");
        await controller.Close(second);
        await Reject(async()=>await pending,"cancel while Guard pending drains login task");
        Check(created[1].Disposed && !controller.Respond(new(second,secondChallenge!.ChallengeID,"ABCDE")),"cancel revokes pending challenge and late response");
        using var cancel=new CancellationTokenSource();var all=new List<AuthChallenge>();using var broker=new AuthChallengeBroker(Guid.NewGuid().ToString(),all.Add,cancel.Token);
        var email=broker.GetEmailCodeAsync("f***@example.invalid",true);await Until(()=>all.Count==1);
        Check(all[0].PreviousIncorrect && all[0].Type=="email_code","email retry flag and challenge type preserved");
        Check(broker.Respond(new(all[0].SessionID,all[0].ChallengeID,"12345")),"email response is explicitly accepted");Check(await email=="12345","email code returned only to matching SDK call");
        var push=broker.AcceptDeviceConfirmationAsync();await Until(()=>all.Count==2);
        Check(!broker.Respond(new(all[1].SessionID,all[1].ChallengeID,"ABCDE")),"push cannot be answered as a code");
        Check(broker.Respond(new(all[1].SessionID,all[1].ChallengeID,Accepted:false)) && !await push,"device decline falls back via actual SDK authenticator boolean");
        broker.QR("https://s.team/q/1/fixture-only");Check(all[^1].Type=="qr" && !broker.Respond(new(all[^1].SessionID,all[^1].ChallengeID,Accepted:true)),"QR event cannot fabricate Steam approval with host response");
        var wait=broker.GetDeviceCodeAsync(false);cancel.Cancel();await Reject(async()=>await wait,"token cancellation releases pending code wait");
        await Reject(()=>Task.Run(()=>new AuthRequest{Method="refresh",Username="u",Password="p",RefreshToken="r"}.Validate()),"mixed password and refresh auth request rejected","invalid_auth_request");
        await Reject(()=>Task.Run(()=>new AuthRequest{Method="qr",RefreshToken="r"}.Validate()),"QR request cannot smuggle refresh token","invalid_auth_request");
        SlowSession? delayed=null;await using(var late=new SessionController(id=>delayed=new SlowSession(id)))
        {
            var oldLogin=late.BeginLogin(new(){Method="qr"},_=>{});string oldID=late.ID!;
            await Until(()=>delayed!.Started);var close=late.Close(oldID);await Task.Delay(20);
            Check(!close.IsCompleted,"logout waits for late underlying auth operation rather than fake ACK");
            await Reject(()=>late.BeginLogin(new(){Method="qr"},_=>{}),"new login blocked until old auth actually drained","session_busy");
            delayed!.Result.TrySetResult(new("old","123","old-secret",null));await close;
            await Reject(async()=>await oldLogin,"late old auth result cannot publish a token after logout");
            Check(late.ID is null && delayed.Disposed,"late auth leaves no current session or active adapter");
        }
        bool failFactory=true;await using(var construction=new SessionController(id=>
        {if(failFactory){failFactory=false;throw new ContentFailure("fixture_constructor_failed");}return new FakeSession(id);}))
        {
            var failedRequest=new AuthRequest{Method="credentials",Username="u",Password="p"};
            await Reject(()=>construction.BeginLogin(failedRequest,_=>{}),"factory failure is explicit and does not leave session state","fixture_constructor_failed");
            Check(construction.ID is null && failedRequest.Password is null,"factory failure releases credentials and current identity");
            var challengeQueue=new ConcurrentQueue<AuthChallenge>();var next=construction.BeginLogin(new(){Method="qr"},challengeQueue.Enqueue);
            await Until(()=>challengeQueue.Count==1);challengeQueue.TryPeek(out var ch);Check(construction.Respond(new(ch!.SessionID,ch.ChallengeID,"ABCDE")),"new session succeeds after failed construction cleanup");await next;
        }
        using var real=new RealAdapterNoNetwork();Check(true,"real SteamKit adapter constructs and disposes without connecting");
    }
    private static void Boundaries()
    {
        var classified = new Exception[] { new UnauthorizedAccessException("private-path"), new IOException("private-host"),
            new ObjectDisposedException("private-token"), new InvalidOperationException("private-state"),
            new ArgumentException("private-argument"), new CryptographicException("private-key"),
            new OutOfMemoryException("private-memory"), new Exception("private-unknown") }
            .Select(error => RuntimeFailureCodes.Classify("transfer", error).Code).ToArray();
        Check(classified.SequenceEqual(new[]{"scene_runtime_transfer_access","scene_runtime_transfer_io","scene_runtime_transfer_disposed",
            "scene_runtime_transfer_state","scene_runtime_transfer_argument","scene_runtime_transfer_crypto","scene_runtime_transfer_memory",
            "scene_runtime_transfer_unexpected"}) && classified.All(code=>!code.Contains("private")),
            "runtime internal diagnostics expose only fixed phase and exception category without exception text");
        string id=Guid.NewGuid().ToString();var valid=Plan(id);Check(valid.TotalBytes==payload.Length && valid.Files[0].Path=="textures/original.bin","real SDK metadata converts to bounded immutable manifest");
        Check(valid.Fingerprint==Plan(id).Fingerprint,"manifest fingerprint deterministic and excludes session secrets");
        var engineRequest=EngineAssetCatalog.Validate(["materials/particle/halo.tex","fonts/Alcubierre.otf","shaders/common_blending.h"]);
        Check(engineRequest.Count==3 && engineRequest["materials/particle/halo.tex"]=="assets/materials/particle/halo.tex" &&
            engineRequest["fonts/Alcubierre.otf"]=="assets/fonts/Alcubierre.otf",
            "engine assets accept only fixed logical texture, font and shader resource identifiers");
        try { EngineAssetCatalog.Validate(["../../arbitrary"]); throw new Exception("accepted arbitrary engine path"); }
        catch(ContentFailure e) { Check(e.Code=="invalid_engine_asset_request","arbitrary engine asset path rejected before Steam lookup"); }
        try { EngineAssetCatalog.Validate(["materials/particle/halo.tex","materials/particle/halo.tex"]); throw new Exception("accepted duplicate engine path"); }
        catch(ContentFailure e) { Check(e.Code=="invalid_engine_asset_request","duplicate engine asset request rejected"); }
        var appInfo=new KeyValue("appinfo");var depots=new KeyValue("depots");appInfo.Children.Add(depots);
        depots.Children.Add(new KeyValue("workshopdepot","431960"));
        static KeyValue Depot(string id,string os,string gid)
        { var d=new KeyValue(id);var config=new KeyValue("config");config.Children.Add(new KeyValue("oslist",os));d.Children.Add(config);var manifests=new KeyValue("manifests");var branch=new KeyValue("public");branch.Children.Add(new KeyValue("gid",gid));manifests.Children.Add(branch);d.Children.Add(manifests);return d; }
        depots.Children.Add(Depot("431960","windows","100"));depots.Children.Add(Depot("431961","windows","101"));
        depots.Children.Add(Depot("431962","macos","102"));depots.Children.Add(Depot("431963","","103"));
        var publicDepots=EngineAssetCatalog.PublicWindowsDepots(appInfo);
        Check(publicDepots.SequenceEqual(new[]{new AppDepotManifest(431961,101),new AppDepotManifest(431963,103)}),
            "PICS selection uses public Windows-compatible app depots and excludes declared workshop depot");
        var engineManifest=Manifest("assets/materials/particle/halo.tex");Set(engineManifest,"DepotID",431961u);
        engineManifest.Files!.Add(Manifest("assets/fonts/Alcubierre.otf").Files![0]);
        engineManifest.Files!.Add(Manifest("assets/shaders/common_blending.h").Files![0]);
        engineManifest.Files.Add(Manifest("assets/private/unrequested.bin").Files![0]);
        var matched=EngineAssetCatalog.Match(engineManifest,engineRequest)!;
        var enginePlan=AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],matched.Values.ToHashSet(StringComparer.Ordinal));
        Check(enginePlan.PublishedFileID==0 && enginePlan.Files.Select(f=>f.Path).Order().SequenceEqual(matched.Values.Order()),
            "app depot authorization carries no fake Workshop ID and filters manifest to requested assets");
        Check(enginePlan.Fingerprint==AuthorizedManifest.FromAppDepot(Guid.NewGuid().ToString(),431961,456,engineManifest,key,[Server()],matched.Values.ToHashSet(StringComparer.Ordinal)).Fingerprint,
            "engine asset cache identity binds selected manifest content while excluding login session");
        Check(EngineAssetCatalog.Match(Manifest("assets/materials/particle/halo.tex"),engineRequest) is null,
            "manifest missing any requested engine asset fails closed");
        var inspectManifest=Manifest("assets/materials/particle/halo.tex");
        inspectManifest.Files!.Add(Manifest("assets/fonts/Alcubierre.otf").Files![0]);
        inspectManifest.Files!.Add(Manifest("assets/shaders/common_blending.h").Files![0]);
        inspectManifest.Files.Add(Manifest("packages/engine_assets.pkg").Files![0]);
        inspectManifest.Files.Add(Manifest("assets/packages/runtime.pkg").Files![0]);
        inspectManifest.Files.Add(Manifest("assets_runtime.pkg").Files![0]);
        inspectManifest.Files.Add(Manifest("resources/shader_bundle.pkg").Files![0]);
        inspectManifest.Files.Add(Manifest("private/account-name.txt").Files![0]);
        for(int i=0;i<300;i++) inspectManifest.Files.Add(Manifest($"assets/shaders/unrelated_{i}.h").Files![0]);
        var inspected=EngineAssetCatalog.Inspect(inspectManifest,engineRequest);
        Check(inspected.SequenceEqual(new[]{"assets/fonts/Alcubierre.otf","assets/materials/particle/halo.tex","assets/packages/runtime.pkg","assets/shaders/common_blending.h","assets_runtime.pkg","resources/shader_bundle.pkg"}),
            "metadata inspection returns only exact requested resources and fixed-root archive candidates despite hundreds of unrelated assets");
        var tooManyArchives=Manifest("assets/packages/archive_0.pkg");
        for(int i=1;i<193;i++) tooManyArchives.Files!.Add(Manifest($"assets/packages/archive_{i}.pkg").Files![0]);
        try { _=EngineAssetCatalog.Inspect(tooManyArchives,engineRequest);throw new Exception("truncated archive inspection"); }
        catch(ContentFailure e) { Check(e.Code=="engine_asset_inspection_limit","too many relevant archives fail explicitly instead of reporting false absence"); }
        var inventoryManifest=Manifest("assets/shaders/common.h",[1]);Set(inventoryManifest,"DepotID",431961u);Set(inventoryManifest,"ManifestGID",900UL);
        foreach(string path in new[]{"assets/effects/clock/effect.json","assets/materials/clock.tex","assets/particles/spark.json",
            "assets/fonts/Alcubierre.otf","assets/scripts/jsclasses/baseclasses.js","assets/models/clock.json","assets/root.bin",
            "assets/new_namespace/data.raw","assets/packages/resources.pkg","bin/outside.dll","assets/bin/prohibited.dll"})
            inventoryManifest.Files!.Add(Manifest(path,[1,2]).Files![0]);
        var inventory=EngineManifestInventoryBuilder.Build([(431961,900,inventoryManifest)]);
        Check(inventory.Complete && inventory.Files.Count==10 && inventory.Groups.Select(g=>g.Category).ToHashSet().SetEquals(
            ["shaders","effects","materials","particles","fonts","scripts","models","assets-root","other-assets"]),
            "diagnostic inventory classifies all fixed resource roots plus root and unknown assets without treating prefixes as download grants");
        Check(inventory.Files.Any(f=>f.ManifestPath=="assets/packages/resources.pkg"&&f.ArchiveCandidate) &&
            inventory.Files.All(f=>f.ManifestPath.StartsWith("assets/",StringComparison.Ordinal)&&!f.ManifestPath.EndsWith(".dll",StringComparison.OrdinalIgnoreCase)) &&
            inventory.ExcludedExecutableCount==1 && inventory.ExcludedExecutableBytes==2,
            "diagnostic inventory separates archives and accounts for prohibited executable metadata without exposing it as an asset file");
        Check(inventory.Files.All(f=>f.SHA1.Length==40&&f.SizeBytes>0&&f.DepotID==431961&&f.ManifestID==900),
            "private inventory file rows retain normalized logical path manifest identity size and hash metadata");
        var runtimePlan=AuthorizedManifest.FromSceneRuntimeAssets(id,431961,900,inventoryManifest,key,[Server()]);
        Check(runtimePlan.Dataset=="scene_runtime_assets"&&runtimePlan.PublishedFileID==0&&runtimePlan.Files.Count==10&&
            runtimePlan.Files.All(f=>f.Path.StartsWith("assets/",StringComparison.Ordinal)&&!f.Path.EndsWith(".dll",StringComparison.OrdinalIgnoreCase)),
            "fixed Scene runtime dataset selects every safe assets file while excluding executable metadata");
        Check((ulong)runtimePlan.TotalBytes==inventory.TotalBytes&&runtimePlan.Files.Select(f=>f.Path).SequenceEqual(inventory.Files.Select(f=>f.ManifestPath)),
            "runtime download selection exactly matches the complete diagnostic inventory order and bytes");
        var oversizedRuntime=Manifest("assets/materials/0.tex",[1]);Set(oversizedRuntime,"DepotID",431961u);Set(oversizedRuntime,"ManifestGID",904UL);
        for(int i=1;i<=4096;i++) oversizedRuntime.Files!.Add(Manifest($"assets/materials/{i}.tex",[1]).Files![0]);
        try{_=AuthorizedManifest.FromSceneRuntimeAssets(id,431961,904,oversizedRuntime,key,[Server()]);throw new Exception("oversized runtime dataset accepted");}
        catch(ContentFailure e){Check(e.Code=="scene_runtime_manifest_limit","Scene runtime dataset file-count limit fails instead of truncating the tree");}
        var secondInventory=Manifest("assets/shaders/common.h",[3]);Set(secondInventory,"DepotID",431962u);Set(secondInventory,"ManifestGID",901UL);
        var multiInventory=EngineManifestInventoryBuilder.Build([(431961,900,inventoryManifest),(431962,901,secondInventory)]);
        Check(multiInventory.Files.Count(f=>f.LogicalPath=="shaders/common.h")==2,
            "same logical asset in distinct depot manifests remains explicit instead of silently choosing an authority");
        var emptyAssetDepot=Manifest("bin/runtime.dat",[3]);Set(emptyAssetDepot,"DepotID",431966u);Set(emptyAssetDepot,"ManifestGID",905UL);
        Check(SceneRuntimeAssetCatalog.HasSafeAssetFiles(431961,900,inventoryManifest)&&
              !SceneRuntimeAssetCatalog.HasSafeAssetFiles(431966,905,emptyAssetDepot),
            "runtime authority is determined by safe assets ownership rather than total public Windows depot count");
        var unsafeInventory=Manifest("assets/shaders/link.h",[1]);Set(unsafeInventory,"DepotID",431961u);Set(unsafeInventory,"ManifestGID",902UL);Set(unsafeInventory.Files![0],"LinkTarget","private");
        try { _=EngineManifestInventoryBuilder.Build([(431961,902,unsafeInventory)]);throw new Exception("inventory accepted manifest link"); }
        catch(ContentFailure e) { Check(e.Code=="engine_inventory_manifest_invalid","diagnostic inventory rejects manifest links without following them"); }
        var excessiveInventory=Manifest("assets/materials/0.tex",[1]);Set(excessiveInventory,"DepotID",431961u);Set(excessiveInventory,"ManifestGID",903UL);
        for(int i=1;i<=EngineManifestInventoryBuilder.MaximumFiles;i++) excessiveInventory.Files!.Add(Manifest($"assets/materials/{i}.tex",[1]).Files![0]);
        try { _=EngineManifestInventoryBuilder.Build([(431961,903,excessiveInventory)]);throw new Exception("inventory truncated oversized manifest"); }
        catch(ContentFailure e) { Check(e.Code=="engine_inventory_manifest_invalid","oversized manifest fails explicitly instead of returning a truncated complete report"); }
        void Bad(Action<PublishedFileDetails,DepotManifest> mutate,string name)
        {
            var d=Details();var m=Manifest();mutate(d,m);
            try {AuthorizedManifest.FromSDK(id,d,123,431960,m,key,[Server()]);throw new Exception("accepted "+name);}catch(ContentFailure){Check(true,name);}
        }
        Bad((d,m)=>d.consumer_appid=999,"foreign-app UGC rejected");
        Bad((d,m)=>d.publishedfileid=124,"wrong published item rejected");
        Bad((d,m)=>d.result=15,"denied UGC result rejected");
        Bad((d,m)=>d.file_type=2,"collections rejected, never recursively expand an account grant");
        Bad((d,m)=>d.file_url="https://example.invalid/content","legacy direct URL explicitly unavailable rather than spoofed as manifest");
        Bad((d,m)=>d.banned=true,"banned item rejected");
        Bad((d,m)=>Set(m,"DepotID",123u),"mismatched depot rejected");
        Bad((d,m)=>Set(m,"ManifestGID",987UL),"mismatched authorized manifest ID rejected");
        Bad((d,m)=>Set(m,"FilenamesEncrypted",true),"undecrypted file names rejected");
        Bad((d,m)=>Set(m.Files![0],"FileName","../outside"),"traversal path rejected");
        Bad((d,m)=>Set(m.Files![0],"FileName","/absolute"),"absolute path rejected");
        Bad((d,m)=>Set(m.Files![0],"FileName","x//y"),"empty path component rejected");
        Bad((d,m)=>Set(m.Files![0],"LinkTarget","/outside"),"manifest link target rejected");
        Bad((d,m)=>Set(m.Files![0],"Flags",EDepotFileFlag.Symlink|EDepotFileFlag.Directory),"symlink file flag rejected");
        Bad((d,m)=>Set(m.Files![0].Chunks[0],"Offset",1UL),"chunk gap rejected");
        Bad((d,m)=>Set(m.Files![0].Chunks[0],"UncompressedLength",0u),"zero-size chunk rejected");
        Bad((d,m)=>Set(m.Files![0].Chunks[0],"CompressedLength",uint.MaxValue),"oversized compressed chunk rejected before allocation");
        Bad((d,m)=>Set(m.Files![0],"FileHash",new byte[19]),"missing full-file hash rejected");
        Bad((d,m)=>m.Files!.Add(m.Files![0]),"duplicate paths rejected");
        var ordered=Manifest("z.bin");ordered.Files!.Add(Manifest("a.bin").Files![0]);
        var stableA=Plan(id,ordered);ordered.Files.Reverse();var stableB=Plan(id,ordered);
        Check(stableA.Fingerprint==stableB.Fingerprint && stableA.Files.SelectMany(f=>f.Chunks).Select(c=>(c.Index,c.Path)).SequenceEqual(stableB.Files.SelectMany(f=>f.Chunks).Select(c=>(c.Index,c.Path))),"checkpoint indices stable across equivalent SDK file ordering");
        var s=Server();Check(CDNBoundary.ValidServer(s),"CM-provided HTTPS CDN server shape accepted");
        Set(s,"Protocol",SteamKit2.CDN.Server.ConnectionProtocol.HTTP);Check(!CDNBoundary.ValidServer(s),"HTTP-only CDN has explicit unsupported boundary");
        Set(s,"Protocol",SteamKit2.CDN.Server.ConnectionProtocol.HTTPS);Set(s,"VHost","127.0.0.1");Check(!CDNBoundary.ValidServer(s),"production loopback CDN rejected");
        Check(SteamKitSession.Retryable(new TaskCanceledException(), CancellationToken.None), "SDK CDN internal timeout is retryable");
        using(var cancelled=new CancellationTokenSource())
        {
            cancelled.Cancel();
            Check(!SteamKitSession.Retryable(new TaskCanceledException(), cancelled.Token), "caller cancellation is not converted into CDN retry");
        }
        var forbidden=new HttpRequestException("fixture", null, HttpStatusCode.Forbidden);
        Check(SteamKitSession.NeedsToken(forbidden, null, CancellationToken.None) &&
            !SteamKitSession.NeedsToken(forbidden, "already-present", CancellationToken.None),
            "CDN auth token is requested only after an unauthenticated 403");
        foreach(string ip in new[]{"127.0.0.1","10.0.0.1","172.16.0.1","192.168.1.1","169.254.2.3","100.64.1.1","::1","::","fe80::1","fc00::1","::ffff:127.0.0.1"})
            Check(!SteamHTTP.IsPublic(IPAddress.Parse(ip)),"private/reserved connection target blocked "+ip);
    }
    private static async Task DirectoryCapabilities()
    {
        CContentServerDirectory_ServerInfo Raw(string capability = "optional") => new()
        { type = "SteamCache", host = "origin.steamcontent.com", vhost = "edge.steamcontent.com", https_support = capability,
          source_id = 13, cell_id = 42, load = 7, weighted_load = 1.5f, num_entries_in_client_list = 3, steam_china_only = true };
        CDNDirectorySelection Select(params CContentServerDirectory_ServerInfo[] records)
        { var r = new CContentServerDirectory_GetServersForSteamPipe_Response(); r.servers.AddRange(records); return CDNServerDirectory.Select(r); }
        var raw = Raw(); raw.allowed_app_ids.Add(431960);
        var sdkResponse = new CContentServerDirectory_GetServersForSteamPipe_Response(); sdkResponse.servers.Add(raw);
        var converted = (IReadOnlyCollection<Server>)typeof(ContentServerDirectoryService).GetMethod("ConvertServerList", BindingFlags.NonPublic|BindingFlags.Static)!.Invoke(null, [sdkResponse])!;
        Check(converted.Single().Protocol == SteamKit2.CDN.Server.ConnectionProtocol.HTTP && converted.Single().Port == 80, "pinned SDK reproduces optional HTTPS capability loss before adapter");
        var selected = Select(raw); var server = selected.Servers.Single();
        Check(server.Protocol == SteamKit2.CDN.Server.ConnectionProtocol.HTTPS && server.Port == 443 && CDNBoundary.ValidServer(server), "explicit optional HTTPS promoted to strict TLS443 transport");
        Check(server.Host == raw.host && server.VHost == raw.vhost && server.Host != server.VHost && server.Type == raw.type, "distinct original host and virtual TLS host preserved");
        Check(SteamKitSession.TokenHost(server) == raw.host, "CDN token request uses directory host rather than TLS virtual host");
        Check(server.SourceID == 13 && server.CellID == 42 && server.Load == 7 && server.WeightedLoad == 1.5f && server.NumEntries == 3 && server.SteamChinaOnly, "directory routing and ranking metadata preserved");
        raw.allowed_app_ids.Clear(); Check(server.AllowedAppIds.SequenceEqual(new uint[]{431960}), "allowed app grant copied without mutable protobuf alias");
        Check(Select(Raw("mandatory")).Servers.Single().Protocol == SteamKit2.CDN.Server.ConnectionProtocol.HTTPS, "mandatory TLS remains supported");
        foreach (string capability in new[]{"unavailable", "", "none", "OPTIONAL", "future", "optional "})
            Check(Select(Raw(capability)).Servers.Length == 0, "no TLS upgrade for unknown or unavailable capability: " + capability);
        foreach (string type in new[]{"CDN", "SteamCache"}) { var x=Raw();x.type=type;Check(Select(x).Servers.Length==1,"supported raw directory type accepted: "+type); }
        void Denied(Action<CContentServerDirectory_ServerInfo> mutate, string message)
        { var x=Raw(); mutate(x); Check(Select(x).Servers.Length==0,message); }
        Denied(x=>x.type="unknown", "unknown CDN type rejected");
        Denied(x=>x.use_as_proxy=true, "proxy not upgraded into direct CDN");
        Denied(x=>x.allowed_app_ids.Add(999), "foreign-app-only directory candidate rejected");
        Denied(x=>x.vhost="127.0.0.1", "raw private IP virtual host rejected before construction");
        Denied(x=>x.host="private.local", "raw private host remains rejected");
        Denied(x=>x.vhost="https://injected.example", "URL injection cannot become TLS hostname");
        Denied(x=>x.weighted_load=float.NaN, "nonfinite ranking rejected");
        var denied = Raw("unavailable"); denied.host="should-not-serialize.secret.example";
        var diagnostics = JsonSerializer.Serialize(Select(denied).Diagnostics, Wire.Json);
        Check(!diagnostics.Contains("secret") && !diagnostics.Contains("host") && !diagnostics.Contains("token") && diagnostics.Contains("https_not_advertised"), "bounded directory diagnostics expose capability counts only, no hosts URLs or tokens");
        var over = new CContentServerDirectory_GetServersForSteamPipe_Response(); for(int i=0;i<513;i++)over.servers.Add(Raw());
        await Reject(()=>Task.FromResult(CDNServerDirectory.Select(over)), "oversized directory response rejected", "cdn_directory_limit");
        CContentServerDirectory_GetServersForSteamPipe_Response Response(params CContentServerDirectory_ServerInfo[] values)
        { var value=new CContentServerDirectory_GetServersForSteamPipe_Response();value.servers.AddRange(values);return value; }
        var requestedCells = new List<uint>();
        int publicRequests=0;
        var fallback = await CDNServerDirectory.Find(42, cell=> { requestedCells.Add(cell); return Task.FromResult(Response(Raw("unavailable"))); },
            ()=> { publicRequests++; return Task.FromResult(Response(Raw("mandatory"))); }, CancellationToken.None);
        Check(requestedCells.SequenceEqual(new uint[]{42,0}) && fallback.Servers.Length==1, "empty preferred TLS pool queries global directory once in same injected session");
        Check(publicRequests==1 && fallback.Diagnostics.Total==3 && fallback.Diagnostics.Accepted==1 && fallback.Diagnostics.Groups.Sum(g=>g.Count)==3, "empty CM pools query public global directory once and aggregate bounded diagnostics");
        requestedCells.Clear();
        publicRequests=0;
        _=await CDNServerDirectory.Find(42, cell=> { requestedCells.Add(cell); return Task.FromResult(Response(Raw())); },
            ()=> { publicRequests++; return Task.FromResult(Response(Raw())); }, CancellationToken.None);
        Check(requestedCells.SequenceEqual(new uint[]{42}) && publicRequests==0, "usable preferred TLS candidate does not perform fallback");
        requestedCells.Clear();
        publicRequests=0;
        var cmGlobal=await CDNServerDirectory.Find(42, cell=> { requestedCells.Add(cell); return Task.FromResult(Response(Raw(cell==0 ? "mandatory" : "unavailable"))); },
            ()=> { publicRequests++; return Task.FromResult(Response(Raw())); }, CancellationToken.None);
        Check(requestedCells.SequenceEqual(new uint[]{42,0}) && publicRequests==0 && cmGlobal.Servers.Length==1,
            "usable global CM candidate does not query public directory");
        requestedCells.Clear();
        publicRequests=0;
        var emptyGlobal=await CDNServerDirectory.Find(0, cell=> { requestedCells.Add(cell); return Task.FromResult(Response(Raw("unavailable"))); },
            ()=> { publicRequests++; return Task.FromResult(Response(Raw("future"))); }, CancellationToken.None);
        Check(requestedCells.SequenceEqual(new uint[]{0}) && publicRequests==1 && emptyGlobal.Servers.Length==0, "unknown public TLS capability fails closed after one request");
        publicRequests=0;
        var appRestricted=await CDNServerDirectory.Find(0, _=>Task.FromResult(Response(Raw("unavailable"))), ()=>
        { publicRequests++; var x=Raw();x.allowed_app_ids.Add(999);return Task.FromResult(Response(x)); }, CancellationToken.None);
        Check(publicRequests==1 && appRestricted.Servers.Length==0, "foreign-app public candidate fails closed");
        await Reject(()=>CDNServerDirectory.Find(0, _=>Task.FromResult(Response(Raw("unavailable"))),
            ()=>throw new HttpRequestException("controlled public failure"), CancellationToken.None),
            "public directory failure becomes fixed redacted code", "cdn_directory_public_failed");
        using(var cancel=new CancellationTokenSource())
        {
            requestedCells.Clear();
            publicRequests=0;
            await Reject(async()=>await CDNServerDirectory.Find(42,cell=> { requestedCells.Add(cell);cancel.Cancel();return Task.FromResult(Response(Raw("unavailable"))); },
                ()=> { publicRequests++; return Task.FromResult(Response(Raw())); },cancel.Token), "cancelled directory lookup never starts global fallback");
            Check(requestedCells.SequenceEqual(new uint[]{42}) && publicRequests==0, "directory cancellation preserves single-call boundary");
        }
        using(var cancel=new CancellationTokenSource())
        {
            requestedCells.Clear();publicRequests=0;
            await Reject(async()=>await CDNServerDirectory.Find(42,cell=>
            {
                requestedCells.Add(cell);if(cell==0)cancel.Cancel();return Task.FromResult(Response(Raw("unavailable")));
            },()=> { publicRequests++; return Task.FromResult(Response(Raw())); },cancel.Token),
                "cancellation after global CM response prevents public request");
            Check(requestedCells.SequenceEqual(new uint[]{42,0}) && publicRequests==0, "cancelled global fallback never invokes public fetch");
        }
        var unsafeHandler=new CapturedResponse([]);
        var deniedCandidate=Raw("unavailable");
        foreach(var candidate in Select(deniedCandidate).Servers) { using var unused=new HttpClient(unsafeHandler); await unused.GetAsync("https://unused.example"); }
        Check(unsafeHandler.URI is null, "unadvertised TLS candidates produce no HTTP handler invocation");
        string sha=Convert.ToHexString(SHA1.HashData(payload)).ToLowerInvariant();byte[] encrypted=Encrypt(payload);
        var scope = new CDNRequestScope(server.VHost!, $"/depot/431960/chunk/{sha}", encrypted.Length, false, CancellationToken.None);
        var capture = new CapturedResponse(encrypted);
        var client = new SteamClient(SteamConfiguration.Create(b=>b.WithHttpClientFactory(_=>new HttpClient(new CDNBoundaryHandler(scope,capture)))));
        using var cdn = new Client(client);var output=new byte[payload.Length];
        int count=await cdn.DownloadDepotChunkAsync(431960,Manifest().Files![0].Chunks[0],server,output,key);
        Check(count==payload.Length && output.SequenceEqual(payload), "actual SDK optional-CDN chunk decrypt and checksum succeeds through strict production request scope");
        Check(capture.URI is { Scheme: "https", Port: 443 } && capture.URI.Host==server.VHost, "actual SDK emits HTTPS443 virtual-host URI without HTTP fallback (controlled handler, no network)");
        using var http = new HttpClient(new CDNBoundaryHandler(scope,new CapturedResponse(encrypted)));
        await Reject(async()=>await http.GetAsync($"http://{server.VHost}{scope.Path}"), "optional candidate never permits plaintext request", "cdn_request_outside_authorized_scope");
    }
    private sealed class CapturedResponse(byte[] body) : HttpMessageHandler
    {
        internal Uri? URI;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        { URI=request.RequestUri;return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){ Content=new ByteArrayContent(body) }); }
    }
    private static async Task HTTPAndDisk(string root)
    {
        var memoryBudget=new RuntimeTransferBudget();
        var memoryLeases=new[]{await memoryBudget.Acquire(36L*1024*1024,CancellationToken.None),
            await memoryBudget.Acquire(36L*1024*1024,CancellationToken.None),await memoryBudget.Acquire(36L*1024*1024,CancellationToken.None)};
        var fourthMemory=memoryBudget.Acquire(36L*1024*1024,CancellationToken.None).AsTask();await Task.Delay(25);
        Check(!fourthMemory.IsCompleted,"runtime transfer budget blocks before aggregate chunk memory can exceed 128MiB");
        memoryLeases[0].Dispose();using(await fourthMemory){}memoryLeases[1].Dispose();memoryLeases[2].Dispose();
        using(var held=await memoryBudget.Acquire(120L*1024*1024,CancellationToken.None))
        using(var budgetCancel=new CancellationTokenSource())
        {
            var partial=memoryBudget.Acquire(16L*1024*1024,budgetCancel.Token).AsTask();await Task.Delay(25);budgetCancel.Cancel();
            await Reject(async()=>{using(await partial){}},"cancelled weighted memory wait releases partially acquired permits");
        }
        using(await memoryBudget.Acquire(RuntimeTransferBudget.CapacityBytes,CancellationToken.None)){}
        using(var tokenGates=new CDNTokenGatePool())
        {
            int active=0,maximum=0;
            async Task Enter(int host)
            {
                using(await tokenGates.Enter((431961,"host"+host),CancellationToken.None))
                {int now=Interlocked.Increment(ref active);int seen;while(now>(seen=Volatile.Read(ref maximum)))Interlocked.CompareExchange(ref maximum,now,seen);await Task.Delay(15);Interlocked.Decrement(ref active);}
            }
            await Task.WhenAll(Enumerable.Range(0,8).Select(_=>Enter(1)));
            Check(maximum==1,"same depot and CDN host serializes first-token acquisition");
            maximum=0;await Task.WhenAll(Enter(1),Enter(2));
            Check(maximum==2,"independent CDN token hosts do not serialize unrelated requests");
        }
        using var server=new LocalServer();
        string id=Guid.NewGuid().ToString();byte[] encrypted=Encrypt(payload);string sha=Convert.ToHexString(SHA1.HashData(payload)).ToLowerInvariant();
        server.Routes[$"/depot/431960/chunk/{sha}"]=encrypted;
        var context=new CDNRequestScope("127.0.0.1",$"/depot/431960/chunk/{sha}",encrypted.Length,false,CancellationToken.None,Fixture:true);
        var client=new SteamClient(SteamConfiguration.Create(b=>b.WithHttpClientFactory(_=>new HttpClient(new CDNBoundaryHandler(context,SteamHTTP.Handler(true))))));
        var chunk=Manifest().Files![0].Chunks[0];
        using(var cdn=new Client(client))
        {
            var output=new byte[payload.Length];int count=await cdn.DownloadDepotChunkAsync(431960,chunk,Server(true,server.Port),output,key);
            Check(count==payload.Length && output.SequenceEqual(payload),"actual official SDK CDN request + decrypt + checksum via loopback");
        }
        using(var data=new MemoryStream())
        {
            Manifest().Serialize(data);server.Routes["/depot/431960/manifest/456/5/789"]=Zip(data.ToArray());
            var scope=new CDNRequestScope("127.0.0.1","/depot/431960/manifest/456/5/789",32*1024*1024,true,CancellationToken.None,Fixture:true);
            var c=new SteamClient(SteamConfiguration.Create(b=>b.WithHttpClientFactory(_=>new HttpClient(new CDNBoundaryHandler(scope,SteamHTTP.Handler(true))))));
            using var cdn=new Client(c);var manifest=await cdn.DownloadManifestAsync(431960,456,789,Server(true,server.Port),key);
            Check(manifest.DepotID==431960 && manifest.ManifestGID==456 && manifest.Files!.Count==1,"actual SDK serialized manifest ZIP traverses bounded HTTP adapter and SDK parser");
        }
        using(var http=new HttpClient(new CDNBoundaryHandler(context,SteamHTTP.Handler(true))))
        {
            await Reject(async()=>await http.GetAsync($"http://127.0.0.1:{server.Port}/unexpected"),"request path outside granted chunk rejected before network","cdn_request_outside_authorized_scope");
        }
        using(var zipStream=new MemoryStream())
        {
            using(var zip=new ZipArchive(zipStream,ZipArchiveMode.Create,true)){using(var a=zip.CreateEntry("a").Open()){a.WriteByte(1);}using(var b=zip.CreateEntry("b").Open()){b.WriteByte(2);}}
            await Reject(()=>Task.Run(()=>CDNBoundaryHandler.ValidateManifestEnvelope(zipStream.ToArray())),"multiple-entry manifest ZIP rejected","manifest_zip_limit");
        }
        using(var zipStream=new MemoryStream())
        {
            using(var zip=new ZipArchive(zipStream,ZipArchiveMode.Create,true)){using var a=zip.CreateEntry("a").Open();a.Write(new byte[16*1024*1024+1]);}
            await Reject(()=>Task.Run(()=>CDNBoundaryHandler.ValidateManifestEnvelope(zipStream.ToArray())),"decompression bomb size rejected before SDK parse","manifest_zip_limit");
        }
        byte[] invalidFraming=BitConverter.GetBytes(0x71f617d0u).Concat(BitConverter.GetBytes(uint.MaxValue)).Concat(new byte[]{1,2,3}).ToArray();
        await Reject(()=>Task.Run(()=>CDNBoundaryHandler.ValidateManifestEnvelope(Zip(invalidFraming))),"oversized declared protobuf section rejected before SDK allocation","manifest_section_bounds");
        var adapter=new FakeSession(id){Authenticated=true,Server=server};
        var progress=new List<TransferCounters>();var job=new ManifestDownload(adapter,root,progress.Add);
        var plan=Plan(id);string relative=await job.Run(plan,CancellationToken.None);
        Check(File.ReadAllBytes(Path.Combine(root,relative,"textures/original.bin")).SequenceEqual(payload),"authorized nested managed output equals original bytes");
        Check(job.Counters.DownloadedVerifiedBytes==payload.Length.ToString() && job.Counters.ReceivedPayloadBytes==encrypted.Length.ToString(),"production download engine uses true SDK received and verified counters");
        Check(plan.DepotKey.All(b=>b==0),"depot key dropped and zeroed after transfer");
        string journal=File.ReadAllText(Path.Combine(root,"items/123/456/checkpoint.json"));
        Check(!journal.Contains("http") && !journal.Contains("depotKey") && !journal.Contains("fixture-password") && journal.Contains("completedChunkIndices"),"checkpoint contains safe indices and identity only, no secret or URL");
        var engineManifest=Manifest("assets/materials/particle/halo.tex");Set(engineManifest,"DepotID",431961u);
        var selected=new HashSet<string>(["assets/materials/particle/halo.tex"],StringComparer.Ordinal);
        var enginePlan=AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected);
        server.Routes[$"/depot/431961/chunk/{sha}"]=encrypted;
        var engineJob=new ManifestDownload(adapter,root,_=>{});
        string engineRelative=await engineJob.Run(enginePlan,CancellationToken.None,$"engine-assets/{enginePlan.Fingerprint}");
        Check(engineRelative==$"engine-assets/{enginePlan.Fingerprint}/content" &&
            File.ReadAllBytes(Path.Combine(root,engineRelative,"assets/materials/particle/halo.tex")).SequenceEqual(payload),
            "engine asset content is written only below manifest-fingerprint cache scope");
        string engineJournal=File.ReadAllText(Path.Combine(root,$"engine-assets/{enginePlan.Fingerprint}/checkpoint.json"));
        Check(engineJournal.Contains("scene_engine_assets") && !engineJournal.Contains("publishedFileID"),
            "engine asset checkpoint preserves app/depot/manifest identity without fake Workshop ID");
        var runtimeDiskPlan=AuthorizedManifest.FromSceneRuntimeAssets(id,431961,456,engineManifest,key,[Server()]);
        var runtimeJob=new ManifestDownload(adapter,root,_=>{});
        string runtimeRelative=await runtimeJob.Run(runtimeDiskPlan,CancellationToken.None,$"scene-runtime-assets/{runtimeDiskPlan.Fingerprint}");
        Check(runtimeRelative==$"scene-runtime-assets/{runtimeDiskPlan.Fingerprint}/content"&&
            File.ReadAllBytes(Path.Combine(root,runtimeRelative,"assets/materials/particle/halo.tex")).SequenceEqual(payload)&&
            File.ReadAllText(Path.Combine(root,$"scene-runtime-assets/{runtimeDiskPlan.Fingerprint}/checkpoint.json")).Contains("scene_runtime_assets"),
            "Scene runtime dataset uses its isolated cache namespace and typed resumable checkpoint");
        int runtimeHits=server.Hits;var runtimeRepeat=new ManifestDownload(adapter,root,_=>{});
        await runtimeRepeat.Run(AuthorizedManifest.FromSceneRuntimeAssets(id,431961,456,engineManifest,key,[Server()]),
            CancellationToken.None,$"scene-runtime-assets/{runtimeDiskPlan.Fingerprint}");
        Check(server.Hits==runtimeHits&&runtimeRepeat.Counters.ReusedVerifiedBytes==payload.Length.ToString(),
            "stable Scene runtime manifest reuses only fully revalidated private cache bytes");
        DepotManifest MultiManifest(uint depot,int count,int seed,out List<(string Path,byte[] Data,string Route)> rows)
        {
            rows=[];DepotManifest? result=null;
            for(int i=0;i<count;i++)
            {
                string path=$"assets/parallel/{i:D2}.bin";
                byte[] data=Enumerable.Range(0,2048).SelectMany(n=>SHA256.HashData(BitConverter.GetBytes(seed+i*4096+n))).ToArray();
                var one=Manifest(path,data);Set(one,"DepotID",depot);
                result ??= one;if(!ReferenceEquals(result,one))result.Files!.Add(one.Files![0]);
                string route=$"/depot/{depot}/chunk/{Convert.ToHexString(SHA1.HashData(data)).ToLowerInvariant()}";
                server.Routes[route]=Encrypt(data);rows.Add((path,data,route));
            }
            return result!;
        }
        var parallelManifest=MultiManifest(431961,16,1000,out var parallelRows);
        var parallelPlan=AuthorizedManifest.FromSceneRuntimeAssets(id,431961,456,parallelManifest,key,[Server()]);
        foreach(var row in parallelRows.Skip(4))server.Slow[row.Route]=true;
        adapter.ResetConcurrency();using(var parallelCancel=new CancellationTokenSource())
        {
            var parallelJob=new ManifestDownload(adapter,root,_=>{});
            var operation=parallelJob.Run(parallelPlan,parallelCancel.Token,$"scene-runtime-assets/{parallelPlan.Fingerprint}");
            await Until(()=>adapter.MaximumDownloads==8&&long.Parse(parallelJob.Counters.DownloadedVerifiedBytes)>0);
            parallelCancel.Cancel();await Reject(async()=>await operation.WaitAsync(TimeSpan.FromSeconds(3)),"runtime parallel cancellation drains every in-flight loopback CDN request");
            int stoppedHits=server.Hits;await Task.Delay(100);
            Check(adapter.ActiveDownloads==0&&server.Hits==stoppedHits&&adapter.MaximumDownloads<=8,
                "runtime cancellation leaves no late writes or requests and never exceeds eight workers");
            using var checkpoint=JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root,$"scene-runtime-assets/{parallelPlan.Fingerprint}/checkpoint.json")));
            var indices=checkpoint.RootElement.GetProperty("completedChunkIndices").EnumerateArray().Select(x=>x.GetInt32()).ToArray();
            Check(indices.Length>0&&indices.SequenceEqual(indices.Order())&&indices.Distinct().Count()==indices.Length,
                "parallel checkpoint publication is serialized and contains sorted unique completed chunks");
        }
        server.Slow.Clear();adapter.ResetConcurrency();
        var resumedPlan=AuthorizedManifest.FromSceneRuntimeAssets(id,431961,456,parallelManifest,key,[Server()]);
        var resumedRuntime=new ManifestDownload(adapter,root,_=>{});
        string resumedRelative=await resumedRuntime.Run(resumedPlan,CancellationToken.None,$"scene-runtime-assets/{resumedPlan.Fingerprint}");
        Check(adapter.MaximumDownloads>1&&adapter.MaximumDownloads<=8&&long.Parse(resumedRuntime.Counters.ReusedVerifiedBytes)>0&&
            long.Parse(resumedRuntime.Counters.DownloadedVerifiedBytes)>0&&parallelRows.All(row=>File.ReadAllBytes(Path.Combine(root,resumedRelative,row.Path)).SequenceEqual(row.Data)),
            "runtime resume revalidates cancelled cache and bounded workers complete every file through loopback CDN");
        string failureRoot=Path.Combine(root,"runtime-internal-failure");Directory.CreateDirectory(failureRoot,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        var failureManifest=MultiManifest(431961,1,4000,out _);adapter.NextFailure=new IOException("private-host-token-path");
        var failurePlan=AuthorizedManifest.FromSceneRuntimeAssets(id,431961,456,failureManifest,key,[Server()]);
        await Reject(()=>new ManifestDownload(adapter,failureRoot,_=>{}).Run(failurePlan,CancellationToken.None,$"scene-runtime-assets/{failurePlan.Fingerprint}"),
            "runtime worker maps generic I/O to a fixed safe transfer phase and category","scene_runtime_transfer_io");
        string serialRoot=Path.Combine(root,"serial-datasets");Directory.CreateDirectory(serialRoot,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        var serialWorkshopManifest=MultiManifest(431960,4,2000,out _);adapter.ResetConcurrency();
        await new ManifestDownload(adapter,serialRoot,_=>{}).Run(Plan(id,serialWorkshopManifest),CancellationToken.None);
        Check(adapter.MaximumDownloads==1,"Workshop manifest retains the original sequential transfer path");
        var serialEngineManifest=MultiManifest(431961,4,3000,out var serialEngineRows);adapter.ResetConcurrency();
        var serialEnginePlan=AuthorizedManifest.FromAppDepot(id,431961,456,serialEngineManifest,key,[Server()],serialEngineRows.Select(x=>x.Path).ToHashSet(StringComparer.Ordinal));
        await new ManifestDownload(adapter,root,_=>{}).Run(serialEnginePlan,CancellationToken.None,$"engine-assets/{serialEnginePlan.Fingerprint}");
        Check(adapter.MaximumDownloads==1,"small verified engine-asset manifest retains the original sequential transfer path");
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(
            AuthorizedManifest.FromSceneRuntimeAssets(id,431961,456,engineManifest,key,[Server()]),CancellationToken.None,$"engine-assets/{runtimeDiskPlan.Fingerprint}"),
            "Scene runtime dataset cannot be redirected into the small engine cache","engine_asset_destination_invalid");
        string activeReceipt=Path.Combine(root,"engine-assets/active-receipt.json");
        File.WriteAllText(activeReceipt,"{\"schemaVersion\":1}");
        File.SetUnixFileMode(activeReceipt,UnixFileMode.UserRead|UnixFileMode.UserWrite);
        byte[] receiptBefore=File.ReadAllBytes(activeReceipt);
        var repeatEngineJob=new ManifestDownload(adapter,root,_=>{});
        await repeatEngineJob.Run(AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected),
            CancellationToken.None,$"engine-assets/{enginePlan.Fingerprint}");
        Check(File.ReadAllBytes(activeReceipt).SequenceEqual(receiptBefore),
            "engine cache admission preserves the fixed private Scene resolver receipt while auditing fingerprint directories");
        string receiptLink=Path.Combine(root,"receipt-hardlink");Check(link(activeReceipt,receiptLink)==0,"hardlink fixture created");
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(
            AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected),CancellationToken.None,$"engine-assets/{enginePlan.Fingerprint}"),
            "hardlinked active Scene receipt fails cache admission","engine_asset_cache_invalid");
        File.Delete(receiptLink);
        File.SetUnixFileMode(activeReceipt,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.GroupRead);
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(
            AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected),CancellationToken.None,$"engine-assets/{enginePlan.Fingerprint}"),
            "nonprivate active Scene receipt fails cache admission","engine_asset_cache_invalid");
        File.SetUnixFileMode(activeReceipt,UnixFileMode.UserRead|UnixFileMode.UserWrite);
        File.Delete(activeReceipt);File.CreateSymbolicLink(activeReceipt,root);
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(
            AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected),CancellationToken.None,$"engine-assets/{enginePlan.Fingerprint}"),
            "symlink active Scene receipt fails cache admission without following it","engine_asset_cache_invalid");
        File.Delete(activeReceipt);File.WriteAllBytes(activeReceipt,receiptBefore);
        File.SetUnixFileMode(activeReceipt,UnixFileMode.UserRead|UnixFileMode.UserWrite);
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(
            AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected),CancellationToken.None,"engine-assets/arbitrary"),
            "engine asset downloader rejects caller-chosen cache destination","engine_asset_destination_invalid");
        string cacheRoot=Path.Combine(root,"engine-assets");
        for(int i=0;i<6;i++) Directory.CreateDirectory(Path.Combine(cacheRoot,i.ToString("x64")),
            UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        var nextManifest=Manifest("assets/materials/particle/halo.tex");Set(nextManifest,"DepotID",431961u);Set(nextManifest,"ManifestGID",457UL);
        var nextPlan=AuthorizedManifest.FromAppDepot(id,431961,457,nextManifest,key,[Server()],selected);
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(nextPlan,CancellationToken.None,$"engine-assets/{nextPlan.Fingerprint}"),
            "engine asset cache has explicit eight-entry admission bound","engine_asset_cache_limit");
        Directory.Delete(Path.Combine(cacheRoot,0.ToString("x64")));
        Directory.CreateSymbolicLink(Path.Combine(cacheRoot,0.ToString("x64")),root);
        var existingPlan=AuthorizedManifest.FromAppDepot(id,431961,456,engineManifest,key,[Server()],selected);
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(existingPlan,CancellationToken.None,$"engine-assets/{existingPlan.Fingerprint}"),
            "engine asset cache admission rejects symlink entries without following them","engine_asset_cache_invalid");
        int hits=server.Hits;var resume=new ManifestDownload(adapter,root,_=>{});await resume.Run(Plan(id),CancellationToken.None);
        Check(server.Hits==hits && resume.Counters.ReusedVerifiedBytes==payload.Length.ToString() && resume.Counters.ReceivedPayloadBytes=="0","real disk resume revalidates file and avoids CDN fetch");
        File.WriteAllBytes(Path.Combine(root,relative,"textures/original.bin"),new byte[payload.Length]);
        var corrupt=new ManifestDownload(adapter,root,_=>{});await corrupt.Run(Plan(id),CancellationToken.None);
        Check(corrupt.Counters.ReusedVerifiedBytes=="0" && corrupt.Counters.DownloadedVerifiedBytes==payload.Length.ToString(),"same-sized corrupted managed content is downloaded rather than reused");
        File.WriteAllText(Path.Combine(root,relative,"unexpected"),"not-in-manifest");
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(Plan(id),CancellationToken.None),"extra unlisted file prevents complete","final_content_tree_mismatch");File.Delete(Path.Combine(root,relative,"unexpected"));
        var other=Plan(Guid.NewGuid().ToString());await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(other,CancellationToken.None),"manifest from different login session cannot download","manifest_session_mismatch");
        var badFile=Manifest();Set(badFile.Files![0],"FileHash",new byte[20]);
        await Reject(()=>new ManifestDownload(adapter,root,_=>{}).Run(Plan(id,badFile),CancellationToken.None),"full-file hash independently checked after chunk acceptance","final_file_hash");
        string cancelRoot=Path.Combine(root,"cancel-owned");Directory.CreateDirectory(cancelRoot,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        server.Slow[$"/depot/431960/chunk/{sha}"]=true;
        using(var cancellation=new CancellationTokenSource())
        {
            var cancelled=new ManifestDownload(adapter,cancelRoot,_=>{});var operation=cancelled.Run(Plan(id),cancellation.Token);
            await Until(()=>long.Parse(cancelled.Counters.ReceivedPayloadBytes)>0);cancellation.Cancel();
            await Reject(async()=>await operation.WaitAsync(TimeSpan.FromSeconds(3)),"cancel reaches actual SDK HTTP body and drains before ACK");
            long bytes=long.Parse(cancelled.Counters.ReceivedPayloadBytes);await Task.Delay(100);
            Check(bytes>0 && bytes<encrypted.Length && cancelled.Counters.DownloadedVerifiedBytes=="0" && long.Parse(cancelled.Counters.ReceivedPayloadBytes)==bytes,"cancelled SDK content has no late counter callbacks or fake verified bytes");
            Check(new FileInfo(Path.Combine(cancelRoot,"items/123/456/content/textures/original.bin")).Length==0,"cancelled unverified SDK chunk never reaches managed output");
        }
        server.Slow.Clear();
        var afterCancel=new ManifestDownload(adapter,cancelRoot,_=>{});await afterCancel.Run(Plan(id),CancellationToken.None);
        Check(afterCancel.Counters.DownloadedVerifiedBytes==payload.Length.ToString(),"fresh epoch can resume cancelled SDK transfer using validated disk state");
        string privateRoot=Path.Combine(root,"private-second");Directory.CreateDirectory(privateRoot,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        string outside=Path.Combine(root,"outside-original");File.WriteAllText(outside,"original");
        Directory.CreateDirectory(Path.Combine(privateRoot,"items/123/456/content"),UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        Directory.CreateSymbolicLink(Path.Combine(privateRoot,"items/123/456/content/textures"),root);
        await Reject(()=>new ManifestDownload(adapter,privateRoot,_=>{}).Run(Plan(id),CancellationToken.None),"nested destination symlink rejected without following source");
        Check(File.ReadAllText(outside)=="original","external user source remains untouched");
    }
    private static async Task ProxyTransport()
    {
        Check(SteamHTTP.TrustedCMHost("cmp3-hkg1.steamserver.net") && SteamHTTP.TrustedCMHost("STEAMSERVER.NET"),
            "CM host boundary permits official Steam directory namespace");
        foreach (var host in new[] { "evilsteamserver.net", "steamserver.net.invalid", "127.0.0.1", "example.com" })
            Check(!SteamHTTP.TrustedCMHost(host), "CM host boundary rejects " + host);
        using (var cm = new HttpMessageInvoker(SteamHTTP.CMWebSocketHandler()))
        {
            foreach (int port in new[] { 444, 26999, 27051 })
                await Reject(async () => { using var response = await cm.SendAsync(new HttpRequestMessage(HttpMethod.Get,
                    $"https://cmp3-hkg1.steamserver.net:{port}/cmsocket/"), CancellationToken.None); },
                    "CM out-of-range port rejected before network " + port);
        }
        using (var api = new HttpMessageInvoker(SteamHTTP.Handler()))
            await Reject(async () => { using var response = await api.SendAsync(new HttpRequestMessage(HttpMethod.Get,
                "https://cmp3-hkg1.steamserver.net:27022/"), CancellationToken.None); },
                "WebAPI and CDN transport still reject non-443 ports");
        using (var proxy = new ConnectProxy("HTTP/1.1 200 Connection established\r\n\r\nZ"))
        {
            await using var tunnel = await SteamHTTP.ConnectTunnel(IPAddress.Parse("1.1.1.1"), 27022,
                new SteamHTTP.LoopbackProxy(IPAddress.Loopback, proxy.Port), CancellationToken.None);
            Check(tunnel.ReadByte() == 'Z', "CM tunnel preserves first TLS payload byte");
            await proxy.Done;
            Check(proxy.Request.StartsWith("CONNECT 1.1.1.1:27022 HTTP/1.1\r\nHost: 1.1.1.1:27022\r\n", StringComparison.Ordinal)
                && !proxy.Request.Contains("Authorization", StringComparison.OrdinalIgnoreCase),
                "CM CONNECT uses actual directory port without credentials");
        }
        foreach (int port in new[] { 444, 26999, 27051 })
            await Reject(async () => { await using var tunnel = await SteamHTTP.ConnectTunnel(IPAddress.Parse("1.1.1.1"), port,
                new SteamHTTP.LoopbackProxy(IPAddress.Loopback, 1), CancellationToken.None); },
                "CONNECT invalid port rejected before I/O " + port, "proxy_connect_boundary");
        var targetUri=new Uri("https://fixture.steamcontent.com/");
        var validProxy=new FixedProxy(new Uri("http://127.0.0.1:7890"));
        var selected=await SteamHTTP.ResolveLoopbackProxy(targetUri,validProxy,CancellationToken.None);
        Check(selected is { Port:7890 } && IPAddress.IsLoopback(selected.Address),"configured no-credential loopback HTTP proxy accepted");
        Check(await SteamHTTP.ResolveLoopbackProxy(targetUri,new FixedProxy(new Uri("http://user:secret@127.0.0.1:7890")),CancellationToken.None) is null,
            "proxy URI credentials rejected without transmission");
        var credentialProxy=new FixedProxy(new Uri("http://127.0.0.1:7890")){Credentials=new NetworkCredential("fixture","fixture")};
        Check(await SteamHTTP.ResolveLoopbackProxy(targetUri,credentialProxy,CancellationToken.None) is null,
            "configured proxy credential provider rejected without reading credentials");
        Check(await SteamHTTP.ResolveLoopbackProxy(targetUri,new FixedProxy(new Uri("http://192.0.2.1:7890")),CancellationToken.None) is null,
            "non-loopback proxy rejected");
        Check(await SteamHTTP.ResolveLoopbackProxy(targetUri,new FixedProxy(targetUri,true),CancellationToken.None) is null,
            "bypassed target keeps direct transport");
        await Reject(async()=>{await using var _=await SteamHTTP.ConnectTunnel(IPAddress.Loopback,443,
            new SteamHTTP.LoopbackProxy(IPAddress.Loopback,1),CancellationToken.None);},
            "private CONNECT destination rejected before proxy I/O","proxy_connect_boundary");

        using(var proxy=new ConnectProxy("HTTP/1.1 200 Connection established\r\n\r\nZ"))
        {
            await using var tunnel=await SteamHTTP.ConnectTunnel(IPAddress.Parse("1.1.1.1"),443,
                new SteamHTTP.LoopbackProxy(IPAddress.Loopback,proxy.Port),CancellationToken.None);
            int marker=tunnel.ReadByte();await proxy.Done;
            Check(marker=='Z',"CONNECT parser drains only proxy headers and preserves first tunneled byte");
            Check(proxy.Request.StartsWith("CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n",StringComparison.Ordinal) &&
                !proxy.Request.Contains("fixture.steamcontent.com",StringComparison.OrdinalIgnoreCase) &&
                !proxy.Request.Contains("Proxy-Authorization",StringComparison.OrdinalIgnoreCase),
                "CONNECT authority is concrete public IP with no remote DNS or credentials");
        }
        using(var proxy=new ConnectProxy("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=private\r\n\r\n"))
        {
            await Reject(async()=>{await using var _=await SteamHTTP.ConnectTunnel(IPAddress.Parse("1.1.1.1"),443,
                new SteamHTTP.LoopbackProxy(IPAddress.Loopback,proxy.Port),CancellationToken.None);},
                "proxy authentication challenge returns fixed redacted code","proxy_auth_required");
            await proxy.Done;
            Check(!proxy.Request.Contains("Authorization",StringComparison.OrdinalIgnoreCase) && !proxy.Request.Contains("secret",StringComparison.OrdinalIgnoreCase),
                "proxy 407 never causes credential forwarding");
        }
        using(var proxy=new ConnectProxy(null))
        using(var cancellation=new CancellationTokenSource())
        {
            var operation=SteamHTTP.ConnectTunnel(IPAddress.Parse("1.1.1.1"),443,
                new SteamHTTP.LoopbackProxy(IPAddress.Loopback,proxy.Port),cancellation.Token);
            await Until(()=>proxy.Request.Length>0);cancellation.Cancel();
            await Reject(async()=>await operation,"CONNECT response wait observes caller cancellation");
        }

        string? observedSNI=null;
        using RSA rsa=RSA.Create(2048);
        var request=new CertificateRequest("CN=fixture.steamcontent.com",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        using X509Certificate2 certificate=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1),DateTimeOffset.UtcNow.AddMinutes(5));
        using(var proxy=new ConnectProxy("HTTP/1.1 200 Connection established\r\n\r\n",async stream=>
        {
            using var tls=new SslStream(stream,false);
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificateSelectionCallback=(_,name)=>{observedSNI=name;return certificate;}
            });
        }))
        {
            await using var tunnel=await SteamHTTP.ConnectTunnel(IPAddress.Parse("1.1.1.1"),443,
                new SteamHTTP.LoopbackProxy(IPAddress.Loopback,proxy.Port),CancellationToken.None);
            using var tls=new SslStream(tunnel,false,(_,_,_,_)=>true);
            await tls.AuthenticateAsClientAsync("fixture.steamcontent.com");await proxy.Done;
            Check(observedSNI=="fixture.steamcontent.com","TLS over CONNECT preserves original hostname for SNI and certificate identity");
        }
        Check(SteamHTTP.Handler().SslOptions.RemoteCertificateValidationCallback is null,
            "production handler retains platform TLS certificate validation");
    }
    private sealed class FixedProxy(Uri uri,bool bypass=false):IWebProxy
    {
        public ICredentials? Credentials { get; set; }
        public Uri GetProxy(Uri destination)=>uri;
        public bool IsBypassed(Uri host)=>bypass;
    }
    private sealed class ConnectProxy:IDisposable
    {
        private readonly TcpListener listener=new(IPAddress.Loopback,0);private readonly CancellationTokenSource cancellation=new();
        private readonly string? response;private readonly Func<Stream,Task>? afterResponse;internal string Request="";
        internal int Port=>((IPEndPoint)listener.LocalEndpoint).Port;internal Task Done{get;}
        internal ConnectProxy(string? response,Func<Stream,Task>? afterResponse=null)
        {
            this.response=response;this.afterResponse=afterResponse;listener.Start();Done=Task.Run(Serve);
        }
        private async Task Serve()
        {
            try
            {
                using var client=await listener.AcceptTcpClientAsync(cancellation.Token);var stream=client.GetStream();
                var header=new List<byte>();var one=new byte[1];
                while(header.Count<8192 && await stream.ReadAsync(one,cancellation.Token)!=0)
                {header.Add(one[0]);if(header.Count>=4 && header[^4..].SequenceEqual("\r\n\r\n"u8.ToArray()))break;}
                Request=Encoding.ASCII.GetString(header.ToArray());
                if(response is null){await Task.Delay(Timeout.Infinite,cancellation.Token);return;}
                await stream.WriteAsync(Encoding.ASCII.GetBytes(response),cancellation.Token);
                if(afterResponse is not null)await afterResponse(stream);
            }
            catch(OperationCanceledException){}
        }
        public void Dispose(){cancellation.Cancel();listener.Stop();try{Done.GetAwaiter().GetResult();}catch(SocketException){}cancellation.Dispose();}
    }
    private sealed class FakeSession(string id):ISteamContentSession
    {
        public string ID=>id;public bool Authenticated{get;set;}public bool Disposed;internal LocalServer? Server;
        private int activeDownloads,maximumDownloads;
        internal Exception? NextFailure;
        internal int ActiveDownloads=>Volatile.Read(ref activeDownloads);internal int MaximumDownloads=>Volatile.Read(ref maximumDownloads);
        internal void ResetConcurrency(){Volatile.Write(ref activeDownloads,0);Volatile.Write(ref maximumDownloads,0);}
        public async Task<AuthResult> Login(AuthRequest input,AuthChallengeBroker challenges,CancellationToken token)
        { _=await challenges.GetDeviceCodeAsync(false);token.ThrowIfCancellationRequested();Authenticated=true;return new("fixture-user","123","fixture-refresh",null); }
        public Task<AuthorizedManifest> Resolve(ulong item,CancellationToken token)=>Task.FromResult(Plan(id));
        public Task<EngineAssetResolution> ResolveEngineAssets(IReadOnlyList<string> resources,CancellationToken token)=>throw new NotSupportedException();
        public Task<EngineAssetInspection> InspectEngineAssets(IReadOnlyList<string> resources,CancellationToken token)=>throw new NotSupportedException();
        public Task<EngineManifestInventory> InspectEngineAssetInventory(CancellationToken token)=>throw new NotSupportedException();
        public Task<AuthorizedManifest> ResolveSceneRuntimeAssets(CancellationToken token)=>throw new NotSupportedException();
        public async Task DownloadChunk(AuthorizedManifest authorized,DepotChunkEntry chunk,byte[] output,Action<int> received,CancellationToken token)
        {
            int now=Interlocked.Increment(ref activeDownloads),seen;
            while(now>(seen=Volatile.Read(ref maximumDownloads)))Interlocked.CompareExchange(ref maximumDownloads,now,seen);
            try
            {
                var failure=Interlocked.Exchange(ref NextFailure,null);if(failure is not null)throw failure;
                var scope=new CDNRequestScope("127.0.0.1",$"/depot/{authorized.DepotID}/chunk/{chunk.SHA1}",chunk.CompressedLength,false,token,received,true);
                var client=new SteamClient(SteamConfiguration.Create(b=>b.WithHttpClientFactory(_=>new HttpClient(new CDNBoundaryHandler(scope,SteamHTTP.Handler(true))))));
                using var cdn=new Client(client);await cdn.DownloadDepotChunkAsync(authorized.DepotID,chunk.SDK,SessionTests.Server(true,this.Server!.Port),output,key);
            }
            finally{Interlocked.Decrement(ref activeDownloads);}
        }
        public ValueTask DisposeAsync(){Disposed=true;Authenticated=false;return ValueTask.CompletedTask;}
    }
    private sealed class SlowSession(string id):ISteamContentSession
    {
        public string ID=>id;public bool Authenticated{get;private set;}internal bool Started,Disposed;
        internal readonly TaskCompletionSource<AuthResult> Result=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<AuthResult> Login(AuthRequest input,AuthChallengeBroker broker,CancellationToken token)
        {Started=true;var result=await Result.Task;Authenticated=true;return result;}
        public Task<AuthorizedManifest> Resolve(ulong item,CancellationToken token)=>throw new NotSupportedException();
        public Task<EngineAssetResolution> ResolveEngineAssets(IReadOnlyList<string> resources,CancellationToken token)=>throw new NotSupportedException();
        public Task<EngineAssetInspection> InspectEngineAssets(IReadOnlyList<string> resources,CancellationToken token)=>throw new NotSupportedException();
        public Task<EngineManifestInventory> InspectEngineAssetInventory(CancellationToken token)=>throw new NotSupportedException();
        public Task<AuthorizedManifest> ResolveSceneRuntimeAssets(CancellationToken token)=>throw new NotSupportedException();
        public Task DownloadChunk(AuthorizedManifest p,DepotChunkEntry c,byte[] b,Action<int> r,CancellationToken t)=>throw new NotSupportedException();
        public ValueTask DisposeAsync(){Disposed=true;Authenticated=false;return ValueTask.CompletedTask;}
    }
    private sealed class RealAdapterNoNetwork:IDisposable
    {private readonly SteamKitSession adapter=new(Guid.NewGuid().ToString());public void Dispose()=>adapter.DisposeAsync().AsTask().GetAwaiter().GetResult();}
    private sealed class LocalServer:IDisposable
    {
        private readonly TcpListener listener=new(IPAddress.Loopback,0);private readonly CancellationTokenSource cancellation=new();
        private readonly Task pump;internal readonly ConcurrentDictionary<string,byte[]> Routes=new();internal readonly ConcurrentDictionary<string,bool> Slow=new();internal int Hits;internal int Port=>((IPEndPoint)listener.LocalEndpoint).Port;
        internal LocalServer(){listener.Start();pump=Task.Run(async()=>{try{while(!cancellation.IsCancellationRequested){var c=await listener.AcceptTcpClientAsync(cancellation.Token);_=Serve(c);}}catch(OperationCanceledException){} });}
        private async Task Serve(TcpClient client)
        {
            try { await ServeBody(client); } catch(IOException) { client.Dispose(); } catch(SocketException) { client.Dispose(); }
        }
        private async Task ServeBody(TcpClient client)
        {
            using(client)
            {
                var stream=client.GetStream();var header=new List<byte>();var one=new byte[1];
                while(header.Count<8192 && await stream.ReadAsync(one)!=0){header.Add(one[0]);if(header.Count>=4 && Encoding.ASCII.GetString(header.ToArray()).EndsWith("\r\n\r\n"))break;}
                string path=Encoding.ASCII.GetString(header.ToArray()).Split(' ')[1];Interlocked.Increment(ref Hits);
                if(!Routes.TryGetValue(path,out var data))data=[];
                byte[] response=Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Length: {data.Length}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(response);
                for(int i=0;i<data.Length;i+=4096)
                {
                    await stream.WriteAsync(data.AsMemory(i,Math.Min(4096,data.Length-i)));
                    if(Slow.ContainsKey(path)) await Task.Delay(10,cancellation.Token);
                }
            }
        }
        public void Dispose(){cancellation.Cancel();listener.Stop();pump.GetAwaiter().GetResult();cancellation.Dispose();}
    }
}
