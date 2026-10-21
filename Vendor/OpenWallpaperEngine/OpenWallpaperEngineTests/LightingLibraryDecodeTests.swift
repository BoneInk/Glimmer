import XCTest
@testable import OpenWallpaperEngine

/// The library survey of docs/lighting-plan.md §1.5, rerun through the app's decoder: every scene
/// of the Workshop folder, OpenWallpaperStorage and WE's default projects (de-duplicated by
/// Workshop id, the Workshop copy first; `project.json` type "scene" only), its scene file read
/// loose or from its `.pkg`. Every scene decodes, and what it decodes is what its JSON authors:
/// one light of the named kind per object with a `light`, `lightconfig`, `hdr` and
/// `bloomhdrstrength`. The survey's lit and HDR scenes (`known`) are checked by name as well; one
/// the library no longer has is skipped. Skipped when the library is absent (CI).
final class LightingLibraryDecodeTests: XCTestCase {
    private static let weRoot = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps"
    static let roots = [URL(fileURLWithPath: "\(weRoot)/workshop/content/431960"),
                        URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage"),
                        URL(fileURLWithPath: "\(weRoot)/common/wallpaper_engine/projects/defaultprojects")]

    private struct Survey: Equatable {
        var lights: [WELightKind] = []
        var lightConfig = false
        var hdr = false
    }

    /// The survey's scenes with lights, a `lightconfig` or `hdr: true` (§1.5), by Workshop id or
    /// folder name.
    private static let known: [String: Survey] = [
        "3074485715": Survey(hdr: true),
        "3270035750": Survey(lights: [.tube, .tube, .tube, .tube], lightConfig: true),
        "3352730400": Survey(lights: [.spot], lightConfig: true, hdr: true),
        "3453730450": Survey(lights: [.point, .point, .point], lightConfig: true),
        "3606529469": Survey(hdr: true),
        // The Knight: the library's one layer lit by legacy lights (genericimage2).
        "2515150033": Survey(lights: [.legacyPoint, .legacyPoint]),
        "arsenal": Survey(lights: [.legacyPoint, .legacyPoint]),
        "demon_core": Survey(lights: [.legacyPoint]),
        "razer_bedroom": Survey(hdr: true),
        "shimmering_particles": Survey(hdr: true),
    ]

    func testTheLibrarysLightsAndSettingsDecode() throws {
        let roots = Self.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < Self.roots.count, "wallpaper library not present")
        var seen = Set<String>()
        var scenes = 0, lightConfigs = 0, hdr = 0, bloomHDR = 0
        var kinds: [WELightKind: Int] = [:]
        var knownFound = Set<String>()
        for root in roots {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                guard let project = Self.project(in: directory) else { continue }
                let workshopID = project["workshopid"].map { "\($0)" } ?? ""
                let key = workshopID.isEmpty || workshopID == "0" ? name : workshopID
                guard !seen.contains(key), !seen.contains(name) else { continue }
                seen.formUnion([key, name])
                guard (project["type"] as? String)?.lowercased() == "scene" else { continue }
                let file = project["file"] as? String ?? "scene.json"
                let data = try XCTUnwrap(Self.read(file, in: directory), "\(name): no \(file)")
                let scene: WEScene
                let authored: (survey: Survey, unknownLights: [String], bloomHDR: Bool)
                do {
                    scene = try decodeTolerant(WEScene.self, from: data)
                    authored = try Self.authored(data)
                } catch {
                    XCTFail("\(name): \(error)")
                    continue
                }
                scenes += 1
                let decoded = Survey(lights: scene.objects.compactMap { $0.light?.kind },
                                     lightConfig: scene.general.lightconfig != nil, hdr: scene.general.hdr == true)
                XCTAssertEqual(authored.unknownLights, [], "\(key): light names that aren't WE's")
                XCTAssertEqual(decoded, authored.survey, "\(key): decoded vs authored")
                if let expected = Self.known[key] {
                    knownFound.insert(key)
                    XCTAssertEqual(decoded, expected, "\(key): the survey's")
                }
                XCTAssertEqual(scene.general.values[.bloomhdrstrength] != nil, authored.bloomHDR, "\(key): bloomhdrstrength")
                for kind in decoded.lights { kinds[kind, default: 0] += 1 }
                if decoded.lightConfig { lightConfigs += 1 }
                if decoded.hdr { hdr += 1 }
                if authored.bloomHDR { bloomHDR += 1 }
            }
        }
        XCTAssertGreaterThan(scenes, 0)
        let lights = kinds.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key)" }
        var lines = ["\(scenes) scenes; lights: \(lights.joined(separator: ", ")); \(lightConfigs) lightconfigs, "
                     + "\(hdr) hdr, \(bloomHDR) with bloomhdrstrength"]
        let missing = Set(Self.known.keys).subtracting(knownFound).sorted()
        if !missing.isEmpty {
            lines.append("survey scenes no longer in the library, skipped: \(missing.joined(separator: ", "))")
        }
        LibraryReport.attach("Lighting library survey", lines)
    }

    /// What the scene's JSON authors: every object's non-null `light` (the names that aren't one
    /// of WE's kinds apart), `general.lightconfig`, `general.hdr` (a literal, or a bound value's
    /// `value`) and whether `general.bloomhdrstrength` is there.
    private static func authored(_ data: Data) throws -> (survey: Survey, unknownLights: [String], bloomHDR: Bool) {
        let root = try json(data)
        var survey = Survey()
        var unknown: [String] = []
        for object in root["objects"] as? [[String: Any]] ?? [] {
            guard let light = object["light"], !(light is NSNull) else { continue }
            let name = light as? String ?? (light as? [String: Any])?["value"] as? String ?? "\(light)"
            if let kind = WELightKind(name: name) { survey.lights.append(kind) } else { unknown.append(name) }
        }
        let general = root["general"] as? [String: Any] ?? [:]
        survey.lightConfig = general["lightconfig"] is [String: Any]
        let hdr = general["hdr"]
        survey.hdr = (hdr as? Bool ?? (hdr as? [String: Any])?["value"] as? Bool) == true
        return (survey, unknown, general["bloomhdrstrength"] != nil)
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return try JSONSerialization.jsonObject(with: Data(bytes), options: [.json5Allowed]) as? [String: Any] ?? [:]
    }

    /// `project.json`; nil for a folder without one. `try?`: an unreadable one isn't a wallpaper.
    private static func project(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])) as? [String: Any]
    }

    /// A loose file wins over the same path inside a `.pkg`, as WE reads a wallpaper.
    private static func read(_ file: String, in directory: URL) -> Data? {
        if let loose = FileManager.default.contents(atPath: directory.appending(path: file).path) { return loose }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "pkg" else { continue }
            do {
                if let data = try PKGParser(url: url).extractFile(named: file) { return data }
            } catch {
                XCTFail("\(url.path): \(error)")
            }
        }
        return nil
    }
}
