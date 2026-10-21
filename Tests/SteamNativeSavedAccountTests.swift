import Foundation

private actor SavedAccountFixtureStore: SteamContentSessionStoring {
    var value: SteamContentSavedSession?
    var readFails = false, writeFails = false, deleteFails = false
    var delay: Int = 0
    var loads = 0, saves = 0, deletes = 0
    var pauseDeletes = false
    var deleteWaiters: [CheckedContinuation<Void, Never>] = []
    init(_ value: SteamContentSavedSession?) { self.value = value }
    func load() async throws -> SteamContentSavedSession? {
        loads += 1
        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
        if readFails { throw SteamContentSessionStoreError.readFailed }; return value
    }
    func save(_ session: SteamContentSavedSession) async throws {
        saves += 1; if writeFails { throw SteamContentSessionStoreError.saveFailed }; value = session
    }
    func delete() async throws {
        deletes += 1
        if pauseDeletes { await withCheckedContinuation { deleteWaiters.append($0) } }
        if deleteFails { throw SteamContentSessionStoreError.deleteFailed }; value = nil
    }
    func faults(read: Bool = false, write: Bool = false, delete: Bool = false, delay: Int = 0) {
        readFails = read; writeFails = write; deleteFails = delete; self.delay = delay
    }
    func pauseDeletion() { pauseDeletes = true }
    func releaseDeletion() { if !deleteWaiters.isEmpty { deleteWaiters.removeFirst().resume() } }
    func snapshot() -> (SteamContentSavedSession?, Int, Int, Int) { (value, loads, saves, deletes) }
}

@main @MainActor enum SteamNativeSavedAccountTests {
    static let fm = FileManager.default
    static var checks = 0
    static let saved = SteamContentSavedSession(username: "fixture_account", refreshToken: "SAVED_FIXTURE_REFRESH", guardData: "SAVED_FIXTURE_GUARD")
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }; checks += 1; print("PASS \(name)")
    }
    static func wait(_ name: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<800 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(message: "TIMEOUT " + name)
    }
    static func fixture(_ root: URL, mode: String, cache: Bool = false) throws -> (SteamCMDLayout, URL) {
        let base = root.appendingPathComponent(UUID().uuidString)
        let layout = SteamCMDLayout(root: base.appendingPathComponent("legacy"))
        try fm.createDirectory(at: layout.homeURL.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data(mode.utf8).write(to: base.appendingPathComponent("mode"))
        if cache { try Data("\"users\" { \"0\" { \"AccountName\" \"fixture_account\" } }".utf8).write(to: layout.loginUsersURL) }
        let helper = base.appendingPathComponent("helper")
        try Data(#"""
        #!/usr/bin/python3
        import json,sys,uuid,pathlib,time
        base=pathlib.Path(__file__).parent; seq=0; nonce=str(uuid.uuid4()); sid=str(uuid.uuid4()); auth=None
        def emit(kind,request,detail=None):
            global seq
            seq+=1
            print(json.dumps(dict(v=1,sessionNonce=nonce,seq=seq,kind=kind,requestID=request,detail=detail or {})),flush=True)
        def result():
            emit('auth_result',auth,dict(sessionID=sid,accountName='fixture_account',steamID='12345',refreshToken='ROTATED_FIXTURE_REFRESH',guardData='ROTATED_FIXTURE_GUARD'))
        emit('ready','startup',dict(productionAuthentication=True,productionWorkshopDownload=True))
        for raw in sys.stdin:
            c=json.loads(raw); request=c['requestID']; command=c['commandName']; mode=(base/'mode').read_text()
            if command=='login':
                auth=request; a=c['auth']; assert a['username']=='fixture_account'
                count_file=base/'auth-count'
                attempt=int(count_file.read_text())+1 if count_file.exists() else 1
                count_file.write_text(str(attempt))
                with (base/'auth-methods').open('a') as trace: trace.write(a['method']+'\n')
                if a['method']=='refresh': assert a['refreshToken'] in ('SAVED_FIXTURE_REFRESH','ROTATED_FIXTURE_REFRESH') and 'password' not in a
                else: assert a['method']=='credentials' and a['password']=='SAVED_FIXTURE_PASSWORD'
                emit('auth_started',auth,dict(sessionID=sid))
                if mode in ('network','revoked') or (mode=='network-once' and attempt==1) or (mode=='network-twice' and attempt<=2):
                    emit('auth_failed',auth,dict(sessionID=sid,reason='steam_logon_26' if mode=='revoked' else 'steam_disconnected'))
                elif mode=='timeout-once' and attempt==1: emit('auth_failed',auth,dict(sessionID=sid,reason='steam_auth_timeout'))
                elif mode=='other-failure': emit('auth_failed',auth,dict(sessionID=sid,reason='steam_auth_failed'))
                elif mode=='late': emit('auth_challenge',auth,dict(sessionID=sid,challengeID=str(uuid.uuid4()),type='email_code',previousIncorrect=False))
                else: time.sleep(.1); result()
            elif command in ('auth_cancel','logout'):
                if mode=='late': result()
                emit('logged_out',request,dict(sessionID=sid))
            elif command=='shutdown': emit('stopped',request); break
            else: raise AssertionError('unexpected isolated command')
        """#.utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try Data(#"""
        #!/bin/sh
        printf 'Steam>\n'
        while IFS= read -r line; do
          case "$line" in
            login*) printf 'Waiting for user info...OK\n';;
            quit) exit 0;;
            *) exit 91;;
          esac
        done
        """#.utf8).write(to: layout.executableURL)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.executableURL.path)
        return (layout, helper)
    }
    private static func manager(_ layout: SteamCMDLayout, helper: URL, store: SavedAccountFixtureStore?, probes: LockedBox<Int> = .init(0), retryDelays: [Duration] = []) -> SteamAccountManager {
        SteamAccountManager(layout: layout, capabilityOperation: { layout in
            probes.with { $0 += 1 }
            return .init(status: .ready(version: "fixture"), executablePath: layout.executableURL.path,
                         architecture: .arm64, rosetta: .notRequired, hostArchitecture: "fixture", binaryExists: true, evidence: [])
        }, makeLoginSession: { SteamLoginSession(executable: $0, layout: $1, commandTimeout: 3, settleGrace: 0.05, shutdownTimeout: 1) },
        nativeContentExecutableURL: helper, sessionStore: store, savedSessionRetryDelays: retryDelays)
    }
    private static func authCount(_ helper: URL) -> Int {
        Int((try? String(contentsOf: helper.deletingLastPathComponent().appendingPathComponent("auth-count"), encoding: .utf8)) ?? "0") ?? 0
    }
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("GWSavedAccount-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let (layout, helper) = try fixture(root, mode: "success", cache: true)
        let store = SavedAccountFixtureStore(saved), probes = LockedBox(0)
        let a = manager(layout, helper: helper, store: store, probes: probes)
        var callbacks = 0; a.onDownloadSessionReady = { callbacks += 1 }
        async let first: Void = a.prepareForDownloads()
        async let second: Void = a.prepareForDownloads()
        _ = await (first, second)
        try check(a.isNativeContentReady && a.isSignedIn && callbacks == 1, "concurrent startup preparation restores saved token once and waits for real authentication ACK")
        try check(probes.with { $0 } == 0 && a.report == nil, "saved native session takes priority over existing legacy cache and dependency probe")
        try check(a.rememberedUsername.isEmpty, "saved identity stays broker-private rather than copying into the form")
        let afterAuth = await store.snapshot()
        try check(afterAuth.0?.refreshToken == "ROTATED_FIXTURE_REFRESH" && afterAuth.2 == 1, "authenticated refresh rotation is saved only after actual helper ACK")
        try check(!a.loginStatus.recentLines.joined().contains("FIXTURE") && !a.loginStatus.recentLines.joined().contains("fixture_account"), "saved token identity and guard data never appear in account diagnostics")
        await a.uninstallSteamCMD()
        try check(a.isNativeContentReady && a.isSignedIn && a.loginState == .loggedIn(userID: nil),
                  "removing only temporary compatibility SteamCMD never cancels the independent native authenticated session")
        await a.shutdownNativeContent()
        let afterQuit = await store.snapshot()
        try check(afterQuit.0 != nil && afterQuit.3 == 0, "quit shutdown preserves saved session and never logs out or deletes it")
        let restarted = manager(layout, helper: helper, store: store)
        await restarted.prepareForDownloads()
        try check(restarted.isNativeContentReady, "new manager restores saved token after previous manager shutdown without username password or OTP")
        restarted.signOut()
        try await wait("signout saved drain") { !restarted.isNativeContentCleaningUp && !restarted.hasCachedSession }
        let afterLogout = await store.snapshot()
        try check(afterLogout.0 == nil && afterLogout.3 == 1 && !restarted.isNativeContentReady, "explicit signout deletes saved native session and own legacy cache")
        await restarted.shutdownNativeContent()

        let (emptyLayout, emptyHelper) = try fixture(root, mode: "success", cache: true)
        let empty = SavedAccountFixtureStore(nil), emptyProbes = LockedBox(0)
        let legacy = manager(emptyLayout, helper: emptyHelper, store: empty, probes: emptyProbes)
        await legacy.prepareForDownloads()
        try await wait("missing saved uses legacy") { legacy.isSignedIn }
        try check(!legacy.isNativeContentReady && emptyProbes.with { $0 } == 1, "only missing saved session allows legacy capability probe and cached authentication")
        await legacy.shutdownNativeContent()

        for mode in ["network", "revoked"] {
            let (layout, helper) = try fixture(root, mode: mode, cache: true)
            let store = SavedAccountFixtureStore(saved), probes = LockedBox(0)
            let account = manager(layout, helper: helper, store: store, probes: probes)
            await account.prepareForDownloads()
            try await wait("failed restore drain") { !account.isNativeContentCleaningUp }
            let snapshot = await store.snapshot()
            try check(!account.isNativeContentReady && !account.isSignedIn && probes.with { $0 } == 0,
                      "\(mode) saved restore failure never falls through to misleading legacy authentication")
            if mode == "network" {
                try check(snapshot.0 != nil && snapshot.3 == 0 && account.nativeSavedSessionRetryAvailable,
                          "transient network failure preserves token and exposes retry rather than requiring password")
                try check(WorkshopAccountPresentation(account: account).actionTitle == "重试连接", "transient saved-session notice offers same-level retry")
                try Data("success".utf8).write(to: helper.deletingLastPathComponent().appendingPathComponent("mode"))
                account.startSignIn()
                try await wait("network retry saved ACK") { account.isNativeContentReady }
                try check(account.rememberedUsername.isEmpty, "retry restores private saved identity without asking for credentials")
            } else {
                try check(snapshot.0 == nil && snapshot.3 == 1 && !account.nativeSavedSessionRetryAvailable,
                          "explicit revoked refresh token is deleted and asks for new manual login")
                account.startSignIn()
                try check(account.loginState == .awaitingUsername, "revoked session returns to existing same-layer username form")
                account.cancelSignIn()
            }
            await account.shutdownNativeContent()
        }

        let (lateLayout, lateHelper) = try fixture(root, mode: "late", cache: true)
        let lateStore = SavedAccountFixtureStore(saved), lateProbes = LockedBox(0)
        let late = manager(lateLayout, helper: lateHelper, store: lateStore, probes: lateProbes)
        let preparation = Task { await late.prepareForDownloads() }
        try await wait("pending saved Guard") { late.loginState == .awaitingGuardCode }
        late.cancelSignIn()
        await preparation.value
        try await wait("cancel saved drain") { !late.isNativeContentCleaningUp }
        let preserved = await lateStore.snapshot()
        try check(!late.isNativeContentReady && late.loginState == .cancelled && preserved.0?.refreshToken == saved.refreshToken && preserved.3 == 0,
                  "cancelled restoration discards late success and preserves original saved session")
        late.startNativeSignIn()
        try check(late.loginState == .awaitingUsername && lateProbes.with { $0 } == 0, "manual flow after cancelled restore cannot be overwritten by legacy cache")
        late.cancelSignIn(); await late.shutdownNativeContent()

        let (faultLayout, faultHelper) = try fixture(root, mode: "success", cache: true)
        let faultStore = SavedAccountFixtureStore(saved), faultProbes = LockedBox(0)
        await faultStore.faults(read: true)
        let fault = manager(faultLayout, helper: faultHelper, store: faultStore, probes: faultProbes)
        await fault.prepareForDownloads()
        try await wait("read fault cleanup") { !fault.isNativeContentCleaningUp }
        try check(fault.nativeSavedSessionRetryAvailable && !fault.isNativeContentReady && faultProbes.with { $0 } == 0,
                  "Keychain-boundary read failure is visible and does not pretend no record or fall back to legacy")
        await faultStore.faults()
        fault.startSignIn(); try await wait("read access retry") { fault.isNativeContentReady }
        try check(fault.isNativeContentReady, "same-layer retry succeeds when injected storage access recovers")
        await fault.shutdownNativeContent()

        let (saveLayout, saveHelper) = try fixture(root, mode: "success")
        let saveStore = SavedAccountFixtureStore(nil)
        await saveStore.faults(write: true)
        let save = manager(saveLayout, helper: saveHelper, store: saveStore)
        save.startNativeSignIn(); save.submitUsername("fixture_account"); save.submitPassword("SAVED_FIXTURE_PASSWORD")
        try await wait("save failure auth ACK") { save.isNativeContentReady }
        try check(save.nativeSessionNotice?.contains("未") == true || save.nativeSessionNotice?.contains("无法") == true,
                  "failed persistence does not discard valid current authentication and clearly reports it was not remembered")
        let failedSave = await saveStore.snapshot()
        try check(failedSave.0 == nil && failedSave.2 == 1 && save.canRetryRememberingNativeSession, "save failure does not fabricate a stored session and offers retry")
        await saveStore.faults()
        await save.retrySavingNativeSession()
        let retriedSave = await saveStore.snapshot()
        try check(retriedSave.0 != nil && retriedSave.2 == 2 && !save.canRetryRememberingNativeSession && save.isNativeContentReady,
                  "retrying persistence remembers the current session without reauthenticating or dropping active connection")
        await save.shutdownNativeContent()

        let (noBrokerLayout, noBrokerHelper) = try fixture(root, mode: "success")
        let noBrokerStore = SavedAccountFixtureStore(saved)
        let noBroker = manager(noBrokerLayout, helper: noBrokerHelper, store: noBrokerStore)
        noBroker.signOut()
        try await wait("signout before startup") { !noBroker.isNativeContentCleaningUp }
        let erasedWithoutBroker = await noBrokerStore.snapshot()
        try check(erasedWithoutBroker.0 == nil && erasedWithoutBroker.3 == 1, "signout deletes saved record even before any broker or helper has been created")
        await noBroker.shutdownNativeContent()
        let (doubleLayout, doubleHelper) = try fixture(root, mode: "success")
        let doubleStore = SavedAccountFixtureStore(saved)
        await doubleStore.pauseDeletion()
        let double = manager(doubleLayout, helper: doubleHelper, store: doubleStore)
        double.signOut(); double.signOut()
        for _ in 0..<300 { if await doubleStore.snapshot().3 == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        await doubleStore.releaseDeletion()
        for _ in 0..<300 { if await doubleStore.snapshot().3 == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try check(double.isNativeContentCleaningUp, "first logout cleanup cannot reopen authentication while a newer queued deletion is still pending")
        double.startNativeSignIn()
        try check(!double.isUsingNativeSignIn, "manual login cannot race outstanding deletion and lose a newly saved token")
        await doubleStore.releaseDeletion()
        try await wait("double logout completion") { !double.isNativeContentCleaningUp }
        await double.shutdownNativeContent()

        for (mode, expectedAttempts) in [("network-once", 2), ("network-twice", 3), ("timeout-once", 2)] {
            let (layout, helper) = try fixture(root, mode: mode, cache: true)
            let store = SavedAccountFixtureStore(saved), probes = LockedBox(0)
            let account = manager(layout, helper: helper, store: store, probes: probes,
                                  retryDelays: [.milliseconds(20), .milliseconds(40)])
            var ready = 0; account.onDownloadSessionReady = { ready += 1 }
            async let prepareA: Void = account.prepareForDownloads()
            async let prepareB: Void = account.prepareForDownloads()
            _ = await (prepareA, prepareB)
            try check(account.isNativeContentReady && authCount(helper) == expectedAttempts && ready == 1,
                      "\(mode) startup retries only its saved-session restore and publishes readiness once after real ACK")
            let methods = try String(contentsOf: helper.deletingLastPathComponent().appendingPathComponent("auth-methods"), encoding: .utf8)
            let snapshot = await store.snapshot()
            try check(methods.split(separator: "\n").allSatisfy { $0 == "refresh" } && probes.with { $0 } == 0 && snapshot.3 == 0,
                      "\(mode) bounded recovery never asks for credentials, probes legacy or deletes the saved identity")
            await account.shutdownNativeContent()
        }

        let (boundedLayout, boundedHelper) = try fixture(root, mode: "network")
        let boundedStore = SavedAccountFixtureStore(saved)
        let bounded = manager(boundedLayout, helper: boundedHelper, store: boundedStore,
                              retryDelays: [.milliseconds(10), .milliseconds(20), .milliseconds(30)])
        await bounded.prepareForDownloads()
        try await wait("bounded network cleanup") { !bounded.isNativeContentCleaningUp }
        try check(authCount(boundedHelper) == 3 && !bounded.isNativeContentReady && bounded.nativeSavedSessionRetryAvailable,
                  "persistent network failure stops after at most three attempts and offers explicit retry")
        bounded.retryNativeSavedSession()
        try await wait("explicit single retry finishes") { !bounded.isUsingNativeSignIn && !bounded.isNativeContentCleaningUp }
        try check(authCount(boundedHelper) == 4, "explicit retry is one attempt rather than another automatic retry loop")
        await bounded.shutdownNativeContent()

        for mode in ["revoked", "other-failure"] {
            let (layout, helper) = try fixture(root, mode: mode)
            let store = SavedAccountFixtureStore(saved)
            let account = manager(layout, helper: helper, store: store,
                                  retryDelays: [.milliseconds(10), .milliseconds(20)])
            await account.prepareForDownloads()
            try await wait("nontransient cleanup") { !account.isNativeContentCleaningUp }
            try check(authCount(helper) == 1 && !account.isNativeContentReady,
                      "\(mode) is not automatically retried as a network interruption")
            await account.shutdownNativeContent()
        }

        let (accessLayout, accessHelper) = try fixture(root, mode: "success")
        let accessStore = SavedAccountFixtureStore(saved)
        await accessStore.faults(read: true)
        let access = manager(accessLayout, helper: accessHelper, store: accessStore,
                             retryDelays: [.milliseconds(10), .milliseconds(20)])
        await access.prepareForDownloads()
        try await wait("access denial cleanup") { !access.isNativeContentCleaningUp }
        let accessSnapshot = await accessStore.snapshot()
        try check(accessSnapshot.1 == 1 && accessSnapshot.3 == 0 && authCount(accessHelper) == 0,
                  "Keychain access denial is surfaced once without repeated prompts or credential deletion")
        await access.shutdownNativeContent()

        for stopByQuit in [false, true] {
            let (layout, helper) = try fixture(root, mode: "network")
            let store = SavedAccountFixtureStore(saved)
            let account = manager(layout, helper: helper, store: store, retryDelays: [.seconds(3), .seconds(3)])
            let preparation = Task { await account.prepareForDownloads() }
            try await wait("waiting in startup backoff") { account.nativeSessionNotice?.contains("正在重试") == true }
            try check(account.loginState.isActive && !account.isNativeContentReady && authCount(helper) == 1,
                      "retry delay stays cancellable and never presents the saved session as already connected")
            if stopByQuit { await account.shutdownNativeContent() }
            else { account.cancelSignIn() }
            await preparation.value
            try await wait("backoff cancellation drain") { !account.isNativeContentCleaningUp }
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = await store.snapshot()
            try check(authCount(helper) == 1 && !account.isNativeContentReady && snapshot.0 != nil && snapshot.3 == 0,
                      stopByQuit ? "quit cancels the startup retry delay without spawning a later login or losing saved state"
                      : "user cancel stops the startup retry delay without a later login or losing saved state")
            if !stopByQuit { await account.shutdownNativeContent() }
        }
        print("RESULT \(checks) saved-session account checks passed; injected actor store + controlled local child, no Security API/real Keychain/Steam/network")
    }
}
