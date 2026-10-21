import Foundation

@MainActor
private final class HostProbe {
    var payloads: [[String: GWJSONValue]] = []
    var failHost = false
    var holdNext = false
    var gate: CheckedContinuation<Void, Never>?
}

@main
struct AuthorPropertySettingsSessionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label)
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GWAuthorSettings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(#"{"type":"web","general":{"properties":{"enabled":{"type":"bool","value":true},"speed":{"type":"slider","value":2,"min":0,"max":10},"tint":{"type":"color","value":"1 0 0"},"mode":{"type":"combo","value":"one","options":[{"label":"One","value":"one"},{"label":"Two","value":"two"}]},"caption":{"type":"textinput","value":"Hello"},"file":{"type":"file","value":""},"folder":{"type":"directory","value":""},"unsafe":{"type":"bool","value":true,"condition":"unknownFunction()"},"heading":{"type":"text","text":"Heading"}}}}"#.utf8)
        let project = try AuthorPropertyProject.parse(data: data, projectURL: root.appendingPathComponent("project.json"))
        func definition(_ key: String) -> AuthorPropertyDefinition { project.definition(for: key)! }
        let directory = root.appendingPathComponent("overrides")
        let store = AuthorPropertyOverrideStore(directory: directory)
        let itemID = UUID()
        let keys = AuthorPropertyEditingCapabilities.scalarKeys(in: project)
        check(keys.contains("speed") && !keys.contains("file") && !keys.contains("folder") && !keys.contains("heading"), "scalar whitelist")
        let caps = AuthorPropertyEditingCapabilities(editableKeys: keys, runtimeLabel: "测试播放器", unsupportedReason: "不支持")
        let host = HostProbe()
        let session = AuthorPropertySettingsSession(project: project, overrideStore: store, itemID: itemID,
            capabilities: caps, coalescingDelay: .zero) { payload in
                host.payloads.append(payload)
                if host.holdNext { host.holdNext = false; await withCheckedContinuation { host.gate = $0 } }
                if host.failHost { throw AuthorPropertyError(message: "host rejected") }
            }
        await session.load()
        check(session.isReady && host.payloads.isEmpty, "opening only reads")
        let initialSummary = AuthorPropertySettingsSummary(session: session)
        check(initialSummary.editableCount == 5 && initialSummary.modifiedCount == 0, "summary counts only actual scalar controls, no unsupported conditions/resources/headings")
        check(!FileManager.default.fileExists(atPath: directory.path), "opening writes nothing")
        check(!session.canEdit(definition("file")) && !session.canEdit(definition("unsafe")), "unsupported controls disabled")
        session.set(.number(99), for: definition("speed"))
        session.retry()
        await session.waitUntilIdle()
        check(host.payloads.isEmpty && !session.canRetry, "invalid edits never dispatch, including retry")
        session.set(.number(3), for: definition("speed"))
        session.set(.number(4), for: definition("speed"))
        await session.waitUntilIdle()
        check(host.payloads.count == 1 && host.payloads.last?["speed"] == .number(4), "coalesce latest edit")
        check(host.payloads.last?["file"] == nil && host.payloads.last?["folder"] == nil, "unsupported values never dispatched")
        let saved = try await store.load(itemID: itemID)
        check(saved["speed"] == .number(4) && session.isModified("speed"), "saved persisted value")
        host.holdNext = true
        session.set(.number(5), for: definition("speed"))
        while host.gate == nil { await Task.yield() }
        check(AuthorPropertySettingsSummary(session: session).activity == .applying,
              "compact summary waits for host ACK rather than treating saved bytes as applied")
        let temporarilyUnavailable = AuthorPropertyEditingCapabilities(editableKeys: [], runtimeLabel: "Loading", unsupportedReason: "")
        check(AuthorPropertySettingsSummary.effectiveCapabilities(temporarilyUnavailable, session: session) == caps,
              "transient loading capabilities retain the exact in-flight ACK transaction")
        session.set(.number(6), for: definition("speed"))
        host.gate?.resume(); host.gate = nil
        await session.waitUntilIdle()
        check(host.payloads.suffix(2).map { $0["speed"] } == [.number(5), .number(6)], "new edits survive suspended host ack")
        check(!session.isSaving && session.values["speed"] == .number(6), "drain finishes latest draft")
        check(AuthorPropertySettingsSummary.effectiveCapabilities(temporarilyUnavailable, session: session) == temporarilyUnavailable,
              "after ACK settles current capabilities are authoritative again")
        host.failHost = true
        session.set(.number(7), for: definition("speed"))
        await session.waitUntilIdle()
        let rejected = try await store.load(itemID: itemID)
        check(rejected["speed"] == .number(7), "host failure does not undo explicit persisted value")
        check(session.savedButNotApplied && session.canRetry && session.errorText?.contains("尚未应用") == true, "honest host failure state")
        let failedSummary = AuthorPropertySettingsSummary(session: session)
        check(failedSummary.activity == .retryRequired && failedSummary.modifiedCount == 1,
              "collapsed summary retains retry and actual modified count after failed ACK")
        host.failHost = false
        session.retry()
        await session.waitUntilIdle()
        check(!session.savedButNotApplied && session.errorText == nil && host.payloads.last?["speed"] == .number(7), "retry dispatches stored values")
        check(AuthorPropertySettingsSummary(session: session).activity == .idle, "summary stops retry indication only after successful retry ACK")
        try await store.set(.string("untouched.mp4"), for: "file", itemID: itemID, project: project)
        // A property removed in a later project must survive an editable-only reset.
        var disk = try JSONDecoder().decode(GWJSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(itemID.uuidString + ".json"))).objectValue!
        var existing = disk["values"]!.objectValue!
        existing["removed"] = .string("preserve")
        disk["values"] = .object(existing)
        try JSONEncoder().encode(GWJSONValue.object(disk)).write(to: directory.appendingPathComponent(itemID.uuidString + ".json"))
        await session.load()
        session.resetEditable()
        await session.waitUntilIdle()
        let reset = try await store.load(itemID: itemID)
        check(reset["speed"] == nil && session.values["speed"] == .number(2), "reset returns editable key to source default")
        check(reset["file"] == .string("untouched.mp4") && reset["removed"] == .string("preserve"), "reset preserves unsupported and orphan values")
        check(session.unknownOverrides["removed"] == .string("preserve"), "orphan remains available for readonly presentation")
        check(project.sourceData == data && !FileManager.default.fileExists(atPath: project.projectURL.path), "source project never rewritten")
        let readonly = AuthorPropertySettingsSession(project: project, overrideStore: store, itemID: itemID,
            capabilities: .init(editableKeys: [], runtimeLabel: "Video", unsupportedReason: "视频不支持"), coalescingDelay: .zero) { _ in
                preconditionFailure("readonly panel dispatched")
            }
        await readonly.load()
        readonly.set(.bool(false), for: definition("enabled"))
        readonly.reset(definition("speed")); readonly.resetEditable(); readonly.retry()
        await readonly.waitUntilIdle()
        check(!readonly.canEdit(definition("enabled")) && !readonly.isSaving, "readonly host rejects every mutation route")
        session.set(.bool(false), for: definition("enabled"))
        session.set(.string("0.2 0.4 0.6"), for: definition("tint"))
        session.set(.string("two"), for: definition("mode"))
        session.set(.string("你好"), for: definition("caption"))
        await session.waitUntilIdle()
        check(host.payloads.last?["enabled"] == .bool(false) && host.payloads.last?["tint"] == .string("0.2 0.4 0.6"), "bool and RGB values dispatch intact")
        check(host.payloads.last?["mode"] == .string("two") && host.payloads.last?["caption"] == .string("你好"), "combo and Unicode text dispatch intact")
        session.reset(definition("enabled"))
        await session.waitUntilIdle()
        let singleReset = try await store.load(itemID: itemID)
        check(singleReset["enabled"] == nil && singleReset["caption"] == .string("你好"), "single reset preserves other editable values")
        // Force an actual write failure after a successful readonly load.
        let failingDirectory = root.appendingPathComponent("write-failure")
        let failingStore = AuthorPropertyOverrideStore(directory: failingDirectory)
        var writeFailureCalls = 0
        let writeFailure = AuthorPropertySettingsSession(project: project, overrideStore: failingStore, itemID: UUID(),
            capabilities: caps, coalescingDelay: .zero) { _ in writeFailureCalls += 1 }
        try await failingStore.set(.number(2), for: "speed", itemID: writeFailure.itemID, project: project)
        await writeFailure.load()
        let failingDocument = failingDirectory.appendingPathComponent(writeFailure.itemID.uuidString + ".json")
        let originalDocument = try Data(contentsOf: failingDocument)
        try FileManager.default.removeItem(at: failingDocument)
        try FileManager.default.createDirectory(at: failingDocument, withIntermediateDirectories: false)
        writeFailure.set(.number(8), for: definition("speed"))
        await writeFailure.waitUntilIdle()
        check(writeFailureCalls == 0 && writeFailure.canRetry && !writeFailure.savedButNotApplied, "failed persistence never invokes runtime")
        try FileManager.default.removeItem(at: failingDocument)
        try originalDocument.write(to: failingDocument)
        writeFailure.retry()
        await writeFailure.waitUntilIdle()
        let recovered = try await failingStore.load(itemID: writeFailure.itemID)
        check(writeFailureCalls == 1 && recovered["speed"] == .number(8) && writeFailure.errorText == nil, "retry recovers actual write failure")
        let otherID = UUID()
        check(try await store.load(itemID: otherID).isEmpty, "different wallpaper remains untouched")
        let brokenDirectory = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: brokenDirectory)
        let broken = AuthorPropertySettingsSession(project: project, overrideStore: .init(directory: brokenDirectory), itemID: UUID(),
            capabilities: caps, coalescingDelay: .zero) { _ in preconditionFailure("load failure dispatched") }
        await broken.load()
        broken.set(.number(3), for: definition("speed")); broken.retry()
        await broken.waitUntilIdle()
        check(!broken.isReady && broken.errorText != nil && !broken.isSaving, "storage load failure cannot edit")
        print("PASS \(checks) author property settings session checks; temporary fixtures only")
    }
}
