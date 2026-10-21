import Foundation
import Darwin
import CryptoKit

@main @MainActor enum SteamContentBrokerTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static let fm = FileManager.default
    static func check(_ value: Bool, _ name: String) throws { guard value else { throw Failure(message: name) }; checks += 1; print("PASS \(name)"); fflush(stdout) }
    static func wait(_ name: String, _ body: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if body() { return }; try await Task.sleep(for: .milliseconds(5)) }; throw Failure(message: "timeout " + name)
    }
    static func fixture(_ root: URL, _ mode: String) throws -> (SteamContentBroker, URL) {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(mode.utf8).write(to: dir.appendingPathComponent("mode"))
        let broker = try SteamContentBroker(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]), workspaceURL: dir, responseTimeout: .milliseconds(700))
        return (broker, broker.workspaceURL)
    }
    static func login(_ broker: SteamContentBroker) async throws {
        try await broker.loginCredentials(username: "fixture_user", password: "fixture_password")
    }
    @MainActor final class MemorySavedStore: SteamContentSessionStoring {
        var value: SteamContentSavedSession?
        var loads=0, saves=0, deletes=0
        var failLoad=false, failSave=false, failDelete=false, holdSave=false, enteredSave=false, suppressed=false
        var saveContinuation: CheckedContinuation<Void,Never>?
        init(_ value:SteamContentSavedSession?=nil) {self.value=value}
        func configure(load:Bool=false,save:Bool=false,delete:Bool=false,hold:Bool=false) {failLoad=load;failSave=save;failDelete=delete;holdSave=hold}
        func load()async throws->SteamContentSavedSession? {loads+=1;if failLoad{throw SteamContentSessionStoreError.readFailed};return suppressed ? nil:value}
        func save(_ session:SteamContentSavedSession)async throws {
            saves+=1;enteredSave=true;suppressed=true
            if holdSave {await withCheckedContinuation{saveContinuation=$0}}
            if failSave {throw SteamContentSessionStoreError.saveFailed};value=session;suppressed=false
        }
        func delete()async throws {deletes+=1;suppressed=true;if failDelete{throw SteamContentSessionStoreError.deleteFailed};value=nil}
        func releaseSave(){holdSave=false;saveContinuation?.resume();saveContinuation=nil}
    }
    static func waitStore(_ name:String,_ body:@escaping @MainActor ()->Bool)async throws {
        for _ in 0..<500 {if body(){return};try await Task.sleep(for:.milliseconds(5))};throw Failure(message:"timeout "+name)
    }
    static func persistedFixture(_ root:URL,_ mode:String,_ store:MemorySavedStore)throws->(SteamContentBroker,URL) {
        let (_,directory)=try fixture(root,mode)
        let b=try SteamContentBroker(executableURL:URL(fileURLWithPath:CommandLine.arguments[0]),workspaceURL:directory,responseTimeout:.milliseconds(700),sessionStore:store)
        return(b,b.workspaceURL)
    }
    static let originalSaved = SteamContentSavedSession(username:"fixture_user",refreshToken:"old_refresh",guardData:"old_guard")
    static func savedChecks(_ root:URL)async throws {
        let store=MemorySavedStore(originalSaved), (b,d)=try persistedFixture(root,"saved-success",store)
        try await b.start();try check(store.loads==0 && b.state == .idle,"constructing/starting a store-enabled broker never reads or restores saved credentials")
        let available=try await b.loadSavedSessionAvailability()
        try check(available && b.hasSavedSession && b.state == .idle && !fm.fileExists(atPath:d.appendingPathComponent("login-received").path),"saved availability lookup alone never marks authenticated or sends login")
        try await b.restoreSavedSession()
        try check(b.state == .loggedIn(userID:nil) && b.hasSavedSession && store.value?.refreshToken == "fixture_refresh","explicit saved restore sends refresh auth and persists rotated token only after actual ACK")
        await b.shutdown()
        try check(store.deletes==0 && store.value != nil && !b.hasInMemoryRefreshSession,"shutdown clears transient memory and preserves saved session")
        let (restart,_)=try persistedFixture(root,"saved-success",store);try await restart.restoreSavedSession();await restart.logout()
        try check(store.value==nil && store.deletes==1 && !restart.hasSavedSession,"explicit logout deletes persisted session instead of preserving it like shutdown")
        do{try await restart.restoreSavedSession();throw Failure(message:"logout restored")}catch SteamContentBrokerError.savedSessionUnavailable{try check(true,"explicit logout blocks restoration in the same broker")}
        await restart.shutdown()
        let empty=MemorySavedStore(),(noSaved,_)=try persistedFixture(root,"success",empty)
        try check(try await !noSaved.loadSavedSessionAvailability(),"empty store reports no saved record without helper authentication")
        do{try await noSaved.restoreSavedSession();throw Failure(message:"empty restored")}catch SteamContentBrokerError.savedSessionUnavailable{try check(true,"missing saved record has typed unavailable result for legacy fallback")}
        let unreadable=MemorySavedStore(originalSaved);unreadable.configure(load:true)
        let (readFail,_)=try persistedFixture(root,"success",unreadable)
        do{_ = try await readFail.loadSavedSessionAvailability();throw Failure(message:"unreadable accepted")}catch SteamContentBrokerError.savedSessionAccessFailed{try check(unreadable.deletes==0,"store access denial never erases a potentially valid saved session")}
        let failedSave=MemorySavedStore(originalSaved);failedSave.configure(save:true)
        let (newAccount,newDirectory)=try persistedFixture(root,"success",failedSave);try await login(newAccount)
        try check(newAccount.state == .loggedIn(userID:nil) && !newAccount.hasSavedSession && newAccount.sessionPersistenceMessage?.contains("未能保存")==true,"save failure preserves live authenticated connection and reports that remembering failed")
        let (suppressed,_)=try persistedFixture(root,"success",failedSave)
        try check(try await !suppressed.loadSavedSessionAvailability(),"failed account replacement never auto-restores the older account record")
        failedSave.configure();try check(await newAccount.retryPersistCurrentSession(),"retry saving current session succeeds from acknowledged in-memory refresh token")
        try check(try Data(contentsOf:newDirectory.appendingPathComponent("login-count")).count==1,"retry persistence does not request password or send another login")
        await newAccount.shutdown()
        let failedDelete=MemorySavedStore(originalSaved);failedDelete.configure(delete:true)
        let (signout,_)=try persistedFixture(root,"success",failedDelete);_ = try await signout.loadSavedSessionAvailability();await signout.logout()
        let (blocked,_)=try persistedFixture(root,"success",failedDelete)
        try check(try await !blocked.loadSavedSessionAvailability() && signout.sessionPersistenceMessage?.contains("未能清除")==true,"failed deletion is reported truthfully while persisted suppression prevents next-instance restoration")
        for code in ["5","26","27","121"] {
            let revoked=MemorySavedStore(originalSaved),(r,_)=try persistedFixture(root,"saved-revoked-"+code,revoked)
            do{try await r.restoreSavedSession();throw Failure(message:"revoked succeeded")}catch SteamContentBrokerError.savedSessionRevoked{try check(revoked.deletes==1 && revoked.value==nil && !r.hasSavedSession,"explicit refresh rejection code \(code) clears revoked saved token with typed manual-login result")}
            await r.shutdown()
        }
        let transient=MemorySavedStore(originalSaved),(network,networkDirectory)=try persistedFixture(root,"saved-network",transient)
        do{try await network.restoreSavedSession();throw Failure(message:"network succeeded")}catch{}
        try check(transient.deletes==0 && transient.value != nil && network.hasSavedSession,"transient network authentication failure retains saved token for retry")
        try Data("saved-success".utf8).write(to:networkDirectory.appendingPathComponent("mode"))
        await network.shutdown()
        let (networkRetry,_)=try persistedFixture(root,"saved-success",transient);try await networkRetry.restoreSavedSession();await networkRetry.shutdown()
        try check(transient.deletes==0,"retrying after transient failure can authenticate without erasing saved credentials")
        for action in ["logout","shutdown"] {
            let held=MemorySavedStore(originalSaved);held.configure(hold:true)
            let (session,_)=try persistedFixture(root,"success",held)
            let attempt=Task{try await login(session)}
            try await waitStore("save gate"){held.enteredSave}
            var done=false
            let close=Task{if action=="logout"{await session.logout()}else{await session.shutdown()};done=true}
            try await Task.sleep(for:.milliseconds(40))
            try check(!done && held.deletes==0,"\(action) waits acknowledged-session pending save instead of abandoning late persistence")
            held.releaseSave();await close.value;_ = try? await attempt.value
            try check((action=="logout" ? held.value==nil && held.deletes==1 : held.value?.refreshToken=="fixture_refresh" && held.deletes==0),"\(action) ordering prevents late save from overriding logout and preserves save across quit")
            await session.shutdown()
        }
        let cancelled=MemorySavedStore(originalSaved),(waiting,_)=try persistedFixture(root,"saved-hold",cancelled)
        let pending=Task{try await waiting.restoreSavedSession()};try await wait("pending saved auth"){waiting.state == .loggingIn}
        pending.cancel();_ = try? await pending.value;await waiting.shutdown()
        try check(cancelled.deletes==0 && cancelled.saves==0 && cancelled.value==originalSaved,"cancelling saved authentication before ACK never saves or deletes the existing session")
        let guardStore=MemorySavedStore(originalSaved),(guardRestore,_)=try persistedFixture(root,"saved-no-guard",guardStore)
        try await guardRestore.restoreSavedSession()
        try check(guardStore.value?.guardData=="old_guard","refresh ACK without replacement GuardData preserves the previously authorized GuardData")
        await guardRestore.shutdown()
        let passwordStore=MemorySavedStore(originalSaved),(wrongPassword,_)=try persistedFixture(root,"saved-password-failure",passwordStore)
        do{try await login(wrongPassword);throw Failure(message:"bad password accepted")}catch{}
        try check(passwordStore.deletes==0 && passwordStore.value==originalSaved,"ordinary password rejection never deletes a different previously saved refresh session")
        await wrongPassword.shutdown()
        let renewing=MemorySavedStore(originalSaved);renewing.configure(hold:true)
        let (renewal,_)=try persistedFixture(root,"persist-renewal",renewing)
        let first=Task{try await login(renewal)}
        try await waitStore("renewal first save"){renewing.enteredSave}
        await renewal.cancelAuthentication();_ = try? await first.value
        let second=Task{try await login(renewal)}
        try await wait("second actual ACK"){renewal.state == .loggedIn(userID:nil)}
        renewing.releaseSave();try await second.value
        try check(renewing.value?.refreshToken=="fixture_refresh_2" && renewing.saves==2 && renewing.deletes==0,"serialized ACK token renewal cannot be overwritten by the older delayed save or cancellation")
        await renewal.shutdown()
        let savedJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(originalSaved)) as! [String:Any]
        try check(Set(savedJSON.keys)==["username","refreshToken","guardData"],"saved schema admits only necessary refresh identity fields and no password OTP or file path")
    }
    static func child(_ root: URL) throws {
        let mode = try String(contentsOf: root.appendingPathComponent("mode"), encoding: .utf8)
        let nonce = UUID().uuidString, session = UUID().uuidString.lowercased(), challenge = UUID().uuidString.lowercased()
        var authenticated = false, authNumber = 0
        var seq = 0, loginRequest = "", job: [String: Any]?, cancelledRequest = ""
        func emit(_ kind: String, _ request: String, _ detail: [String: Any] = [:], identity: [String: Any]? = nil) throws {
            seq += 1
            var event: [String: Any] = ["v": 1, "sessionNonce": nonce, "seq": seq, "kind": kind, "requestID": request, "detail": detail]
            if let identity {
                event["jobID"] = identity["jobID"]; event["epoch"] = String(describing: identity["epoch"]!); event["publishedFileID"] = identity["publishedFileID"]
                event["appID"] = 431960
                let noManifest = ["resolving","engine_assets_resolving","engine_assets_inspection","engine_inventory_resolving",
                                  "engine_inventory_begin","engine_inventory_chunk","engine_inventory_complete","scene_runtime_assets_resolving"].contains(kind) || identity["inventory"] as? Bool == true
                let engine = identity["engine"] as? Bool == true
                if !noManifest { event["manifestID"] = engine ? "199":"99"; event["depotID"] = engine ? 431961:431960 }
                else if kind == "resolving" { event["manifestID"] = "0"; event["depotID"] = 0 }
            }
            if mode == "nonce" && kind == "started" { event["sessionNonce"] = "stale-process" }
            if mode == "seq" && kind == "started" { event["seq"] = seq - 1 }
            if mode == "epoch" && kind == "started" { event["epoch"] = "999" }
            if mode == "request" && kind == "auth_result" { event["requestID"] = UUID().uuidString }
            if mode == "session" && kind == "auth_result" { event["detail"] = ["sessionID": UUID().uuidString, "accountName": "fixture_user", "steamID": "123"] }
            var data = try JSONSerialization.data(withJSONObject: event); data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
        }
        func counters(_ downloaded: String = "4", total: String = "4") -> [String: Any] {
            ["logicalTotalBytes": total, "receivedPayloadBytes": "8", "downloadedVerifiedBytes": downloaded, "reusedVerifiedBytes": "0", "successfulCompressedPayloadBytes": "8"]
        }
        func authResult() throws {
            authenticated = true
            var detail: [String:Any] = ["sessionID": session, "accountName": "fixture_user", "steamID": "123456", "refreshToken": mode == "persist-renewal" ? "fixture_refresh_\(authNumber)":"fixture_refresh", "guardData": "fixture_guard"]
            if mode == "saved-no-guard" { detail.removeValue(forKey:"guardData") }
            try emit("auth_result", loginRequest, detail)
        }
        // Fixtures inspect only their own invented command metadata; no secret content is persisted.
        let environmentClean = ProcessInfo.processInfo.environment["GW_SECRET_SENTINEL"] == nil
        try Data((environmentClean && CommandLine.arguments.count == 3 ? "clean" : "dirty").utf8).write(to: root.appendingPathComponent("launch-check"))
        try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("pid"))
        if mode == "slow-ready" { Thread.sleep(forTimeInterval: 0.15) }
        try emit("ready", "startup", ["productionAuthentication": true, "productionWorkshopDownload": true, "productionEngineAssets": true])
        while let line = readLine() {
            guard let data = line.data(using: .utf8), let command = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = command["commandName"] as? String, let request = command["requestID"] as? String else { exit(80) }
            switch name {
            case "login":
                loginRequest = request; authNumber += 1
                if mode.hasPrefix("saved-success") || mode == "saved-no-guard" {
                    guard (command["auth"] as? [String:Any])?["method"] as? String == "refresh" else { exit(86) }
                }
                let countURL=root.appendingPathComponent("login-count")
                var countData=(try? Data(contentsOf:countURL)) ?? Data();countData.append(1);try countData.write(to:countURL)
                try Data().write(to: root.appendingPathComponent("login-received"))
                if mode == "rejected-secret" { try emit("rejected", request, ["reason": "fixture_secret_lowercase"]); continue }
                try emit("auth_started", request, ["sessionID": session])
                if mode.hasPrefix("saved-revoked-") || mode == "saved-network" || mode == "saved-password-failure" {
                    let code=mode=="saved-network" ? "steam_disconnected":mode=="saved-password-failure" ? "steam_logon_5":"steam_logon_"+String(mode.dropFirst("saved-revoked-".count))
                    try emit("auth_failed",request,["sessionID":session,"reason":code]);continue
                }
                if mode == "saved-hold" {continue}
                if mode == "auth-hold" { continue }
                if ["guard", "confirmation", "qr"].contains(mode) {
                    let type = mode == "guard" ? "email_code" : mode == "confirmation" ? "device_confirmation" : "qr"
                    var detail: [String: Any] = ["sessionID": session, "challengeID": challenge, "type": type, "previousIncorrect": false]
                    if mode == "qr" { detail["challengeURL"] = "https://steamcommunity.com/fixture" }
                    try emit("auth_challenge", request, detail); continue
                }
                try authResult()
            case "auth_response":
                let response = command["response"] as? [String: Any]
                guard response?["sessionID"] as? String == session, response?["challengeID"] as? String == challenge else { exit(81) }
                try emit("auth_response_accepted", request, ["sessionID": session]); try authResult()
            case "download":
                job = command
                if mode.hasPrefix("lost-rejected-") {
                    try emit("rejected", request, ["reason": String(mode.dropFirst("lost-rejected-".count))]); continue
                }
                if mode.hasPrefix("lost-failed-") || mode.hasPrefix("cdn-failed") {
                    try emit("resolving", request, ["sessionID": session], identity: command)
                    try emit("started", request, ["sessionID": session], identity: command)
                    let code = mode.hasPrefix("lost-failed-") ? String(mode.dropFirst("lost-failed-".count)) : "no_supported_https_cdn"
                    let group: [String:Any] = ["type": mode == "cdn-failed-unsafe" ? "fixture_secret" : "CDN", "httpsCapability":"unavailable", "rejection":"https_not_advertised", "count":2]
                    try emit("failed", request, ["reason":code,"counters":counters("0"),"cdnDirectory":["total":2,"accepted":0,"groups":[group]]], identity: command)
                    continue
                }
                if mode == "malformed" { try FileHandle.standardOutput.write(contentsOf: Data("{bad}\n".utf8)); continue }
                if mode == "oversized" { try FileHandle.standardOutput.write(contentsOf: Data(repeating: 120, count: 65_538)); continue }
                if mode == "truncated" { try FileHandle.standardOutput.write(contentsOf: Data("{incomplete".utf8)); return }
                try emit("resolving", request, ["sessionID": session], identity: command)
                try emit("started", request, ["sessionID": session], identity: command)
                try emit("progress", request, counters(mode == "overflow" ? "5" : "2"), identity: command)
                if ["held", "cancel-timeout", "cancel-race"].contains(mode) { continue }
                let content = root.appendingPathComponent("items/7/99/content")
                try fm.createDirectory(at: content, withIntermediateDirectories: true)
                try Data([1,2,3,4]).write(to: content.appendingPathComponent("fixture.bin"))
                if mode == "escape" { try fm.removeItem(at: content); try fm.createSymbolicLink(at: content, withDestinationURL: root.deletingLastPathComponent()) }
                try emit("transfer_complete", request, ["sessionID": session, "counters": counters(), "contentRelativePath": "items/7/99/content", "validationRequired": true, "planFingerprint": String(repeating: "a", count: 64)], identity: command)
            case "engine_assets":
                job = command
                guard command["appID"] as? Int == 431960,
                      let resources = command["desiredResources"] as? [String], !resources.isEmpty else { exit(87) }
                var identity = command; identity["engine"] = true; job = identity
                try emit("engine_assets_resolving", request, ["sessionID":session,"resourceCount":resources.count], identity: identity)
                if command["inspectOnly"] as? Bool == true {
                    guard resources.contains("fonts/Alcubierre.otf") else { exit(88) }
                    if mode == "engine-inspect-held" { continue }
                    let paths = mode == "engine-inspect-invalid" ? ["../private"] : ["assets/materials/particle/halo.tex","assets/shaders/common_fragment.h","packages/engine_assets.pkg"]
                    try emit("engine_assets_inspection",request,["sessionID":session,"manifests":[["depotID":431961,"manifestID":"555"]],"paths":paths],identity:identity)
                    continue
                }
                let fingerprint=String(repeating:"b",count:64), logical=resources[0]
                let relative = mode == "engine-path" ? "../outside":"assets/"+logical
                let planned:[String:Any] = ["logicalPath":logical,"relativePath":relative,"sha1":String(repeating:"a",count:40),"sizeBytes":"4"]
                let manifest:[String:Any] = ["sha256":fingerprint,"depotID":431961,"manifestID":"199"]
                try emit("engine_assets_plan",request,["sessionID":session,"manifestIdentity":manifest,"files":[planned]],identity:identity)
                try emit("progress",request,counters("2"),identity:identity)
                if mode == "engine-held" { continue }
                var directory=root
                for component in ["engine-assets",fingerprint,"content","assets"]+logical.split(separator:"/").dropLast().map(String.init) {
                    directory=directory.appendingPathComponent(component,isDirectory:true)
                    if !fm.fileExists(atPath:directory.path) { try fm.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) }
                }
                let fileURL=directory.appendingPathComponent(String(logical.split(separator:"/").last!)), bytes=Data([1,2,3,4])
                try bytes.write(to:fileURL)
                if mode == "engine-symlink" { try fm.removeItem(at:fileURL);try fm.createSymbolicLink(at:fileURL,withDestinationURL:root.appendingPathComponent("mode")) }
                if mode == "engine-hardlink" { try fm.removeItem(at:fileURL);try fm.linkItem(at:root.appendingPathComponent("mode"),to:fileURL) }
                if mode == "engine-public-dir" { try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:directory.path) }
                let hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
                let complete:[String:Any] = ["logicalPath":logical,"relativePath":relative,"sha256":mode == "engine-hash" ? String(repeating:"0",count:64):hash,"sizeBytes":"4"]
                try emit("engine_assets_complete",request,["sessionID":session,"counters":counters(),"cacheRelativePath":"engine-assets/\(fingerprint)/content","manifestIdentity":manifest,"files":[complete]],identity:identity)
            case "engine_assets_inventory":
                job = command; var identity = command; identity["engine"] = true; identity["inventory"] = true; job = identity
                try emit("engine_inventory_resolving", request, ["sessionID":session], identity:identity)
                let manifest:[String:Any] = ["depotID":431961,"manifestID":"555"]
                let file:[String:Any] = ["logicalPath":"fonts/Alcubierre.otf","manifestPath":"assets/fonts/Alcubierre.otf",
                    "depotID":431961,"manifestID":"555","sizeBytes":"4","sha1":String(repeating:"a",count:40),
                    "category":"fonts","extension":".otf","archiveCandidate":false]
                let group:[String:Any] = ["category":"fonts","fileCount":1,"totalBytes":"4","maximumFileBytes":"4"]
                let ext:[String:Any] = ["category":".otf","fileCount":1,"totalBytes":"4","maximumFileBytes":"4"]
                try emit("engine_inventory_begin",request,["sessionID":session,"complete":true,"manifests":[manifest],
                    "groups":[group],"extensions":[ext],"totalFileCount":1,"totalBytes":"4","maximumFileBytes":"4",
                    "excludedExecutableCount":0,"excludedExecutableBytes":"0"],identity:identity)
                if mode == "inventory-held" { continue }
                try emit("engine_inventory_chunk",request,["sessionID":session,"offset":0,"inventoryFiles":[file]],identity:identity)
                let canonical="gw-engine-inventory-v1\nm\u{0}431961\u{0}555\nf\u{0}fonts/Alcubierre.otf\u{0}assets/fonts/Alcubierre.otf\u{0}431961\u{0}555\u{0}4\u{0}\(String(repeating:"a",count:40))\u{0}fonts\u{0}.otf\u{0}0\ng\u{0}fonts\u{0}1\u{0}4\u{0}4\nx\u{0}.otf\u{0}1\u{0}4\u{0}4\ne\u{0}0\u{0}0\n"
                var hash=SHA256.hash(data:Data(canonical.utf8)).map{String(format:"%02x",$0)}.joined()
                if mode == "inventory-hash" { hash=String(repeating:"0",count:64) }
                try emit("engine_inventory_complete",request,["sessionID":session,"complete":true,"reportSHA256":hash],identity:identity)
            case "scene_runtime_assets":
                var identity=command;identity["engine"]=true;job=identity
                try emit("scene_runtime_assets_resolving",request,["sessionID":session],identity:identity)
                let fingerprint=String(repeating:"c",count:64),manifest:[String:Any]=["sha256":fingerprint,"depotID":431961,"manifestID":"199"]
                try emit("scene_runtime_assets_plan",request,["sessionID":session,"manifestIdentity":manifest,"fileCount":2,"totalBytes":"7"],identity:identity)
                let planned:[[String:Any]]=[
                    ["logicalPath":"fonts/Alcubierre.otf","relativePath":"assets/fonts/Alcubierre.otf","sha1":String(repeating:"a",count:40),"sizeBytes":"4"],
                    ["logicalPath":"shaders/common.h","relativePath":"assets/shaders/common.h","sha1":String(repeating:"b",count:40),"sizeBytes":"3"]]
                try emit("scene_runtime_assets_plan_chunk",request,["sessionID":session,"offset":0,"files":planned],identity:identity)
                if mode == "runtime-safe-failure" { try emit("failed",request,["reason":"scene_runtime_transfer_io","counters":counters("2",total:"7")],identity:identity); continue }
                try emit("progress",request,counters("2",total:"7"),identity:identity)
                if mode == "runtime-held" { continue }
                let content=root.appendingPathComponent("scene-runtime-assets/\(fingerprint)/content")
                for name in ["fonts","shaders"] { try fm.createDirectory(at:content.appendingPathComponent("assets/\(name)"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
                let values:[(String,Data)]=[("assets/fonts/Alcubierre.otf",Data([1,2,3,4])),("assets/shaders/common.h",Data([5,6,7]))]
                var verified:[[String:Any]]=[]
                for (path,data) in values { try data.write(to:content.appendingPathComponent(path));let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined();verified.append(["logicalPath":String(path.dropFirst("assets/".count)),"relativePath":path,"sha256":hash,"sizeBytes":String(data.count)]) }
                if mode == "runtime-hash" { verified[0]["sha256"]=String(repeating:"0",count:64) }
                try emit("scene_runtime_assets_verified_begin",request,["sessionID":session,"fileCount":2],identity:identity)
                try emit("scene_runtime_assets_verified_chunk",request,["sessionID":session,"offset":0,"files":verified],identity:identity)
                try emit("scene_runtime_assets_complete",request,["sessionID":session,"counters":counters("7",total:"7"),
                    "cacheRelativePath":"scene-runtime-assets/\(fingerprint)/content","manifestIdentity":manifest,"fileCount":2],identity:identity)
            case "cancel":
                cancelledRequest = request
                guard let job else { exit(82) }
                if mode == "cancel-race" {
                    let content = root.appendingPathComponent("items/7/99/content")
                    try fm.createDirectory(at: content, withIntermediateDirectories: true)
                    try Data([1,2,3,4]).write(to: content.appendingPathComponent("fixture.bin"))
                    try emit("transfer_complete", job["requestID"] as! String, ["sessionID": session, "counters": counters(), "contentRelativePath": "items/7/99/content", "validationRequired": true, "planFingerprint": String(repeating: "a", count: 64)], identity: job)
                    try emit("rejected", request, ["reason": "stale_job"]); continue
                }
                try emit("cancel_requested", request, identity: job)
                if mode == "cancel-timeout" { continue }
                Thread.sleep(forTimeInterval: 0.12)
                try Data("drained".utf8).write(to: root.appendingPathComponent("drained"))
                try emit("cancelled", job["requestID"] as! String, counters("2"), identity: job)
            case "auth_cancel", "logout":
                if !authenticated && !loginRequest.isEmpty { try emit("auth_cancelled", loginRequest, ["sessionID": session, "reason": "cancelled"]) }
                Thread.sleep(forTimeInterval: 0.08)
                try Data("drained".utf8).write(to: root.appendingPathComponent("auth-drained"))
                try emit("logged_out", request, ["sessionID": session])
            case "shutdown": try emit("stopped", request); return
            default: exit(83)
            }
        }
        _ = cancelledRequest
    }
    static func run(_ root: URL) async throws {
        let burstPipe = Pipe()
        let expectedBurst = (0..<734).map { "runtime-plan-chunk-\($0)" }
            + (0..<734).map { "runtime-verified-chunk-\($0)" }
        let burstWriter = Task.detached {
            for line in expectedBurst {
                try burstPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            }
            try burstPipe.fileHandleForWriting.close()
        }
        var receivedBurst: [String] = []
        for try await data in SteamContentPipe.lines(burstPipe.fileHandleForReading) {
            receivedBurst.append(String(decoding: data, as: UTF8.self))
            try await Task.sleep(for: .milliseconds(1))
        }
        try await burstWriter.value
        try check(receivedBurst == expectedBurst,
                  "pipe applies demand backpressure and preserves all 734 plan plus 734 verification chunks")
        let publicDirectory = root.appendingPathComponent("public")
        try fm.createDirectory(at: publicDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        do { _ = try SteamContentBroker(workspaceURL: publicDirectory); throw Failure(message: "public directory accepted") } catch is SteamContentBrokerError { try check(true, "workspace requires private0700 directory") }
        let (broker, dir) = try fixture(root, "success")
        let link = root.appendingPathComponent("symlink"); try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        do { _ = try SteamContentBroker(workspaceURL: link); throw Failure(message: "symlink accepted") } catch is SteamContentBrokerError { try check(true, "workspace rejects symlink aliases") }
        let reopenedCanonical = try SteamContentBroker(workspaceURL: broker.workspaceURL)
        try check(reopenedCanonical.workspaceURL.path == broker.workspaceURL.path, "workspace accepts exact POSIX canonical spelling as well as macOS system path alias")
        try await broker.start()
        try check(broker.isReady && broker.state == .idle && !fm.fileExists(atPath: dir.appendingPathComponent("login-received").path), "start/ready never starts authentication")
        try check(try String(contentsOf: dir.appendingPathComponent("launch-check"), encoding: .utf8) == "clean", "child argv contains workspace only and credentials are absent from environment")
        var states: [SteamLoginState] = []; broker.onStateChange = { states.append($0) }
        try await login(broker)
        try check(broker.state == .loggedIn(userID: nil) && broker.hasInMemoryRefreshSession && states.contains(.loggingIn), "only exact current auth_result marks authenticated; token remains private memory")
        let inspection=try await broker.inspectEngineAssets()
        let inspectionJSON=try JSONEncoder().encode(inspection)
        try check(inspection.manifests == [.init(depotID:431961,manifestID:555)] && inspection.paths == ["assets/materials/particle/halo.tex","assets/shaders/common_fragment.h","packages/engine_assets.pkg"] &&
                  !String(decoding:inspectionJSON,as:UTF8.self).contains("fixture_user"),"authenticated manifest-only inspection returns bounded redacted engine paths without account fields or chunks")
        let inventory=try await broker.inspectEngineAssetInventory()
        let inventoryJSON=try JSONEncoder().encode(inventory)
        try check(inventory.complete && inventory.totalFileCount == 1 && inventory.files.first?.logicalPath == "fonts/Alcubierre.otf" &&
                  inventory.groups.first?.totalBytes == 4 && !String(decoding:inventoryJSON,as:UTF8.self).contains("fixture_user"),
                  "authenticated inventory validates complete chunked metadata aggregates and canonical report hash")
        let runtime=try await broker.sceneRuntimeAssets()
        try check(runtime.files.count==2 && runtime.cacheRoot.path.contains("/scene-runtime-assets/") &&
                  runtime.files.map(\.relativePath)==["assets/fonts/Alcubierre.otf","assets/shaders/common.h"] &&
                  (try Data(contentsOf:runtime.cacheRoot.appendingPathComponent("assets/shaders/common.h")))==Data([5,6,7]) &&
                  broker.lastRuntimeDiagnosticPhase=="complete_validation",
                  "fixed Scene runtime dataset returns a manifest-bound fully rehashed assets tree")
        do{_ = try await broker.engineAssets(desiredResources:["../arbitrary"]);throw Failure(message:"unsafe engine path accepted")}
        catch SteamContentBrokerError.invalidInput{try check(true,"Swift bridge rejects arbitrary engine paths before helper request")}
        var engineSamples:[SteamContentProgress]=[]
        let engine=try await broker.engineAssets(desiredResources:["fonts/Alcubierre.otf"]){engineSamples.append($0)}
        let mapped=engine.logicalFileMappings["fonts/Alcubierre.otf"]!
        try check(engine.manifestIdentity == .init(sha256:String(repeating:"b",count:64),depotID:431961,manifestID:199) &&
                  engine.cacheRoot.path == dir.appendingPathComponent("engine-assets/\(String(repeating:"b",count:64))/content").path &&
                  (try Data(contentsOf:mapped)) == Data([1,2,3,4]),"engine bundle returns manifest-bound cache root and verified exact builtin-font mapping")
        try check(engineSamples.count == 2 && engineSamples.last?.verifiedBytes == 4,"engine transfer shares monotonic progress semantics with Workshop downloads")
        var samples: [SteamContentProgress] = []
        let job = UUID()
        let result = try await broker.download(publishedFileID: "7", jobID: job, epoch: 1) { samples.append($0) }
        try check(result.validationRequired && result.contentURL.path == dir.appendingPathComponent("items/7/99/content").path && (try Data(contentsOf: result.contentURL.appendingPathComponent("fixture.bin"))) == Data([1,2,3,4]), "download returns canonical content directory with actual fixture bytes; native validation still required")
        try check(samples.count == 2 && samples[0].verifiedBytes == 2 && result.progress.verifiedBytes == 4 && result.progress.receivedPayloadBytes == 8 && result.progress.fraction == 1, "retry-inclusive network bytes remain distinct from verified logical fraction")
        do { _ = try await broker.download(publishedFileID: "7", jobID: job, epoch: 1); throw Failure(message: "stale epoch accepted") } catch is SteamContentBrokerError { try check(true, "replayed job epoch is rejected before sending") }
        let largeEpoch = try await broker.download(publishedFileID: "7", jobID: UUID(), epoch: UInt64.max)
        try check(largeEpoch.progress.verifiedBytes == 4, "UInt64 epoch remains exact beyond JSON floating-point precision")
        await broker.logout()
        try check(broker.state == .idle && !broker.hasInMemoryRefreshSession, "logout waits closing ACK and releases memory-only refresh credentials")
        await broker.shutdown()
        let pid = Int32(try String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8))!
        try check(!broker.isReady && kill(pid, 0) == -1 && errno == ESRCH, "shutdown drains and reaps owned process with no child remaining")
        for mode in ["guard", "confirmation", "qr"] {
            let (b, d) = try fixture(root, mode)
            let task = Task { try await login(b) }
            try await wait("challenge") { b.challenge != nil }
            try check(b.state == (mode == "guard" ? .awaitingGuardCode : .awaitingMobileConfirmation), "\(mode) challenge maps honest login state before ACK")
            if mode == "qr" {
                do { try b.respondToChallenge(accepted: true); throw Failure(message: "QR spoof accepted") } catch is SteamContentBrokerError { try check(true, "QR approval cannot be spoofed with host confirmation") }
                task.cancel(); _ = try? await task.value
                try check(fm.fileExists(atPath: d.appendingPathComponent("auth-drained").path) && b.state == .cancelled && !b.hasInMemoryRefreshSession, "authentication cancellation waits logged_out drain and never publishes token")
            } else {
                try b.respondToChallenge(code: mode == "guard" ? "AB123" : nil, accepted: mode == "confirmation" ? true : nil)
                try await task.value; try check(b.state == .loggedIn(userID: nil), "\(mode) response preserves exact helper-issued IDs and awaits auth_result")
            }
            await b.shutdown()
        }
        let (slow, slowDirectory) = try fixture(root, "slow-ready")
        let slowLogin = Task { try await login(slow) }
        try await wait("reserved auth") { slow.state == .preparing }
        await slow.logout(); _ = try? await slowLogin.value
        try check(slow.state == .idle && !fm.fileExists(atPath: slowDirectory.appendingPathComponent("login-received").path), "logout during helper handshake cancels reserved login before any credentials are sent")
        await slow.shutdown()
        let (explicit, explicitDirectory) = try fixture(root, "held"); try await login(explicit)
        let explicitTask = Task { try await explicit.download(publishedFileID: "7") }
        try await wait("explicit partial") { explicit.progress.verifiedBytes == 2 }
        await explicit.cancelDownload(); _ = try? await explicitTask.value
        try check(fm.fileExists(atPath: explicitDirectory.appendingPathComponent("drained").path) && !explicit.isDownloading, "explicit cancelDownload waits original download terminal and handle drain")
        await explicit.shutdown()
        let (engineCancel,engineCancelDirectory)=try fixture(root,"engine-held");try await login(engineCancel)
        let engineTask=Task{try await engineCancel.engineAssets(desiredResources:["materials/particle/halo.tex"])}
        try await wait("engine active"){engineCancel.isDownloading && engineCancel.progress.verifiedBytes==2}
        await engineCancel.cancelDownload();_ = try? await engineTask.value
        try check(fm.fileExists(atPath:engineCancelDirectory.appendingPathComponent("drained").path) && !engineCancel.isDownloading,
                  "engine cancellation uses the same job drain and never reports unknown success")
        await engineCancel.shutdown()
        let (inspectCancel,inspectCancelDirectory)=try fixture(root,"engine-inspect-held");try await login(inspectCancel)
        let inspectTask=Task{try await inspectCancel.inspectEngineAssets()}
        try await wait("inspection active"){inspectCancel.isDownloading}
        inspectTask.cancel();_ = try? await inspectTask.value
        try check(fm.fileExists(atPath:inspectCancelDirectory.appendingPathComponent("drained").path) && !inspectCancel.isDownloading,
                  "manifest-only inspection cancellation drains the shared authenticated broker job")
        await inspectCancel.shutdown()
        let (inventoryCancel,inventoryCancelDirectory)=try fixture(root,"inventory-held");try await login(inventoryCancel)
        let inventoryTask=Task{try await inventoryCancel.inspectEngineAssetInventory()}
        try await wait("inventory active"){inventoryCancel.isDownloading}
        inventoryTask.cancel();_ = try? await inventoryTask.value
        try check(fm.fileExists(atPath:inventoryCancelDirectory.appendingPathComponent("drained").path) && !inventoryCancel.isDownloading,
                  "inventory cancellation drains the shared authenticated broker job")
        await inventoryCancel.shutdown()
        let (runtimeCancel,runtimeCancelDirectory)=try fixture(root,"runtime-held");try await login(runtimeCancel)
        let runtimeTask=Task{try await runtimeCancel.sceneRuntimeAssets()};try await wait("runtime active"){runtimeCancel.progress.verifiedBytes==2}
        runtimeTask.cancel();_ = try? await runtimeTask.value
        try check(fm.fileExists(atPath:runtimeCancelDirectory.appendingPathComponent("drained").path) && !runtimeCancel.isDownloading,
                  "Scene runtime dataset cancellation drains before releasing the broker")
        await runtimeCancel.shutdown()
        let (badRuntime,_)=try fixture(root,"runtime-hash");try await login(badRuntime)
        do{_ = try await badRuntime.sceneRuntimeAssets();throw Failure(message:"runtime hash accepted")}
        catch SteamContentBrokerError.protocolViolation{try check(badRuntime.lastRuntimeDiagnosticPhase=="complete_validation","Scene runtime dataset rejects a tampered verified file hash with a fixed safe phase")}
        await badRuntime.shutdown()
        let (safeRuntimeFailure,_)=try fixture(root,"runtime-safe-failure");try await login(safeRuntimeFailure)
        do{_ = try await safeRuntimeFailure.sceneRuntimeAssets();throw Failure(message:"safe runtime failure accepted")}
        catch SteamContentBrokerError.helperRejected(let code){try check(code=="scene_runtime_transfer_io","fixed runtime phase/category code crosses the bridge without exposing exception text")}
        await safeRuntimeFailure.shutdown()
        let (badInventory,_)=try fixture(root,"inventory-hash");try await login(badInventory)
        do{_ = try await badInventory.inspectEngineAssetInventory();throw Failure(message:"tampered inventory accepted")}
        catch SteamContentBrokerError.protocolViolation{try check(true,"inventory rejects a mismatched canonical report hash")}
        await badInventory.shutdown()
        for mode in ["engine-hash","engine-symlink","engine-hardlink","engine-public-dir","engine-path"] {
            let (b,_)=try fixture(root,mode);try await login(b)
            do{_ = try await b.engineAssets(desiredResources:["materials/particle/halo.tex"]);throw Failure(message:"unsafe engine result accepted")}
            catch SteamContentBrokerError.protocolViolation{try check(true,"\(mode) engine cache response fails strict path/hash/no-follow validation")}
            await b.shutdown()
        }
        let (badInspection,_)=try fixture(root,"engine-inspect-invalid");try await login(badInspection)
        do{_ = try await badInspection.inspectEngineAssets();throw Failure(message:"unsafe inspection accepted")}
        catch SteamContentBrokerError.protocolViolation{try check(true,"inspection rejects paths outside bounded engine prefixes")}
        await badInspection.shutdown()
        for mode in ["held", "cancel-timeout", "cancel-race"] {
            let (b, d) = try fixture(root, mode); try await login(b)
            let task = Task { try await b.download(publishedFileID: "7") }
            try await wait("partial") { b.progress.verifiedBytes == 2 }
            let before = Date(); task.cancel()
            var rejected = false
            do { _ = try await task.value } catch { rejected = true }
            try check(rejected && !b.isDownloading && (mode == "cancel-race" || Date().timeIntervalSince(before) >= 0.1), "\(mode) task cancellation waits terminal or kill+process exit")
            if mode == "held" { try check(fm.fileExists(atPath: d.appendingPathComponent("drained").path) && b.isReady, "cancel_requested is not mistaken for stopped writes; terminal retains reusable session") }
            else if mode == "cancel-timeout" { try check(!b.isReady, "unresponsive cancel kills only owned child and reaps before returning") }
            else { try await Task.sleep(for: .milliseconds(40)); try check(b.isReady, "completion winning cancellation race drains safely; late stale_job rejection does not kill reusable session") }
            await b.shutdown()
        }
        for mode in ["nonce", "seq", "epoch", "malformed", "oversized", "truncated", "overflow", "escape", "request", "session"] {
            let (b, _) = try fixture(root, mode)
            var failed = false
            do { try await login(b); _ = try await b.download(publishedFileID: "7") } catch { failed = true }
            try check(failed && !b.isReady && !b.isDownloading, "\(mode) invalid/stale response cannot publish completion or revive authentication")
            await b.shutdown()
        }
        for code in ["session_not_authenticated", "steam_disconnected", "stale_session", "auth_adapter_not_authenticated"] {
            for envelope in ["failed", "rejected"] {
                let (b, d) = try fixture(root, "lost-" + envelope + "-" + code); try await login(b)
                let oldPID = Int32(try String(contentsOf:d.appendingPathComponent("pid"),encoding:.utf8))!
                var rejected = false
                do { _ = try await b.download(publishedFileID:"7") } catch { rejected = error.localizedDescription.contains("重新连接") }
                if case .failed = b.state {
                    try check(rejected && !b.isReady && !b.hasInMemoryRefreshSession && kill(oldPID,0) == -1 && errno == ESRCH,
                        "\(envelope) \(code) invalidates only current session before terminal; owned child reaped and reconnect reason visible")
                } else { throw Failure(message:"auth loss remained logged in") }
                try await login(b)
                try check(b.isReady && b.state == .loggedIn(userID:nil), "\(envelope) \(code) allows fresh ACK-based reconnection after failed session drain")
                await b.shutdown()
            }
        }
        for mode in ["cdn-failed", "cdn-failed-unsafe"] {
            let (b, _) = try fixture(root, mode); try await login(b)
            var retryVisible = false
            do { _ = try await b.download(publishedFileID:"7") } catch {
                retryVisible = (error as? SteamContentBrokerError) == .helperRejected("no_supported_https_cdn") &&
                    error.localizedDescription.contains("重试")
            }
            try check(retryVisible && b.isReady && b.state == .loggedIn(userID:nil) && b.hasInMemoryRefreshSession,
                "\(mode) ordinary HTTPS CDN failure keeps authenticated session and actionable retry message")
            if mode == "cdn-failed" { try check(b.lastCDNDirectoryDiagnostics?.total == 2 && b.lastCDNDirectoryDiagnostics?.groups.first?.type == "CDN", "bounded fixed-enum CDN aggregate diagnostics retain no host/token fields") }
            else { try check(b.lastCDNDirectoryDiagnostics == nil, "unknown diagnostic strings are discarded without logging or signing out") }
            await b.shutdown()
        }
        let (redacted, _) = try fixture(root, "rejected-secret")
        var secretRedacted = false
        do { try await login(redacted) } catch { secretRedacted = !error.localizedDescription.contains("fixture_secret") }
        try check(secretRedacted && !redacted.state.displayText.contains("fixture_secret"), "unknown helper failure text cannot reflect secret-shaped content into public errors or state")
        await redacted.shutdown()
        if let index = CommandLine.arguments.firstIndex(of: "--helper"), index + 1 < CommandLine.arguments.count {
            let workspace = root.appendingPathComponent("actual-helper-startup")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let actual = try SteamContentBroker(executableURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]), workspaceURL: workspace, responseTimeout: .seconds(10))
            try await actual.start()
            try check(actual.isReady && actual.state == .idle && !actual.hasInMemoryRefreshSession, "actual production helper ready handshake works without login or Steam connection")
            await actual.shutdown()
            try check(!actual.isReady, "actual production helper shutdown ACK and process exit drain without authentication")
            try check(try fm.contentsOfDirectory(atPath: workspace.path).isEmpty, "actual start/shutdown writes no account, cache, checkpoint or content files")
        }
        try await savedChecks(root)
        print("RESULT \(checks) native broker checks passed; controlled real children/temporary bytes, no Steam network/account/profile access")
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--workspace-root" { try child(URL(fileURLWithPath: CommandLine.arguments[2])); return }
        let root = fm.temporaryDirectory.appendingPathComponent("GW-Steam-Broker-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: root) }
        try await run(root)
    }
}
