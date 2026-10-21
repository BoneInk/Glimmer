import Foundation

@MainActor private final class ResourceHostFixture {
    let assets: AuthorPropertyAssetStore
    let overrides: AuthorPropertyOverrideStore
    var calls: [AuthorPropertyResourceRequest] = []
    var failAcknowledgement = false
    var holdItem: UUID?
    var gate: CheckedContinuation<Void, Never>?
    init(assets: AuthorPropertyAssetStore, overrides: AuthorPropertyOverrideStore) {
        self.assets = assets; self.overrides = overrides
    }
    // Test adapter for the UI transaction contract; production service/runtime tests are separate.
    func perform(_ request: AuthorPropertyResourceRequest) async throws {
        calls.append(request)
        if holdItem == request.itemID { holdItem = nil; await withCheckedContinuation { gate = $0 } }
        let key = request.definition.key
        let checkpoint = try await assets.checkpoint(itemID: request.itemID, propertyKey: key)
        var replacement: String?
        var persisted = false
        do {
            var value: GWJSONValue?
            switch request.operation {
            case .select(let url):
                let grant = try await request.definition.kind == .file
                    ? assets.selectFile(url, itemID: request.itemID, propertyKey: key, project: request.project)
                    : assets.selectDirectory(url, itemID: request.itemID, propertyKey: key, project: request.project)
                replacement = grant.revision; value = grant.value
            case .refresh:
                let grant = try await assets.refresh(itemID: request.itemID, propertyKey: key, project: request.project)
                replacement = grant.revision; value = grant.value
            case .clear:
                try await assets.revoke(itemID: request.itemID, propertyKey: key); value = .string("")
            case .reset:
                try await assets.revoke(itemID: request.itemID, propertyKey: key); value = nil
            case .retry:
                persisted = true
            }
            if case .retry = request.operation {} else {
                try await overrides.set(value, for: key, itemID: request.itemID, project: request.project)
                persisted = true
            }
            let manifest = try await assets.manifest(itemID: request.itemID)
            for asset in manifest.assets { _ = try Data(contentsOf: asset.url) }
            if failAcknowledgement { throw AuthorPropertyAssetError(message: "host ACK rejected") }
        } catch {
            if !persisted { try await assets.restore(checkpoint, replacingRevision: replacement) }
            throw AuthorPropertyResourceFailure(persisted: persisted, message: error.localizedDescription)
        }
    }
}

@main struct AuthorPropertyResourceSettingsTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GWResourceUI-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = root.appendingPathComponent("chosen.png")
        let secondImage = root.appendingPathComponent("second.png")
        try Data([1, 2, 3]).write(to: image); try Data([4, 5, 6]).write(to: secondImage)
        let folder = root.appendingPathComponent("photos")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([7, 8]).write(to: folder.appendingPathComponent("inside.png"))
        let project = try AuthorPropertyProject.parse(data: Data(#"{"type":"web","general":{"properties":{"picture":{"type":"file","fileType":"image","value":""},"photos":{"type":"directory","fileType":"image","mode":"ondemand","value":""},"enabled":{"type":"bool","value":true}}}}"#.utf8), projectURL: root.appendingPathComponent("project.json"))
        let picture = project.definition(for: "picture")!
        let photos = project.definition(for: "photos")!
        let overridesDirectory = root.appendingPathComponent("overrides")
        let overrides = AuthorPropertyOverrideStore(directory: overridesDirectory)
        let assets = AuthorPropertyAssetStore(directory: root.appendingPathComponent("assets"))
        let host = ResourceHostFixture(assets: assets, overrides: overrides)
        let actions = AuthorPropertyResourceActions { try await host.perform($0) }
        let caps = AuthorPropertyEditingCapabilities(editableKeys: ["picture", "photos", "enabled"], runtimeLabel: "fixture", unsupportedReason: "不可编辑")
        let itemA = UUID(), itemB = UUID()
        var scalarCalls = 0
        let session = AuthorPropertySettingsSession(project: project, overrideStore: overrides, itemID: itemA,
            capabilities: caps, resourceActions: actions, coalescingDelay: .zero) { _ in scalarCalls += 1 }
        await session.load()
        check(host.calls.isEmpty && scalarCalls == 0, "opening never authorizes or applies")
        session.set(.string(image.path), for: picture)
        await session.waitUntilIdle()
        check(host.calls.isEmpty && !session.isSaving, "absolute path cannot enter scalar setter")
        session.performResource(.select(image), for: picture)
        await session.waitUntilIdle()
        let firstValue = session.values["picture"]!
        check(firstValue.stringValue?.hasPrefix("__gw_assets__/") == true && firstValue != .string(image.path), "only virtual value is persisted")
        check(scalarCalls == 0 && !session.savedButNotApplied, "resource action does not duplicate scalar callback")
        let firstGrant = try await assets.grants(itemID: itemA).first!
        check(try Data(contentsOf: firstGrant.assets[0].url) == Data([1, 2, 3]), "real managed resource copy readable")
        let document = overridesDirectory.appendingPathComponent(itemA.uuidString + ".json")
        let documentBytes = try Data(contentsOf: document)
        try fm.removeItem(at: document); try fm.createDirectory(at: document, withIntermediateDirectories: false)
        session.performResource(.select(secondImage), for: picture)
        await session.waitUntilIdle()
        let rolledBack = try await assets.grants(itemID: itemA).first!
        check(rolledBack.value == firstValue && session.values["picture"] == firstValue, "persistence failure retains old grant and UI value")
        check(session.canRetry && !session.savedButNotApplied, "persistence failure is retryable without false applied state")
        try fm.removeItem(at: document); try documentBytes.write(to: document)
        session.retry(); await session.waitUntilIdle()
        check(session.values["picture"] != firstValue && session.errorText == nil, "persistence retry obtains usable replacement")
        host.failAcknowledgement = true
        session.performResource(.select(image), for: picture)
        await session.waitUntilIdle()
        let rejectedValue = session.values["picture"]
        let rejectedGrant = try await assets.grants(itemID: itemA).first!
        check(session.savedButNotApplied && rejectedGrant.value == rejectedValue, "ACK failure retains saved grant and override")
        host.failAcknowledgement = false
        session.retry(); await session.waitUntilIdle()
        if case .retry = host.calls.last!.operation {} else { preconditionFailure("retry selected resource again") }
        check(session.values["picture"] == rejectedValue && session.errorText == nil, "ACK retry does not reselect or replace grant")
        session.performResource(.clear, for: picture); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).isEmpty, "clear revokes native grant")
        check(session.values["picture"] == .string("") && scalarCalls == 0, "clear persists empty virtual selection via resource transaction")
        session.performResource(.select(folder), for: photos); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).first?.assetCount == 1, "directory selection copies permitted resources")
        try Data([9]).write(to: folder.appendingPathComponent("added.png"))
        session.performResource(.refresh, for: photos); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).first?.assetCount == 2, "directory refresh updates actual grant")
        session.reset(photos); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).isEmpty, "per-item reset revokes resources")
        check(try await overrides.load(itemID: itemA)["photos"] == nil, "reset removes override rather than absolute path fallback")
        let other = AuthorPropertySettingsSession(project: project, overrideStore: overrides, itemID: itemB,
            capabilities: caps, resourceActions: actions, coalescingDelay: .zero) { _ in scalarCalls += 1 }
        await other.load()
        host.holdItem = itemA
        session.performResource(.select(image), for: picture)
        while host.gate == nil { await Task.yield() }
        let callsBefore = host.calls.count
        session.performResource(.select(secondImage), for: picture)
        session.set(.bool(false), for: project.definition(for: "enabled")!)
        check(host.calls.count == callsBefore && session.isResourceBusy, "busy resource transaction prevents conflicting edits")
        other.performResource(.select(secondImage), for: picture); await other.waitUntilIdle()
        host.gate?.resume(); host.gate = nil
        await session.waitUntilIdle()
        check(session.values["picture"] != other.values["picture"], "late item A completion cannot overwrite item B")
        check(try await overrides.load(itemID: itemB)["picture"] == other.values["picture"], "other item persisted selection remains independent")
        session.resetEditable(); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).isEmpty, "all reset uses resource revocation transaction")
        check(try await assets.grants(itemID: itemB).count == 1, "all reset never revokes another item")
        session.performResource(.select(image), for: picture); await session.waitUntilIdle()
        let grantBeforeClear = try await assets.grants(itemID: itemA).first!
        let bytesBeforeClear = try Data(contentsOf: document)
        try fm.removeItem(at: document); try fm.createDirectory(at: document, withIntermediateDirectories: false)
        session.performResource(.clear, for: picture); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).first?.value == grantBeforeClear.value, "failed clear restores prior grant")
        check(session.values["picture"] == grantBeforeClear.value && !session.savedButNotApplied, "failed revoke cannot leave UI claiming cleared")
        try fm.removeItem(at: document); try bytesBeforeClear.write(to: document)
        session.retry(); await session.waitUntilIdle()
        check(try await assets.grants(itemID: itemA).isEmpty, "failed clear retries same revoke transaction")
        check(fm.fileExists(atPath: grantBeforeClear.assets[0].url.path), "UI never prunes versions retained for old hosts")
        session.performResource(.select(image), for: picture); await session.waitUntilIdle()
        session.set(.bool(false), for: project.definition(for: "enabled")!); await session.waitUntilIdle()
        let scalarCallsBeforeReset = scalarCalls
        session.resetEditable(); await session.waitUntilIdle()
        let mixedReset = try await overrides.load(itemID: itemA)
        check(mixedReset["picture"] == nil && mixedReset["enabled"] == nil, "mixed reset clears native resource and scalar overrides")
        check(scalarCalls == scalarCallsBeforeReset + 1 && !session.isSaving, "mixed reset scalar callback once, resource callback remains separate")
        let noActions = AuthorPropertySettingsSession(project: project, overrideStore: overrides, itemID: UUID(),
            capabilities: caps, coalescingDelay: .zero) { _ in preconditionFailure("resource without bridge dispatched") }
        await noActions.load()
        check(!noActions.canEdit(picture) && !noActions.canEdit(photos), "resource controls remain locked without ready actions")
        print("PASS \(count) AP04 UI resource transaction checks; real temporary asset actor, fixture host ACK")
    }
}
