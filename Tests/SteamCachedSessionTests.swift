import Foundation

/// All profile contents and console input here are invented fixture values.
/// The child is a local scripted executor, never SteamCMD or a network login.
@main @MainActor enum SteamCachedSessionTests {
    static let fm=FileManager.default
    static var checks=0
    static func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(message:name)};checks += 1;print("PASS \(name)");fflush(stdout)}
    struct Failure:Error {let message:String}
    static func wait(_ name:String,_ condition:@MainActor ()->Bool)async throws {for _ in 0..<500 {if condition(){return};try await Task.sleep(for:.milliseconds(10))};throw Failure(message:"Timeout: "+name)}
    nonisolated static func ready(_ layout:SteamCMDLayout)->SteamCMDReport {.init(status:.ready(version:"fixture"),executablePath:layout.executableURL.path,architecture:.arm64,rosetta:.notRequired,hostArchitecture:"fixture",binaryExists:true,evidence:[])}
    static func fixture(_ root:URL,mode:String,cache:Bool=true)throws->SteamCMDLayout {
        let layout=SteamCMDLayout(root:root.appendingPathComponent(UUID().uuidString))
        try fm.createDirectory(at:layout.homeURL.appendingPathComponent("config"),withIntermediateDirectories:true)
        if cache {try writeCache(layout)}
        try Data(mode.utf8).write(to:layout.root.appendingPathComponent("mode"))
        let script = #"""
        #!/bin/sh
        cd "$(dirname "$0")" || exit 91
        printf 'x' >> process-starts
        # Record only whether a login command was sent, never its contents.
        printf 'Steam Console Client\nSteam>\n'
        step=login
        while IFS= read -r line; do
          if [ "$line" = quit ]; then
            : > quit-seen
            mode=$(cat mode)
            if [ "$mode" = held ]; then
              while [ ! -f release ]; do /bin/sleep 0.02; done
            fi
            if [ "$mode" = late-failure ]; then
              printf 'Waiting for user info...FAILED\n'
              /bin/sleep 0.1
              exit 1
            fi
            : > exited
            exit 0
          fi
          case "$line" in
            'login fixture_account')
              printf 'x' >> login-commands
              mode=$(cat mode)
              case "$mode" in
                expired) printf 'FAILED login with cached credentials\n'; /bin/sleep 0.1; exit 1;;
                no-ack) exit 0;;
                password) printf 'Password:\n';step=password;continue;;
                guard) printf 'Steam Guard code:\n';step=guard;continue;;
                mobile) printf 'Waiting for mobile confirmation\n'; /bin/sleep 0.3;;
              esac
              ;;
            fixture_secret) [ "$step" = password ] || exit 92;;
            ABC12) [ "$step" = guard ] || exit 93;;
            *) exit 94;;
          esac
          printf "Logging in user 'fixture_account'...OK\nWaiting for user info...OK\n"
        done
        """#
        try Data(script.utf8).write(to:layout.executableURL)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:layout.executableURL.path)
        return layout
    }
    static func writeCache(_ layout:SteamCMDLayout)throws {try Data("\"users\" { \"0\" { \"AccountName\" \"fixture_account\" } }".utf8).write(to:layout.loginUsersURL)}
    static func count(_ layout:SteamCMDLayout,_ file:String)->Int {(try? Data(contentsOf:layout.root.appendingPathComponent(file)).count) ?? 0}
    static func manager(_ layout:SteamCMDLayout)->SteamAccountManager {
        SteamAccountManager(layout:layout,capabilityOperation:{ready($0)},makeLoginSession:{SteamLoginSession(executable:$0,layout:$1,commandTimeout:3,settleGrace:0.1,shutdownTimeout:2)})
    }
    static func freeGate(_ layout:SteamCMDLayout)async throws {for _ in 0..<300 {if !(await SteamProfileGateRegistry.gate(for:layout).isBusy){return};try await Task.sleep(for:.milliseconds(10))};throw Failure(message:"Profile gate retained")}
    static func run(_ root:URL)async throws {
        let layout=try fixture(root,mode:"held"),account=manager(layout)
        try check(account.hasCachedSession && !account.isSignedIn && account.loginState == .idle,"cache existence alone never marks connected")
        await account.refreshCapability()
        try await wait("cached login reaches finalization"){account.loginState == .finalizing && fm.fileExists(atPath:layout.root.appendingPathComponent("quit-seen").path)}
        try check(!account.isSignedIn && account.lastSignedInAt == nil && count(layout,"login-commands")==1,"startup sends one cached login but awaits real completion instead of file-based success")
        try check(account.rememberedUsername.isEmpty,"cached account name is not copied to observable username or form state")
        try Data().write(to:layout.root.appendingPathComponent("release"))
        try await wait("normal ACK and exit"){account.isSignedIn}
        try check(fm.fileExists(atPath:layout.root.appendingPathComponent("exited").path) && account.lastSignedInAt != nil && account.loginStatus.state == account.loginState,"accepted login becomes connected only after executor ACK and graceful exit")
        try check(!account.loginStatus.recentLines.joined().contains("fixture_account"),"account console lines are sanitized before presentation")
        let record=try JSONSerialization.jsonObject(with:Data(contentsOf:layout.homeURL.appendingPathComponent("account-session.json"))) as! [String:Any]
        try check(Set(record.keys)==["schemaVersion","lastSignedInAt"],"application session record persists only schema and timestamp")
        await account.refreshCapability();await account.refreshCapability()
        try check(count(layout,"process-starts")==1,"repeated capability checks never repeatedly authenticate connected cache")
        try Data("success".utf8).write(to:layout.root.appendingPathComponent("mode"))
        let restarted=manager(layout)
        try check(restarted.lastSignedInAt != nil && !restarted.isSignedIn,"restart timestamp does not restore a fabricated connected state")
        await restarted.refreshCapability();try await wait("restart ACK"){restarted.isSignedIn}
        try check(count(layout,"process-starts")==2,"fresh manager actually validates cached login again after restart")
        try await freeGate(layout)

        let missing=try fixture(root,mode:"success",cache:false),empty=manager(missing)
        await empty.refreshCapability()
        try check(!empty.hasCachedSession && empty.loginState == .idle && count(missing,"process-starts")==0,"no cache causes no automatic login or prompt")
        try Data().write(to:missing.homeURL.appendingPathComponent("ssfn_fixture"));empty.refreshCachedSessionState();await empty.refreshCapability()
        try check(empty.hasCachedSession && !empty.isSignedIn && count(missing,"process-starts")==0,"credential evidence without a reusable cached account is not mistaken for a connected session")
        let blocked=try fixture(root,mode:"success")
        let unavailable=SteamAccountManager(layout:blocked,capabilityOperation:{var report=ready($0);report.status = .notInstalled;return report})
        await unavailable.refreshCapability()
        try check(!unavailable.isReady && !unavailable.isSignedIn && count(blocked,"process-starts")==0,"not-ready capability never launches cached authentication")

        for mode in ["expired","no-ack","late-failure"] {
            let l=try fixture(root,mode:mode),a=manager(l)
            await a.refreshCapability();try await wait("failure "+mode){if case .failed=a.loginState{return true};return false}
            try check(!a.isSignedIn && a.lastSignedInAt == nil,"\(mode) cannot publish a connected cache")
            await a.refreshCapability()
            try check(count(l,"process-starts")==1,"\(mode) does not trigger an automatic retry loop")
            if mode=="expired" {
                a.startSignIn();try await wait("manual username after expired cache"){a.loginState == .awaitingUsername}
                try check(count(l,"login-commands")==1,"explicit retry after invalid cache returns to manual username instead of replaying broken cache")
                a.cancelSignIn();try await freeGate(l)
            }
        }
        for mode in ["password","guard"] {
            let l=try fixture(root,mode:mode),a=manager(l)
            await a.refreshCapability()
            let prompt:SteamLoginState=mode=="password" ? .awaitingPassword:.awaitingGuardCode
            try await wait("manual prompt "+mode){a.loginState==prompt}
            try check(!a.isSignedIn && a.rememberedUsername.isEmpty,"cached \(mode) prompt remains manual and unconnected without exposing account name")
            if mode=="password" {a.submitPassword("fixture_secret")}else{a.submitGuardCode("ABC12")}
            try await wait("prompt complete "+mode){a.isSignedIn}
            try check(a.loginStatus.state==a.loginState && count(l,"process-starts")==1,"\(mode) input continues the existing official session rather than launching duplicate authentication")
            try check(!a.loginStatus.recentLines.joined().contains("fixture_secret") && !a.loginStatus.recentLines.joined().contains("ABC12"),"\(mode) input does not appear in state output")
        }
        let mobileLayout=try fixture(root,mode:"mobile"),mobile=manager(mobileLayout)
        await mobile.refreshCapability();try await wait("mobile confirmation"){mobile.loginState == .awaitingMobileConfirmation}
        try check(!mobile.isSignedIn,"cached mobile confirmation is not reported as connected before approval")
        try await wait("mobile ACK"){mobile.isSignedIn}

        let gated=try fixture(root,mode:"success",cache:false),gatedAccount=manager(gated)
        await gatedAccount.refreshCapability();try writeCache(gated);gatedAccount.refreshCachedSessionState()
        let gate=SteamProfileGateRegistry.gate(for:gated)
        try check(await gate.acquire(owner:"controlled download"),"controlled profile lock acquired")
        gatedAccount.startSignIn();try await Task.sleep(for:.milliseconds(80))
        try check(gatedAccount.loginState == .preparing && count(gated,"process-starts")==0,"cached login waits for existing download profile lock before starting process")
        gatedAccount.cancelSignIn();await gate.release();try await freeGate(gated);try await Task.sleep(for:.milliseconds(80))
        try check(gatedAccount.loginState == .cancelled && count(gated,"process-starts")==0,"cancelling queued login never spawns a late process after profile unlock")
        gatedAccount.startSignIn();try await wait("new login after queued cancel"){gatedAccount.isSignedIn}
        try check(count(gated,"process-starts")==1,"stale cancelled completion cannot overwrite subsequent successful login")

        let cancelLayout=try fixture(root,mode:"held"),cancelled=manager(cancelLayout)
        await cancelled.refreshCapability();try await wait("cancel finalization"){cancelled.loginState == .finalizing}
        cancelled.cancelSignIn();try Data().write(to:cancelLayout.root.appendingPathComponent("release"));try await freeGate(cancelLayout);try await Task.sleep(for:.milliseconds(100))
        try check(cancelled.loginState == .cancelled && !cancelled.isSignedIn && cancelled.lastSignedInAt == nil,"cancel during graceful finalization cannot resurrect connected state")

        let outLayout=try fixture(root,mode:"password"),signedOut=manager(outLayout)
        await signedOut.refreshCapability();try await wait("signout prompt"){signedOut.loginState == .awaitingPassword}
        signedOut.signOut();try await wait("cache cleared"){!signedOut.hasCachedSession};try await freeGate(outLayout)
        try writeCache(outLayout);await signedOut.refreshCapability();try await Task.sleep(for:.milliseconds(80))
        try check(signedOut.loginState == .idle && !signedOut.isSignedIn && count(outLayout,"process-starts")==1,"explicit signout blocks automatic reconnection even if cache evidence appears again")
        let mac = try fixture(root, mode: "success", cache: false)
        let macDirectory = mac.loginCacheDirectories[1]
        try fm.createDirectory(at: macDirectory, withIntermediateDirectories: true)
        let macConfig = macDirectory.appendingPathComponent("config.vdf")
        let macVDF = "\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"Accounts\" { \"fixture_account\" { \"SteamID\" \"invented\" \"Token\" \"invented-secret\" } } } } } }"
        try Data(macVDF.utf8).write(to: macConfig)
        let macAccount = manager(mac)
        try check(macAccount.hasCachedSession && !macAccount.isSignedIn && WorkshopDownloadService.cachedAccountName(layout: mac) == "fixture_account", "macOS isolated HOME config Accounts key is a reusable candidate, never an authenticated session")
        await macAccount.refreshCapability(); try await wait("macOS cache ACK") { macAccount.isSignedIn }
        try check(count(mac, "login-commands") == 1 && macAccount.rememberedUsername.isEmpty, "macOS cached name is temporary stdin only and requires real executor ACK")
        try check(SteamCachedLoginProfile.parse("\"Other\" { \"Accounts\" { \"fixture_account\" {} } \"AccountName\" \"fixture_account\" }") == nil, "unrelated Accounts and AccountName nodes cannot invent a cached identity")
        try check(SteamCachedLoginProfile.parse(macVDF.dropLast().description) == nil, "truncated config fails closed despite an earlier account key")
        try check(SteamCachedLoginProfile.parse("// comment\n" + macVDF.lowercased()) == "fixture_account", "VDF comments and case-insensitive known structural keys are supported")
        try check(SteamCachedLoginProfile.parse(String(repeating: "x", count: 2 * 1024 * 1024 + 1)) == nil, "oversized cache parsing is bounded")
        let outside = root.appendingPathComponent("outside-config.vdf")
        try Data(macVDF.utf8).write(to: outside)
        try fm.removeItem(at: macConfig); try fm.createSymbolicLink(at: macConfig, withDestinationURL: outside)
        try check(WorkshopDownloadService.cachedAccountName(layout: mac) == nil, "leaf symlink outside isolated HOME cannot supply cached identity")
        try fm.removeItem(at: macConfig); try fm.removeItem(at: macDirectory)
        let externalDirectory = root.appendingPathComponent("external-config")
        try fm.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalConfig = externalDirectory.appendingPathComponent("config.vdf")
        try Data(macVDF.utf8).write(to: externalConfig)
        try fm.createSymbolicLink(at: macDirectory, withDestinationURL: externalDirectory)
        try check(WorkshopDownloadService.cachedAccountName(layout: mac) == nil, "parent-directory symlink escape cannot supply cached identity")
        macAccount.signOut(); try await wait("symlink signout") { macAccount.loginState == .idle }; try await freeGate(mac)
        try check(fm.fileExists(atPath: externalConfig.path), "explicit signout never removes external symlink targets")
        try fm.removeItem(at: macDirectory); try fm.createDirectory(at: macDirectory, withIntermediateDirectories: true)
        try Data(macVDF.utf8).write(to: macConfig)
        try writeCache(mac)
        try Data(macVDF.utf8).write(to: mac.homeURL.appendingPathComponent("config/config.vdf"))
        try Data("\"users\" {}".utf8).write(to: macDirectory.appendingPathComponent("loginusers.vdf"))
        let preserved = macDirectory.appendingPathComponent("unrelated.vdf")
        try Data("preserve".utf8).write(to: preserved)
        macAccount.refreshCachedSessionState(); macAccount.signOut()
        try await wait("all official cache paths cleared") { !macAccount.hasCachedSession }; try await freeGate(mac)
        try check(mac.loginCacheFiles.allSatisfy { !fm.fileExists(atPath: $0.path) } && fm.fileExists(atPath: preserved.path) && fm.fileExists(atPath: outside.path), "explicit signout clears both official app-owned layouts but preserves unrelated and external files")
        print("RESULT \(checks) isolated cached-session state checks passed; controlled local executor only, no real Steam authentication/network/cache mutations")
    }
    static func main()async throws {
        if CommandLine.arguments.contains("--probe-app-cache") {
            // Deliberately no manager/session construction and no identity output.
            let candidate = WorkshopDownloadService.cachedAccountName(layout: SteamCMDLayout()) != nil
            print("READ_ONLY_APP_PROFILE reusableCandidate=\(candidate); no login/cache mutation")
        }
        let root=fm.temporaryDirectory.appendingPathComponent("GW-Cached-Session-\(UUID())");try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)};try await run(root)}
}
