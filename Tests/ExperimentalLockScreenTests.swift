import Foundation

@main struct ExperimentalLockScreenTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func editingRole(_ bytes: Data, role: String, _ edit: ([String: Any]) -> [String: Any]) throws -> Data {
            var root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
            var node = root["SystemDefault"] as! [String: Any]
            node[role] = edit(node[role] as? [String: Any] ?? [:])
            root["SystemDefault"] = node
            return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        }
        let extensionURL = URL(fileURLWithPath: "/Applications/Fixture.app/Contents/PlugIns/GlimmerWallpaperExtension.appex")
        let registration = "+ "+LockScreenStorePatcher.provider+"(1.0)\tUUID\t2026-10-22 00:00:00 +0000\t"+extensionURL.path+"\n"
        check(ExperimentalLockScreenRegistrar.registrationMatches(output: registration, extensionURL: extensionURL), "registration requires expected bundle and current exact path")
        check(!ExperimentalLockScreenRegistrar.registrationMatches(output: registration.replacingOccurrences(of: LockScreenStorePatcher.provider, with: LockScreenStorePatcher.provider+".other"), extensionURL: extensionURL), "registration rejects different bundle suffix")
        check(!ExperimentalLockScreenRegistrar.registrationMatches(output: registration.replacingOccurrences(of: "Fixture.app", with: "Old.app"), extensionURL: extensionURL), "registration rejects stale extension path")
        check(!ExperimentalLockScreenRegistrar.registrationMatches(output: registration.replacingOccurrences(of: ".appex", with: ".appex.backup"), extensionURL: extensionURL), "registration rejects path-prefix matches")
        let otherProvider = registration.replacingOccurrences(of: LockScreenStorePatcher.provider, with: "other.provider")
        let oldRegistration = registration.replacingOccurrences(of: "Fixture.app", with: "Old.app")
        check(!ExperimentalLockScreenRegistrar.registrationMatches(output: oldRegistration + otherProvider, extensionURL: extensionURL), "provider and path must belong to the same record")
        check(!ExperimentalLockScreenRegistrar.registrationMatches(output: oldRegistration + registration, extensionURL: extensionURL), "duplicate inventory cannot prove system selection")
        for marker in ["-", "!", "=", "?"] {
            check(!ExperimentalLockScreenRegistrar.registrationMatches(output: marker + registration.dropFirst(), extensionURL: extensionURL), "disabled or superseded extension is not selected")
        }
        check(ExperimentalLockScreenRegistrar.registeredExtensionURLs(output: oldRegistration + registration + otherProvider).count == 2, "inventory retires only matching provider records")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("gw-lock-screen-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try LockScreenOwnedFiles.makePrivateDirectory(root)
        let store = root.appendingPathComponent("Store")
        try LockScreenOwnedFiles.makePrivateDirectory(store)
        let desktop: [String: Any] = ["OpaqueData": Data([1, 2, 3]), "Content": ["Choices": [["Provider": "other.app.desktop"]]]]
        let node: [String: Any] = ["Type": "individual", "Desktop": desktop,
            "Idle": ["KeepMe": "unknown", "Content": ["Choices": [["Provider": "old.idle"]], "UnknownOption": 42]],
            "Other": ["keep": true]]
        let fixture: [String: Any] = ["SystemDefault": node, "AllSpacesAndDisplays": node,
            "Displays": ["display-a": node], "Spaces": ["space-x": ["Displays": ["display-b": node]]],
            "UnknownRoot": Data([9, 8, 7]), "UnknownObject": ["Desktop": ["foo": "bar"]]]
        let original = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let patched = try LockScreenStorePatcher.patch(original)
        let object = try PropertyListSerialization.propertyList(from: patched, format: nil) as! [String: Any]
        let system = object["SystemDefault"] as! [String: Any]
        let newDesktop = system["Desktop"] as! [String: Any]
        check(newDesktop["OpaqueData"] as? Data == Data([1, 2, 3]), "desktop unknown fields preserved")
        check(system["Type"] as? String == "individual", "individual type remains individual")
        let idle = system["Idle"] as! [String: Any]
        let content = newDesktop["Content"] as! [String: Any]
        let choice = (content["Choices"] as! [[String: Any]])[0]
        check(choice["Provider"] as? String == LockScreenStorePatcher.provider, "correct extension provider")
        check(choice["Configuration"] as? Data == Data("glimmer.native-video".utf8), "exact runtime choice configuration")
        check(NSDictionary(dictionary: idle).isEqual(to: node["Idle"] as! [String: Any]), "screen-saver Idle is completely unchanged")
        check(object["UnknownRoot"] as? Data == Data([9, 8, 7]), "unknown root preserved")
        check(NSDictionary(dictionary: object["UnknownObject"] as! [String: Any]).isEqual(to: ["Desktop": ["foo": "bar"]]), "unrelated unknown dictionary not treated as wallpaper role")
        let spaces = object["Spaces"] as! [String: Any]
        let nested = ((spaces["space-x"] as! [String: Any])["Displays"] as! [String: Any])["display-b"] as! [String: Any]
        check((nested["Desktop"] as? [String: Any])?["LastSet"] is Date, "nested spaces/displays desktop roles patched")
        let shared: [String: Any] = ["KeepMetadata": Data([4, 5]), "Content": ["Choices": [["Provider": "old.shared"]], "OtherContent": true]]
        let linked: [String: Any] = ["Type": "linked", "Linked": shared,
            "Idle": ["StaleUnusedIdle": true], "KeepNode": "keep"]
        let linkedOriginal = try PropertyListSerialization.data(fromPropertyList: ["SystemDefault": linked], format: .binary, options: 0)
        let linkedOutput = try PropertyListSerialization.propertyList(from: LockScreenStorePatcher.patch(linkedOriginal), format: nil) as! [String: Any]
        let linkedNode = linkedOutput["SystemDefault"] as! [String: Any]
        check(linkedNode["Type"] as? String == "individual" && linkedNode["Linked"] == nil, "valid linked role splits into individual desktop and screen-saver surfaces")
        check(NSDictionary(dictionary: linkedNode["Idle"] as! [String: Any]).isEqual(to: shared), "linked effective screen-saver copied completely, stale inactive Idle is not activated")
        let linkedDesktop = linkedNode["Desktop"] as! [String: Any]
        check(linkedDesktop["KeepMetadata"] as? Data == Data([4, 5]) && linkedNode["KeepNode"] as? String == "keep", "linked metadata survives desktop provider change")
        let linkedChoice = ((linkedDesktop["Content"] as! [String: Any])["Choices"] as! [[String: Any]])[0]
        check(linkedChoice["Provider"] as? String == LockScreenStorePatcher.provider, "linked lockscreen actually receives native provider on active Desktop role")
        let roleCases: [String: Any] = ["SystemDefault": node, "Displays": [
            "desktop-only": ["Type": "desktop", "Desktop": desktop],
            "idle-only": ["Type": "idle", "Idle": shared],
            "future-role": ["Type": "future-unknown", "Desktop": desktop, "Keep": true]]]
        let roleData = try PropertyListSerialization.data(fromPropertyList: roleCases, format: .binary, options: 0)
        let roleOutput = try PropertyListSerialization.propertyList(from: LockScreenStorePatcher.patch(roleData), format: nil) as! [String: Any]
        let roleDisplays = roleOutput["Displays"] as! [String: Any]
        let desktopOnly = roleDisplays["desktop-only"] as! [String: Any]
        check(desktopOnly["Type"] as? String == "desktop" && desktopOnly["Idle"] == nil, "desktop-only type preserved without inventing Idle")
        let desktopOnlyChoice = (((desktopOnly["Desktop"] as! [String: Any])["Content"] as! [String: Any])["Choices"] as! [[String: Any]])[0]
        check(desktopOnlyChoice["Provider"] as? String == LockScreenStorePatcher.provider, "desktop-only active role patched")
        let beforeRoleDisplays = roleCases["Displays"] as! [String: Any]
        check(NSDictionary(dictionary: roleDisplays["idle-only"] as! [String: Any]).isEqual(to: beforeRoleDisplays["idle-only"] as! [String: Any]), "screen-saver-only node untouched")
        check(NSDictionary(dictionary: roleDisplays["future-role"] as! [String: Any]).isEqual(to: beforeRoleDisplays["future-role"] as! [String: Any]), "unknown type untouched")
        let idleOnlyData = try PropertyListSerialization.data(fromPropertyList: ["SystemDefault": ["Type": "idle", "Idle": shared]], format: .binary, options: 0)
        do { _ = try LockScreenStorePatcher.patch(idleOnlyData); preconditionFailure("invented desktop for idle-only store") } catch { checks += 1 }
        let linkedStore = root.appendingPathComponent("LinkedStore")
        try LockScreenOwnedFiles.makePrivateDirectory(linkedStore)
        try linkedOriginal.write(to: linkedStore.appendingPathComponent("Index.plist"))
        let linkedTransaction = LockScreenStoreTransaction(storeDirectory: linkedStore, snapshotURL: root.appendingPathComponent("linked-snapshot.json"))
        let linkedSnapshot = try linkedTransaction.apply(configuration: Data("linked-config".utf8), previousConfiguration: nil, assetID: UUID())
        try linkedTransaction.restore(linkedSnapshot)
        let linkedRestored = try Data(contentsOf: linkedStore.appendingPathComponent("Index.plist"))
        check(linkedRestored == linkedOriginal, "snapshot restores exact original Linked/Type/stale Idle structure")
        for name in ["Index.plist", "Index2.plist"] { try original.write(to: store.appendingPathComponent(name)) }
        let snapshotURL = root.appendingPathComponent("snapshot.json")
        let transaction = LockScreenStoreTransaction(storeDirectory: store, snapshotURL: snapshotURL)
        let config = Data("config".utf8)
        let snapshot = try transaction.apply(configuration: config, previousConfiguration: nil, assetID: UUID())
        try transaction.restore(snapshot)
        for name in ["Index.plist", "Index2.plist"] {
            let restored = try Data(contentsOf: store.appendingPathComponent(name))
            check(restored == original, "roundtrip restores exact original bytes \(name)")
        }
        enum Injected: Error { case failure }
        var writes = 0
        let savedSnapshotBeforeFailure = try Data(contentsOf: snapshotURL)
        let failing = LockScreenStoreTransaction(storeDirectory: store, snapshotURL: snapshotURL, write: { data, url in
            writes += 1
            if writes == 2 { throw Injected.failure }
            try data.write(to: url, options: .atomic)
        })
        do { _ = try failing.apply(configuration: config, previousConfiguration: nil, assetID: UUID()); preconditionFailure("missing failure") }
        catch { checks += 1 }
        let savedSnapshotAfterFailure = try Data(contentsOf: snapshotURL)
        check(savedSnapshotBeforeFailure == savedSnapshotAfterFailure, "failed apply preserves previous successful restore snapshot")
        let historyURL = root.appendingPathComponent("history/\(snapshot.id.uuidString).json")
        let archived = try Data(contentsOf: historyURL)
        check(archived == savedSnapshotBeforeFailure, "next apply archives exact previous successful snapshot")
        check(try JSONDecoder().decode(LockScreenStoreSnapshot.self, from: archived).originalFiles["Index.plist"] == original, "earliest original system provider snapshot survives later applies")
        let historyAttributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        check((historyAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history snapshot private mode600")
        for name in ["Index.plist", "Index2.plist"] {
            let current = try Data(contentsOf: store.appendingPathComponent(name))
            check(current == original, "failed multi-file apply rolls back \(name)")
        }
        let applied = try transaction.apply(configuration: config, previousConfiguration: nil, assetID: UUID())
        let activeBytes = applied.appliedFiles["Index.plist"]!
        var timestampOnly = try editingRole(activeBytes, role: "Desktop") { role in
            var role = role; role["LastUse"] = Date(timeIntervalSince1970: 9_000); role["LastSet"] = Date(timeIntervalSince1970: 8_000); return role
        }
        timestampOnly = try editingRole(timestampOnly, role: "Idle") { role in
            var role = role; role["LastUse"] = Date(timeIntervalSince1970: 7_000); role["LastSet"] = Date(timeIntervalSince1970: 6_000); return role
        }
        check(LockScreenStorePatcher.semanticallyEqual(activeBytes, timestampOnly), "known Desktop/Idle timestamp-only edits are semantically equal")
        let linkedTimestamp = try editingRole(linkedOriginal, role: "Linked") { role in
            var role = role; role["LastUse"] = Date(); role["LastSet"] = Date(); return role
        }
        check(LockScreenStorePatcher.semanticallyEqual(linkedOriginal, linkedTimestamp), "known Linked timestamps are ignored")
        for name in ["Index.plist", "Index2.plist"] { try timestampOnly.write(to: store.appendingPathComponent(name)) }
        try transaction.restore(applied)
        for name in ["Index.plist", "Index2.plist"] {
            let restoredBytes = try Data(contentsOf: store.appendingPathComponent(name))
            check(restoredBytes == original, "restore accepts timestamps-only changes immediately before write \(name)")
            try applied.appliedFiles[name]!.write(to: store.appendingPathComponent(name))
        }
        for field in ["Provider", "Configuration", "UnknownField"] {
            let changed = try editingRole(timestampOnly, role: "Desktop") { role in
                var role = role
                if field == "UnknownField" { role["UnknownField"] = "new-value"; return role }
                var content = role["Content"] as! [String: Any]
                var choices = content["Choices"] as! [[String: Any]]
                choices[0][field] = field == "Provider" ? "com.apple.wallpaper.extension.image" : Data("different-asset".utf8)
                content["Choices"] = choices; role["Content"] = content; return role
            }
            check(!LockScreenStorePatcher.semanticallyEqual(activeBytes, changed), "timestamps cannot hide \(field) change")
            try changed.write(to: store.appendingPathComponent("Index.plist"))
            do { try transaction.restore(applied); preconditionFailure("changed field accepted") } catch { checks += 1 }
            let preservedField = try Data(contentsOf: store.appendingPathComponent("Index.plist"))
            check(preservedField == changed, "restore preserves changed \(field) including system fallback")
        }
        var changedType = try PropertyListSerialization.propertyList(from: timestampOnly, format: nil) as! [String: Any]
        var changedNode = changedType["SystemDefault"] as! [String: Any]
        changedNode["Type"] = "desktop"; changedType["SystemDefault"] = changedNode
        let changedTypeData = try PropertyListSerialization.data(fromPropertyList: changedType, format: .binary, options: 0)
        check(!LockScreenStorePatcher.semanticallyEqual(activeBytes, changedTypeData), "node Type changes remain significant")
        var unknownTimestamp = try PropertyListSerialization.propertyList(from: activeBytes, format: nil) as! [String: Any]
        unknownTimestamp["LastUse"] = Date()
        let unknownTimestampData = try PropertyListSerialization.data(fromPropertyList: unknownTimestamp, format: .binary, options: 0)
        check(!LockScreenStorePatcher.semanticallyEqual(activeBytes, unknownTimestampData), "timestamps outside known role dictionaries remain significant")
        try activeBytes.write(to: store.appendingPathComponent("Index.plist"))
        let external = Data("new-user-choice".utf8)
        try external.write(to: store.appendingPathComponent("Index.plist"))
        do { try transaction.restore(applied); preconditionFailure("external choice overwritten") } catch { checks += 1 }
        let preserved = try Data(contentsOf: store.appendingPathComponent("Index.plist"))
        check(preserved == external, "external system selection survives restore attempt")
        // Restore fault injection must return already-restored files to the prior applied state.
        try applied.appliedFiles["Index.plist"]!.write(to: store.appendingPathComponent("Index.plist"))
        writes = 0
        do { try failing.restore(applied); preconditionFailure("missing restore failure") } catch { checks += 1 }
        for name in ["Index.plist", "Index2.plist"] {
            let current = try Data(contentsOf: store.appendingPathComponent(name))
            check(current == applied.appliedFiles[name], "failed restore rolls back \(name)")
        }
        try original.write(to: store.appendingPathComponent("Index2.plist"))
        try transaction.restore(applied, allowOriginal: true)
        let recovered = try Data(contentsOf: store.appendingPathComponent("Index.plist"))
        check(recovered == original, "partial interrupted transaction can recover without changing already-original file")
        let appStorage = AppStorage(root: root.appendingPathComponent("App"))
        try appStorage.prepareDirectories()
        let input = appStorage.mediaDirectory.appendingPathComponent("input.mp4")
        try await SyntheticVideoWriter.write(to: input)
        let sourceBefore = try Data(contentsOf: input)
        let coordinator = ExperimentalLockScreenCoordinator.review(storage: appStorage)
        let item = WallpaperItem(title: "Fixture", filePath: input.path)
        await coordinator.prepare(item: item)
        check(coordinator.state == .prepared && coordinator.preparedAsset != nil, "prepare creates validated movie and poster")
        check(coordinator.preparedAsset!.codec.contains("avc1") && coordinator.preparedAsset!.durationSeconds > 0, "real codec and duration validated")
        let environment = ExperimentalLockScreenEnvironment.review(storage: appStorage)
        check(!FileManager.default.fileExists(atPath: environment.storeDirectory.path), "prepare does not touch even review system store")
        let sourceAfter = try Data(contentsOf: input)
        check(sourceBefore == sourceAfter, "original library video bytes preserved")
        let assetAttributes = try FileManager.default.attributesOfItem(atPath: coordinator.preparedAsset!.videoURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: coordinator.preparedAsset!.videoURL.deletingLastPathComponent().path)
        check((assetAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "prepared video private mode600")
        check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "prepared asset directory private mode700")
        let alternate = appStorage.mediaDirectory.appendingPathComponent("requires-export.mov")
        try sourceBefore.write(to: alternate)
        let converted = ExperimentalLockScreenCoordinator.review(storage: AppStorage(root: root.appendingPathComponent("Convert")))
        await converted.prepare(item: WallpaperItem(title: "Export", filePath: alternate.path))
        check(converted.state == .prepared && converted.preparedAsset!.videoURL.pathExtension == "mp4", "real async export path produces validated MP4")
        await coordinator.applyPrepared()
        check(coordinator.state == .applied && coordinator.canRestorePrevious, "review applies only its fixture store")
        let sharedVideo = environment.sharedDirectory.appendingPathComponent("\(coordinator.preparedAsset!.id.uuidString).mp4")
        let sharedAttributes = try FileManager.default.attributesOfItem(atPath: sharedVideo.path)
        check((sharedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "staged extension video remains private mode600")
        check(coordinator.statusText == "配置已提交，尚未验证锁屏可见", "submitted never claims real lockscreen visibility")
        let restoredCoordinator = ExperimentalLockScreenCoordinator.review(storage: appStorage)
        check(restoredCoordinator.state == .applied, "restart reads durable status without reapplying")
        let backendRoot = appStorage.root.appendingPathComponent("ExperimentalLockScreen")
        let pending = backendRoot.appendingPathComponent("pending-interrupted-fixture.json")
        try Data(contentsOf: backendRoot.appendingPathComponent("previous-settings.json")).write(to: pending)
        let recoveryCoordinator = ExperimentalLockScreenCoordinator.review(storage: appStorage)
        check(recoveryCoordinator.state == .failed && recoveryCoordinator.canRestorePrevious, "restart detects pending recovery but does not reapply")
        await recoveryCoordinator.restorePrevious()
        check(recoveryCoordinator.state == .restored && !FileManager.default.fileExists(atPath: pending.path), "fixture coordinator restores interrupted transaction and removes pending marker")
        let configURL = environment.sharedDirectory.appendingPathComponent("config.json")
        check(!FileManager.default.fileExists(atPath: configURL.path), "restore removes config only when none existed before")
        await coordinator.applyPrepared()
        let changedStore = environment.storeDirectory.appendingPathComponent("Index.plist")
        let configBeforeConflict = try Data(contentsOf: configURL)
        try external.write(to: changedStore)
        await coordinator.restorePrevious()
        check(coordinator.state == .failed, "coordinator refuses external system selection")
        let storeAfterConflict = try Data(contentsOf: changedStore)
        let configAfterConflict = try Data(contentsOf: configURL)
        check(storeAfterConflict == external && configAfterConflict == configBeforeConflict, "conflict preserves both new store and current extension configuration")
        await coordinator.applyPrepared()
        let configAfterFailedApply = try Data(contentsOf: configURL)
        check(coordinator.state == .failed && configAfterFailedApply == configBeforeConflict, "failed apply rolls back extension configuration")
        let invalid = ExperimentalLockScreenCoordinator.review(storage: AppStorage(root: root.appendingPathComponent("Invalid")))
        await invalid.prepare(item: WallpaperItem(title: "Missing", filePath: root.appendingPathComponent("missing.mp4").path))
        check(invalid.state == .failed && invalid.preparedAsset == nil, "unplayable source rejected without system changes")
        let warningStorage = AppStorage(root: root.appendingPathComponent("ReloadWarning"))
        var warningEnvironment = ExperimentalLockScreenEnvironment.review(storage: warningStorage)
        warningEnvironment.reviewReloadFailureMessage = "fixture reload failure"
        let warningCoordinator = ExperimentalLockScreenCoordinator(storage: warningStorage, environment: warningEnvironment)
        await warningCoordinator.prepare(item: item)
        await warningCoordinator.applyPrepared()
        check(warningCoordinator.state == .applied && warningCoordinator.lastError != nil, "reload failure preserves applied state and reports warning")
        let warningConfigURL = warningEnvironment.sharedDirectory.appendingPathComponent("config.json")
        check(FileManager.default.fileExists(atPath: warningConfigURL.path), "reload failure does not roll back only configuration after store commit")
        let warningRestart = ExperimentalLockScreenCoordinator(storage: warningStorage, environment: warningEnvironment)
        check(warningRestart.state == .applied && warningRestart.lastError != nil, "reload warning survives restart without automatic retry")
        await warningRestart.restorePrevious()
        check(warningRestart.state == .restored && warningRestart.lastError != nil, "restore reload failure preserves restored state")
        check(!FileManager.default.fileExists(atPath: warningConfigURL.path), "restore reload failure leaves restored config consistent")
        print("ExperimentalLockScreenTests: \(checks) checks passed; temp-only fixtures, generated video; no real pluginkit/system store/WallpaperAgent actions")
    }
}
