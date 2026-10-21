import Foundation

@main @MainActor enum SteamNativeAccountTests {
    static var checks = 0
    static let fm = FileManager.default
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure(message: name) }; checks += 1; print("PASS \(name)")
    }
    static func wait(_ name: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(message: "TIMEOUT " + name)
    }
    static func fixture(_ root: URL, mode: String) throws -> (SteamCMDLayout, URL) {
        let base = root.appendingPathComponent(UUID().uuidString)
        let layout = SteamCMDLayout(root: base.appendingPathComponent("legacy"))
        try fm.createDirectory(at: layout.homeURL.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data(mode.utf8).write(to: base.appendingPathComponent("mode"))
        let helper = base.appendingPathComponent("helper")
        // Original protocol fixture, never invokes Steam or stores credentials/tokens.
        let script = #"""
        #!/usr/bin/python3
        import json,sys,uuid,pathlib,time
        base=pathlib.Path(__file__).parent
        seq=0; nonce=str(uuid.uuid4()); sid=str(uuid.uuid4()); auth=None
        def emit(kind,request,detail=None):
            global seq
            seq+=1
            print(json.dumps(dict(v=1,sessionNonce=nonce,seq=seq,kind=kind,requestID=request,detail=detail or {})),flush=True)
        def result():
            emit('auth_result',auth,dict(sessionID=sid,accountName='fixture_account',steamID='12345',refreshToken='NATIVE_FIXTURE_REFRESH',guardData='NATIVE_FIXTURE_GUARD'))
        emit('ready','startup',dict(productionAuthentication=True,productionWorkshopDownload=True))
        for raw in sys.stdin:
            c=json.loads(raw); command=c['commandName']; request=c['requestID']; mode=(base/'mode').read_text()
            if command=='login':
                auth=request
                assert c['auth']['method']=='credentials'
                assert c['auth']['username']=='fixture_account'
                assert c['auth']['password']=='NATIVE_FIXTURE_PASSWORD'
                emit('auth_started',auth,dict(sessionID=sid))
                if mode=='success':
                    time.sleep(.1); result()
                elif mode=='fail': emit('auth_failed',auth,dict(sessionID=sid,reason='authentication_failed'))
                else:
                    kind='device_confirmation' if mode=='mobile' else 'email_code'
                    emit('auth_challenge',auth,dict(sessionID=sid,challengeID=str(uuid.uuid4()),type=kind,previousIncorrect=False))
            elif command=='auth_response':
                if mode=='mobile': assert c['response']['accepted'] is True
                else: assert c['response']['code']=='ABCDE'
                emit('auth_response_accepted',request,dict(sessionID=sid))
                time.sleep(.4 if mode=='mobile' else .1); result()
            elif command in ('auth_cancel','logout'):
                # Deliberate late success tests generation/cancellation boundaries.
                if mode=='late' and auth: result()
                emit('logged_out',request,dict(sessionID=sid))
            elif command=='shutdown':
                emit('stopped',request); break
            else: raise AssertionError('unexpected fixture command')
        """#
        try Data(script.utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let legacy = #"""
        #!/bin/sh
        printf 'Steam>\n'
        while IFS= read -r line; do
          case "$line" in
            login*) printf 'Waiting for user info...OK\n';;
            quit) exit 0;;
            *) exit 93;;
          esac
        done
        """#
        try Data(legacy.utf8).write(to: layout.executableURL)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.executableURL.path)
        return (layout, helper)
    }
    static func manager(_ layout: SteamCMDLayout, helper: URL) -> SteamAccountManager {
        SteamAccountManager(layout: layout, capabilityOperation: { layout in
            .init(status: .ready(version: "fixture"), executablePath: layout.executableURL.path,
                  architecture: .arm64, rosetta: .notRequired, hostArchitecture: "fixture", binaryExists: true, evidence: [])
        }, makeLoginSession: { SteamLoginSession(executable: $0, layout: $1, commandTimeout: 3, settleGrace: 0.05, shutdownTimeout: 1) },
        nativeContentExecutableURL: helper)
    }
    static func begin(_ account: SteamAccountManager) throws {
        account.startSignIn()
        try check(account.nativeContentAvailable && !account.isNativeContentReady && account.loginState == .awaitingUsername,
                  "available native helper chooses manual inline username, not cached authentication")
        account.submitUsername("fixture_account")
        try check(account.loginState == .awaitingPassword && !account.isSignedIn, "username alone never connects")
        account.submitPassword("NATIVE_FIXTURE_PASSWORD")
    }
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("GWNativeAccount-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let (layout, helper) = try fixture(root, mode: "guard")
        // Legacy cache is intentionally present; manual native must never promote it.
        try Data("\"users\" { \"0\" { \"AccountName\" \"fixture_cached_account\" } }".utf8).write(to: layout.loginUsersURL)
        let account = manager(layout, helper: helper)
        var readyCallbacks = 0
        account.onDownloadSessionReady = { readyCallbacks += 1 }
        try check(account.report == nil && !account.isReady && account.hasCachedSession && !account.isNativeContentReady,
                  "native availability does not require ready SteamCMD and legacy cache does not authenticate native")
        try begin(account)
        try await wait("native Guard") { account.loginState == .awaitingGuardCode }
        try check(account.nativeContentBroker?.isReady == true && !account.isNativeContentReady && !account.isSignedIn,
                  "actual helper ready and challenge ACK are not authenticated ACK")
        try check(readyCallbacks == 0, "queue readiness callback never fires for helper ready or Guard challenge")
        account.submitGuardCode("ABCDE")
        try await wait("native authentication ACK") { account.isNativeContentReady }
        try check(account.isSignedIn && account.canAttemptAuthenticatedDownload && account.nativeContentBroker?.hasInMemoryRefreshSession == true,
                  "only real broker auth_result enables native downloads and in-memory refresh session")
        try check(readyCallbacks == 1, "native queue callback fires once after actual authentication ACK")
        try check(account.loginStatus.state == account.loginState, "native UI status is consistent with completed authentication")
        let messages = account.loginStatus.recentLines.joined()
        try check(!messages.contains("fixture_account") && !messages.contains("NATIVE_FIXTURE_") && !messages.contains("ABCDE"),
                  "account observable logs never contain username password Guard token or guard data")
        let workspace = layout.root.deletingLastPathComponent().appendingPathComponent("SteamContent")
        let nativeFiles = try fm.contentsOfDirectory(atPath: workspace.path)
        try check(nativeFiles.isEmpty, "native authentication writes no token/credential/session files")
        let connected = WorkshopAccountPresentation(account: account)
        try check(connected.message.contains("实时下载进度已启用"), "mainstream presentation reflects actual native ACK")
        account.signOut()
        try check(!account.isNativeContentReady && account.nativeContentBroker == nil && account.loginState == .idle,
                  "signout immediately detaches authenticated native state")
        try await wait("native signout drain") { !account.isNativeContentCleaningUp && !account.hasCachedSession }
        try check(account.rememberedUsername.isEmpty, "signout clears remembered identity and own legacy cache")
        await account.shutdownNativeContent()

        let (mobileLayout, mobileHelper) = try fixture(root, mode: "mobile")
        let mobile = manager(mobileLayout, helper: mobileHelper)
        try begin(mobile)
        try await wait("phone method selected") {
            mobile.loginState == .awaitingMobileConfirmation && mobile.nativeContentBroker?.challenge == nil
        }
        try check(!mobile.isNativeContentReady && !mobile.isSignedIn,
                  "accepted phone method only selects polling; it does not authenticate")
        try await Task.sleep(for: .milliseconds(100))
        try check(mobile.loginState == .awaitingMobileConfirmation && !mobile.isNativeContentReady,
                  "phone UI remains awaiting approval until the actual authentication ACK")
        try await wait("phone authentication ACK") { mobile.isNativeContentReady }
        try check(mobile.isNativeContentReady, "phone method becomes connected only after real protocol auth_result")
        await mobile.shutdownNativeContent()

        for mode in ["late", "fail"] {
            let (layout, helper) = try fixture(root, mode: mode)
            let a = manager(layout, helper: helper)
            try begin(a)
            if mode == "late" {
                try await wait("late challenge") { a.loginState == .awaitingGuardCode }
                a.cancelSignIn()
                try check(a.loginState == .cancelled && !a.isNativeContentReady, "cancel immediately clears pending native authentication")
            } else {
                try await wait("native failure") { if case .failed = a.loginState { return true }; return false }
                try check(!a.isNativeContentReady && !a.isSignedIn, "helper auth_failed never becomes connected")
            }
            try await wait("failure or cancel drain") { !a.isNativeContentCleaningUp && a.nativeContentBroker == nil && !a.isUsingNativeSignIn }
            try check(!a.isNativeContentReady && !a.isSignedIn && a.nativeContentBroker == nil,
                      "late cancelled/failing child cannot republish a session after drain")
            // A new generation can authenticate after the old owned child has drained.
            try Data("success".utf8).write(to: helper.deletingLastPathComponent().appendingPathComponent("mode"))
            a.startNativeSignIn()
            if a.loginState == .awaitingUsername { a.submitUsername("fixture_account") }
            a.submitPassword("NATIVE_FIXTURE_PASSWORD")
            try await wait("new native generation") { a.isNativeContentReady }
            try check(a.isNativeContentReady, "fresh attempt succeeds after previous cancelled/failed generation")
            await a.shutdownNativeContent()
            try check(!a.isNativeContentReady && a.nativeContentBroker == nil, "shutdown drains owned native child and detaches session")
            a.startNativeSignIn()
            try check(!a.isUsingNativeSignIn, "shutdown latch prevents late manual restart during termination")
        }
        let (fallbackLayout, fallbackHelper) = try fixture(root, mode: "fail")
        let fallback = manager(fallbackLayout, helper: fallbackHelper)
        try begin(fallback)
        try await wait("fallback native failure") {
            if case .failed = fallback.loginState { return true }; return false
        }
        try await wait("fallback native drain") { fallback.nativeContentBroker == nil && !fallback.isNativeContentCleaningUp && !fallback.isUsingNativeSignIn }
        await fallback.refreshCapability()
        fallback.startLegacySignIn()
        try await wait("explicit compatibility login") { fallback.isSignedIn }
        try check(!fallback.isNativeContentReady && fallback.nativeContentBroker == nil,
                  "installed native helper retains actual explicit SteamCMD fallback after native auth failure")
        await fallback.shutdownNativeContent()

        let (pendingLayout, pendingHelper) = try fixture(root, mode: "late")
        let pending = manager(pendingLayout, helper: pendingHelper)
        try begin(pending)
        try await wait("shutdown pending challenge") { pending.loginState == .awaitingGuardCode }
        await pending.shutdownNativeContent()
        try check(!pending.isNativeContentReady && pending.nativeContentBroker == nil && !pending.isNativeContentCleaningUp,
                  "shutdown during pending authentication drains late success without republishing")
        let restarted = manager(pendingLayout, helper: pendingHelper)
        try check(!restarted.isNativeContentReady && restarted.nativeContentBroker == nil && restarted.rememberedUsername.isEmpty,
                  "new manager never restores native identity or token from disk")
        await restarted.shutdownNativeContent()
        // An installed helper must not replace automatic legacy cache restoration.
        let (legacyLayout, nativeHelper) = try fixture(root, mode: "success")
        try Data("\"users\" { \"0\" { \"AccountName\" \"fixture_account\" } }".utf8).write(to: legacyLayout.loginUsersURL)
        let legacy = manager(legacyLayout, helper: nativeHelper)
        var legacyReadyCallbacks = 0
        legacy.onDownloadSessionReady = { legacyReadyCallbacks += 1 }
        await legacy.refreshCapability()
        try await wait("legacy cached restore") { legacy.isSignedIn }
        try check(!legacy.isNativeContentReady && legacy.nativeContentBroker == nil && legacy.rememberedUsername.isEmpty,
                  "startup still restores legacy cache without transferring cached identity into native authentication")
        try check(legacyReadyCallbacks == 1, "legacy queue callback fires only after finalized login completion")
        let upgrade = WorkshopAccountPresentation(account: legacy)
        try check(upgrade.actionTitle == "查看连接" && !legacy.isNativeContentReady && !upgrade.message.contains("已启用"),
                  "legacy authenticated presentation opens account controls without claiming native progress is enabled")
        legacy.startNativeSignIn()
        try check(legacy.loginState == .awaitingUsername, "legacy connected upgrade opens same inline username flow")
        legacy.cancelSignIn()
        try check(legacy.nativeContentBroker == nil && !legacy.isNativeContentReady && legacy.isSignedIn,
                  "cancelling upgrade preserves the already authenticated legacy connection without touching a download")
        try check(legacyReadyCallbacks == 1, "cancelled upgrade never retriggers queue authentication readiness")
        await legacy.shutdownNativeContent()
        print("RESULT \(checks) native account integration checks passed; actual manager+broker with controlled local child only, no real account/network")
    }
}
