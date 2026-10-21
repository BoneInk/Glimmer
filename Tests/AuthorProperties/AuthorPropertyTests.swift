import Foundation

@main struct AuthorPropertyTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label) } catch { checks += 1 }
        }
        func rejectsAsync(_ label: String, _ body: () async throws -> Void) async {
            do { try await body(); preconditionFailure(label) } catch { checks += 1 }
        }
        func unsupported(_ result: AuthorPropertyConditionResult) -> Bool {
            if case .unsupported(let reason) = result { return !reason.isEmpty }; return false
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let sourceBytes = try Data(contentsOf: fixture)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GW-Author-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let projectURL = projectRoot.appendingPathComponent("project.json")
        try sourceBytes.write(to: projectURL)
        let project = try AuthorPropertyProject.load(projectURL: projectURL, allowedRoot: projectRoot)
        check(project.sourceData == sourceBytes, "original JSON byte spelling and complete source retained")
        check(project.projectType == "web" && project.properties.count == 11, "full official-style author schema loaded")
        check(project.properties.first?.key == "heading" && project.properties.last?.key == "baddefault", "explicit author order honored")
        check(project.rawJSON.objectValue?["unknownProjectField"]?.objectValue?["nested"]?.arrayValue?.count == 3, "unknown nested JSON retained")
        let future = project.definition(for: "future")!
        check(future.kind == .unknown && future.raw["unknownDefinition"] == .object(["keep": .bool(true)]), "future definition retained read-only")
        check(project.definition(for: "format")!.options[0].rawJSON.objectValue?["optionExtra"] == .number(7), "combo option unknown fields retained")
        check(project.definition(for: "gallery")!.raw["mode"] == .string("fetchall"), "directory mode retained without claiming runtime delivery")
        check(project.definition(for: "format")!.condition == "showclock.value == true", "author condition retained verbatim")
        let encoder = JSONEncoder()
        let typed: GWJSONValue = .object(["true": .bool(true), "one": .number(1), "nil": .null, "array": .array([.string("x")])])
        check(try JSONDecoder().decode(GWJSONValue.self, from: encoder.encode(typed)) == typed, "typed arbitrary JSON roundtrip")
        check(GWJSONValue.bool(true) != .number(1), "JSON bool and numeric one remain distinct")
        rejects("nonfinite JSON rejected") { _ = try encoder.encode(GWJSONValue.number(.nan)) }
        let resolved = project.resolve(overrides: [:])
        check(resolved.values["speed"] == .number(1.25) && resolved.values["showclock"] == .bool(true), "valid defaults resolved")
        check(resolved.values["baddefault"] == nil && resolved.diagnostics.contains(where: { $0.key == "baddefault" }), "invalid author defaults explicitly diagnosed")
        check(resolved.diagnostics.contains(where: { $0.key == "future" }), "unsupported author type explicitly diagnosed")
        let merged = project.resolve(overrides: ["speed": .number(2), "showclock": .bool(false), "orphan": .string("preserve")])
        check(merged.values["speed"] == .number(2) && merged.values["showclock"] == .bool(false), "default override merge")
        check(merged.unknownOverrides == ["orphan": .string("preserve")], "unknown saved overrides retained separately")
        let invalidMerged = project.resolve(overrides: ["speed": .number(99)])
        check(invalidMerged.values["speed"] == .number(1.25) && invalidMerged.diagnostics.contains(where: { $0.key == "speed" }), "invalid override falls back with diagnostic")
        for color in ["1 0 0", "0.12 0.5 1", "0\t0\n0"] { try project.definition(for: "schemecolor")!.validate(.string(color)); checks += 1 }
        for color in ["255 0 0", "1 1", "nan 0 0", "1 0 0 1", "-1 0 0"] {
            rejects("bad color rejected") { try project.definition(for: "schemecolor")!.validate(.string(color)) }
        }
        rejects("bool type strict") { try project.definition(for: "showclock")!.validate(.number(1)) }
        rejects("integer slider rejects fraction") { try project.definition(for: "count")!.validate(.number(1.5)) }
        rejects("slider range strict") { try project.definition(for: "count")!.validate(.number(-1)) }
        rejects("slider step strict") { try project.definition(for: "speed")!.validate(.number(1.3)) }
        rejects("slider finite strict") { try project.definition(for: "speed")!.validate(.number(.infinity)) }
        rejects("combo membership strict") { try project.definition(for: "format")!.validate(.string("25h")) }
        rejects("textinput type strict") { try project.definition(for: "caption")!.validate(.bool(false)) }
        rejects("textinput length bounded") { try project.definition(for: "caption")!.validate(.string(String(repeating: "a", count: 65_537))) }
        rejects("file null bytes rejected") { try project.definition(for: "picture")!.validate(.string("bad\0path")) }
        rejects("directory types strict") { try project.definition(for: "gallery")!.validate(.array([])) }
        rejects("decorative text never editable") { try project.definition(for: "heading")!.validate(.string("new heading")) }
        rejects("unknown type never silently editable") { try future.validate(.object([:])) }
        check(project.localizedText("ui_clock", preferredLanguages: ["zh-Hans-CN"]) == "显示时钟", "WE zh-chs language alias")
        check(project.localizedText("ui_clock", preferredLanguages: ["zh-Hant-TW"]) == "顯示時鐘", "WE zh-cht language alias")
        check(project.localizedText("ui_clock", preferredLanguages: ["ja"]) == "時計を表示", "base language matches regional catalog")
        check(project.localizedText("ui_format", preferredLanguages: ["fr-FR"]) == "Clock format", "English fallback")
        check(project.localizedText("ui_unknown", preferredLanguages: ["zh-CN"]) == "ui_unknown", "missing localization token preserved")
        check(project.localizedText("Clock format", preferredLanguages: ["zh-CN"]) == "Clock format", "plain labels are not translation tokens")
        check(project.visibility(for: "format", values: resolved.values) == .visible, "official bool.value condition visible")
        check(project.visibility(for: "format", values: merged.values) == .hidden, "override drives safe visibility")
        check(AuthorPropertyCondition.evaluate("caption.value == 'é'", values: ["caption": .string("e\u{301}")]) == .hidden, "JS strings compare UTF16 rather than Swift canonical Unicode equality")
        let unicodeCombo = AuthorPropertyDefinition(key: "unicode", rawJSON: .object(["type": .string("combo"), "options": .array([.object(["label": .string("x"), "value": .string("é")])])]))
        rejects("combo hidden values preserve exact Unicode") { try unicodeCombo.validate(.string("e\u{301}")) }
        let largeSlider = AuthorPropertyDefinition(key: "large", rawJSON: .object(["type": .string("slider"), "min": .number(0), "max": .number(1e12), "fraction": .bool(true), "step": .number(1)]))
        rejects("large tick counts cannot relax step validation") { try largeSlider.validate(.number(1e10 + 0.5)) }
        let malformedSlider = AuthorPropertyDefinition(key: "bad", rawJSON: .object(["type": .string("slider"), "min": .number(0), "max": .number(2), "fraction": .string("true")]))
        rejects("malformed schema flags reported") { try malformedSlider.validate(.number(1)) }
        let values = resolved.values
        for expression in ["showclock.value == true", "speed.value >= 1 && (count.value < 3 || false)", "!false && true", "showclock.value == speed.value > 1", "caption.value == 'Hello'", "true || missing.value"] {
            check(AuthorPropertyCondition.evaluate(expression, values: values) == .visible, "safe supported grammar \(expression)")
        }
        check(AuthorPropertyCondition.evaluate("count.value === '2'", values: values) == .hidden, "strict comparison preserves types")
        check(AuthorPropertyCondition.evaluate("count.value != 2", values: values) == .hidden, "inequality")
        check(unsupported(AuthorPropertyCondition.evaluate("count.value == '2'", values: values)), "implicit JS coercion explicitly unsupported")
        for expression in ["missing.value", "showclock.value = false", "alert('x')", "false && evil()", "caption.value.constructor", "count.value + 1 > 0", "properties['count'].value", String(repeating: "!", count: 40) + "true", String(repeating: "a", count: 4097)] {
            check(unsupported(AuthorPropertyCondition.evaluate(expression, values: values)), "unsafe or unsupported expression never evaluated")
        }
        let directory = root.appendingPathComponent("Overrides")
        let itemA = UUID(), itemB = UUID()
        let store = AuthorPropertyOverrideStore(directory: directory)
        check(try await store.load(itemID: itemA).isEmpty, "new override store reads empty without writing")
        check(!FileManager.default.fileExists(atPath: directory.path), "read does not create persistence directory")
        try await store.set(.number(2), for: "speed", itemID: itemA, project: project)
        try await store.set(.bool(false), for: "showclock", itemID: itemA, project: project)
        check(try await store.resolve(itemID: itemA, project: project).values["speed"] == .number(2), "saved override resolves")
        check(try await store.load(itemID: itemB).isEmpty, "item UUID isolation")
        let restarted = AuthorPropertyOverrideStore(directory: directory)
        check(try await restarted.load(itemID: itemA)["showclock"] == .bool(false), "restart retains saved values")
        let fileA = directory.appendingPathComponent(itemA.uuidString + ".json")
        let beforeInvalid = try Data(contentsOf: fileA)
        await rejectsAsync("invalid set preserves disk") { try await store.set(.number(4), for: "speed", itemID: itemA, project: project) }
        check(try Data(contentsOf: fileA) == beforeInvalid, "failed validation never writes")
        var persistence = try JSONDecoder().decode(GWJSONValue.self, from: beforeInvalid).objectValue!
        persistence["futureEnvelope"] = .array([.string("keep")])
        var storedValues = persistence["values"]!.objectValue!
        storedValues["unknownSavedKey"] = .object(["opaque": .number(42)])
        persistence["values"] = .object(storedValues)
        try encoder.encode(GWJSONValue.object(persistence)).write(to: fileA)
        try await store.set(.string("12h"), for: "format", itemID: itemA, project: project)
        let preservedEnvelope = try JSONDecoder().decode(GWJSONValue.self, from: Data(contentsOf: fileA)).objectValue!
        check(preservedEnvelope["futureEnvelope"] == .array([.string("keep")]), "unknown persistence envelope fields survive edit")
        check(try await store.load(itemID: itemA)["unknownSavedKey"] == .object(["opaque": .number(42)]), "unknown saved values survive other edits")
        try await store.set(nil, for: "speed", itemID: itemA, project: project)
        check(try await store.resolve(itemID: itemA, project: project).values["speed"] == .number(1.25), "single reset returns to author default")
        check(try await store.load(itemID: itemA)["unknownSavedKey"] != nil, "single reset preserves unrelated unknown values")
        try await store.reset(itemID: itemA)
        check(try await store.load(itemID: itemA).isEmpty, "explicit reset clears only item override values")
        check(try Data(contentsOf: projectURL) == sourceBytes, "overrides and resets never modify source project")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileA.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private override file permissions")
        try Data("bad json".utf8).write(to: fileA)
        await rejectsAsync("corrupt persistence reported") { _ = try await store.load(itemID: itemA) }
        await rejectsAsync("corrupt file never silently replaced") { try await store.set(.bool(true), for: "showclock", itemID: itemA, project: project) }
        check(try Data(contentsOf: fileA) == Data("bad json".utf8), "corrupt original retained")
        let futureEnvelope = GWJSONValue.object(["schemaVersion": .number(2), "itemID": .string(itemB.uuidString), "values": .object([:]), "keep": .bool(true)])
        let futureData = try encoder.encode(futureEnvelope)
        let fileB = directory.appendingPathComponent(itemB.uuidString + ".json")
        try futureData.write(to: fileB)
        await rejectsAsync("future persistence schema not silently downgraded") { try await store.set(.bool(true), for: "showclock", itemID: itemB, project: project) }
        check(try Data(contentsOf: fileB) == futureData, "future envelope retained byte-for-byte")
        let itemC = UUID()
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(itemC.uuidString + ".json"), withDestinationURL: fileB)
        await rejectsAsync("symlink override file rejected") { _ = try await store.load(itemID: itemC) }
        rejects("out of root rejected") { _ = try AuthorPropertyProject.load(projectURL: projectURL, allowedRoot: root.appendingPathComponent("Other")) }
        let linked = projectRoot.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: projectRoot)
        rejects("symlinked project path rejected") { _ = try AuthorPropertyProject.load(projectURL: linked.appendingPathComponent("project.json"), allowedRoot: projectRoot) }
        rejects("oversized JSON rejected") { _ = try AuthorPropertyProject.parse(data: Data(repeating: 0x20, count: AuthorPropertyProject.maximumBytes + 1), projectURL: projectURL) }
        let bom = Data([0xef, 0xbb, 0xbf]) + sourceBytes
        check(try AuthorPropertyProject.parse(data: bom, projectURL: projectURL).sourceData == bom, "BOM accepted without losing original source bytes")
        let maliciousStoreURL = root.appendingPathComponent("OverrideSymlink")
        try FileManager.default.createSymbolicLink(at: maliciousStoreURL, withDestinationURL: directory)
        let malicious = AuthorPropertyOverrideStore(directory: maliciousStoreURL)
        await rejectsAsync("symlink persistence directory rejected") { _ = try await malicious.load(itemID: itemA) }
        let retryDirectory = root.appendingPathComponent("RetryOverrides")
        let retryStore = AuthorPropertyOverrideStore(directory: retryDirectory)
        check(try await retryStore.load(itemID: itemB).isEmpty, "retry store starts missing without writes")
        try Data("temporary blocker".utf8).write(to: retryDirectory)
        await rejectsAsync("regular file cannot become override directory") { try await retryStore.set(.bool(false), for: "showclock", itemID: itemB, project: project) }
        try FileManager.default.removeItem(at: retryDirectory)
        try await retryStore.set(.bool(false), for: "showclock", itemID: itemB, project: project)
        check(try await retryStore.load(itemID: itemB)["showclock"] == .bool(false), "same store recovers after filesystem obstruction removed")
        var liveCount = 0
        if let live = ProcessInfo.processInfo.environment["GW_AUTHOR_LIVE_ROOT"] {
            let liveRoot = URL(fileURLWithPath: live)
            let enumerator = FileManager.default.enumerator(at: liveRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                guard url.lastPathComponent == "project.json", liveCount < 128 else { continue }
                let actual = try AuthorPropertyProject.load(projectURL: url, allowedRoot: liveRoot)
                check(try Data(contentsOf: url) == actual.sourceData, "live author project read-only bytes match")
                let liveResolved = actual.resolve(overrides: [:])
                check(liveResolved.diagnostics.isEmpty, "live author defaults valid")
                liveCount += 1
            }
        }
        print("AuthorPropertyTests: \(checks) passed; exact JSON, strict values, safe condition subset, item-isolated atomic overrides, path bounds; live read-only projects=\(liveCount); no runtime compatibility claim")
    }
}
