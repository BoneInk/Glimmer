import CoreGraphics
import Foundation
import WEFormat

/// The small wallpapers editor previews are rendered from (`EditorPreviewCache`), written into a
/// scratch folder the real loader and renderer read like any wallpaper:
/// - an effect: one image layer showing the editor's test card, with the effect added at its
///   default values, in a 2D scene of the card's size; texture slots an effect needs filled
///   (a depth map, a flow map, a mask with no switch) get a generated picture (`Input`);
/// - a particle system: the system (or a preset's systems) on a dark background, in a 2D scene of
///   a wallpaper's proportions framed on what it draws (`fittedFraming`), or for a 3D one, WE's
///   particle editor camera.
public enum EditorPreviewScene {
    /// A scene's size in its own units, and the preview's size in pixels.
    public struct Frame: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    /// The test card's size (`EditorPreviewTestCard.png`), and the effect preview's.
    public static let effectFrame = Frame(width: 512, height: 320, pixelWidth: 384, pixelHeight: 240)
    /// A 2D particle preview: a 1280×720 piece of a wallpaper around the system.
    public static let particleFrame = Frame(width: 1280, height: 720, pixelWidth: 480, pixelHeight: 270)
    /// The particle preview's background.
    public static let particleBackground = "0.05 0.05 0.07"
    /// WE's particle editor camera for 3D systems (`assets/scenes/particleeditor3dscale`).
    public static let camera3D = (eye: "1.7 1 2.9", center: "0 0 0", up: "0 1 0")

    /// The test card's texture, model and material in the preview's folder.
    public static let testCardFile = "materials/editorpreview/testcard.png"
    static let testCardTexture = "editorpreview/testcard"
    static let testCardModel = "models/editorpreview/testcard.json"
    static let testCardMaterial = "materials/editorpreview/testcard.json"

    // MARK: Generated inputs

    /// A picture an effect's texture slot needs to show anything, generated for the preview.
    public enum Input: String, Codable, CaseIterable, Sendable {
        /// A mask, white in the middle fading to black at the edges.
        case mask
        /// A depth map: near (white) in the middle, far at the edges.
        case depth
        /// A flow map turning around the middle (direction in red and green, 0.5 for none).
        case flow

        /// The texture an effect's pass names.
        public var texture: String { "masks/editorpreview_\(rawValue)" }
        /// The file in the preview's folder.
        public var file: String { "materials/\(texture).png" }
    }

    /// The input a texture slot needs, from its shader annotation: a depth or flow map, or a mask
    /// whose slot has no switch (`combo`) and no picture of its own. Nil for any other slot (it
    /// uses its default, or the effect turns the feature off without it).
    public static func input(mode: String?, combo: String?, defaultTexture: String?, hidden: Bool) -> Input? {
        guard !hidden, combo?.isEmpty ?? true else { return nil }
        let mode = mode?.lowercased() ?? ""
        let fallback = defaultTexture?.lowercased() ?? ""
        switch mode {
        case "depth": return .depth
        case "flowmask": return .flow
        case "opacitymask", "rgbmask": return fallback.isEmpty || fallback == "util/black" ? .mask : nil
        default: return nil
        }
    }

    /// The input's picture as a PNG, `size` pixels square.
    public static func png(_ input: Input, size: Int = 256) -> Data? {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let centre = Double(size - 1) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - centre) / centre, dy = (Double(y) - centre) / centre
                let distance = min((dx * dx + dy * dy).squareRoot(), 1)
                let index = (y * size + x) * 4
                switch input {
                case .mask, .depth:
                    // Smooth falloff: 1 at the middle, 0 at the edge.
                    let value = 1 - distance * distance * (3 - 2 * distance)
                    let byte = UInt8((value * 255).rounded())
                    pixels[index] = byte
                    pixels[index + 1] = byte
                    pixels[index + 2] = byte
                case .flow:
                    // Counter-clockwise around the middle, strongest half-way out.
                    let length = max((dx * dx + dy * dy).squareRoot(), 1e-6)
                    let strength = sin(min(distance, 1) * .pi)
                    let fx = -dy / length * strength, fy = dx / length * strength
                    pixels[index] = UInt8(((0.5 + 0.5 * fx) * 255).rounded())
                    pixels[index + 1] = UInt8(((0.5 + 0.5 * fy) * 255).rounded())
                    pixels[index + 2] = 0
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // The context draws from the buffer only while it is borrowed: the image is made inside.
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        return image.flatMap(EditorAssetStore.pngData)
    }

    // MARK: Effects

    /// The files of an effect's preview besides the test card's picture (`testCardFile`) and the
    /// effect's own files: project.json, scene.json, and the card's model and material.
    /// `passInputs` holds, per pass of the effect, the generated inputs by texture slot;
    /// `authored`, per pass, the settings WE's own preview of the effect gives it
    /// (`authoredPasses`, its values already in range, `clampedConstants`), which win over the
    /// effect's defaults.
    public static func effectFiles(effectFile: String, passInputs: [[Int: Input]],
                                   authored: [[String: Any]] = []) throws -> [String: Data] {
        let frame = effectFrame
        let count = max(passInputs.count, authored.count)
        let passes: [Any] = (0..<count).map { index -> [String: Any] in
            effectPass(inputs: index < passInputs.count ? passInputs[index] : [:],
                       authored: index < authored.count ? authored[index] : [:])
        }
        let object: [String: Any] = [
            "id": 1, "name": "Test card", "image": testCardModel, "visible": true,
            "origin": "\(frame.width / 2) \(frame.height / 2) 0", "scale": "1 1 1", "angles": "0 0 0",
            "size": "\(frame.width) \(frame.height)",
            "effects": [["id": 2, "file": effectFile, "name": "", "visible": true, "passes": passes]],
        ]
        var files = try sceneFiles(scene(frame: frame, clearColor: "0 0 0", camera: nil, objects: [object]))
        try files.merge(testCardFiles()) { $1 }
        return files
    }

    /// The test card's model and material.
    static func testCardFiles() throws -> [String: Data] {
        [
            testCardMaterial: try json([
                "passes": [[
                    "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
                    "shader": "genericimage2", "textures": [testCardTexture],
                ]],
            ]),
            testCardModel: try json(["autosize": true, "material": testCardMaterial]),
        ]
    }

    /// One pass of the previewed effect: WE's preview's values and combos, its textures in the
    /// slots it fills (its masks and maps: shake's is a sideways direction map over most of the
    /// picture), but a render target of its own scene (`_rt_…`), and the generated inputs in the
    /// others.
    static func effectPass(inputs: [Int: Input], authored: [String: Any]) -> [String: Any] {
        var pass: [String: Any] = [:]
        for key in ["combos", "constantshadervalues"] { if let value = authored[key] { pass[key] = value } }
        let named: [Int: String] = authoredTextures(authored)
        let last: Int? = (Array(inputs.keys) + Array(named.keys)).max()
        guard let last else { return pass }
        pass["textures"] = (0...last).map { slot -> Any in named[slot] ?? inputs[slot]?.texture ?? NSNull() }
        return pass
    }

    /// An authored pass's `constantshadervalues` with each plain number or vector held to the
    /// range its shader declares for that key (`ranges`, by material key, any case), as the
    /// editor's sliders hold them: a value from outside it is one an older version of the effect
    /// took (WE's preview of foliage sway still has a strength of 93 for a 0.01…1 slider).
    /// Animated values and keys without a range are kept.
    public static func clampedConstants(_ pass: [String: Any], ranges: [String: ClosedRange<Double>]) -> [String: Any] {
        guard let constants = pass["constantshadervalues"] as? [String: Any], !ranges.isEmpty else { return pass }
        var lowered: [String: ClosedRange<Double>] = [:]
        for (key, range) in ranges { lowered[key.lowercased()] = range }
        var clamped = constants
        for (key, value) in constants {
            guard let range = lowered[key.lowercased()] else { continue }
            func hold(_ number: Double) -> Double { min(max(number, range.lowerBound), range.upperBound) }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                clamped[key] = hold(number.doubleValue)
            } else if let text = value as? String {
                let numbers = text.split(separator: " ").compactMap { Double($0) }
                guard !numbers.isEmpty else { continue }
                clamped[key] = numbers.map { hold($0) }.map { String($0) }.joined(separator: " ")
            }
        }
        var result = pass
        result["constantshadervalues"] = clamped
        return result
    }

    /// The textures an authored pass names by slot, without slot 0 (the layer's own image) and
    /// its scene's render targets.
    static func authoredTextures(_ pass: [String: Any]) -> [Int: String] {
        var named: [Int: String] = [:]
        for (slot, texture) in (pass["textures"] as? [Any] ?? []).enumerated() {
            guard slot > 0, let name = texture as? String, !name.isEmpty, !name.hasPrefix("_rt_") else { continue }
            named[slot] = name
        }
        return named
    }

    // MARK: WE's own effect previews

    /// The project of WE's own preview of a built-in effect (`effect.json`'s `preview`), relative
    /// to the effect's folder; nil without one.
    public static func previewProject(effectJSON: Data) -> String? {
        // Optional: an effect file that can't be read has no preview (the load logs it).
        guard let root = try? TolerantJSON.object(from: effectJSON) as? [String: Any],
              let preview = root["preview"] as? String, !preview.isEmpty else { return nil }
        return preview
    }

    /// The passes WE's own preview scene (`scene`, its scene.json) gives `effectFile`: those of its
    /// first visible instance on a visible layer, as WE's editor shows the effect in its browser.
    /// Empty when the scene doesn't use the effect.
    public static func authoredPasses(effectFile: String, scene: Data) -> [[String: Any]] {
        // Optional: a preview scene that can't be read leaves the effect at its defaults.
        guard let root = try? TolerantJSON.object(from: scene) as? [String: Any] else { return [] }
        let wanted = effectFile.lowercased()
        for object in root["objects"] as? [[String: Any]] ?? [] where object["visible"] as? Bool ?? true {
            for effect in object["effects"] as? [[String: Any]] ?? [] where effect["visible"] as? Bool ?? true {
                guard (effect["file"] as? String)?.lowercased() == wanted else { continue }
                return effect["passes"] as? [[String: Any]] ?? []
            }
        }
        return []
    }

    /// The files of the textures `passes` name that a preview's folder may hold: each name's
    /// `.tex`, `.tex-json`, `.png` and `.jpg` under `materials/`.
    public static func authoredTextureFiles(_ passes: [[String: Any]]) -> [String] {
        let names = Set(passes.flatMap { authoredTextures($0).values })
        return names.sorted().flatMap { name in
            ["tex", "tex-json", "png", "jpg"].map { "materials/\(name).\($0)" }
        }
    }

    /// A built-in effect's files (`effect.json`'s `dependencies`): its materials, shaders and
    /// textures, which WE's editor copies from `assets/effects/<name>/` into the project, where WE
    /// reads them (`EditorWallpaperResources.prepareEffect`).
    public static func builtInDependencies(effectJSON: Data) -> [String] {
        // Optional: an effect file that can't be read has no dependencies (the load logs it).
        guard let root = try? TolerantJSON.object(from: effectJSON) as? [String: Any] else { return [] }
        return (root["dependencies"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// The files of a Workshop effect a wallpaper ships, by their path in the wallpaper: the
    /// effect file, its `dependencies`, its passes' materials, their shaders (with the headers
    /// they include) and textures. Only the files `read` finds are listed.
    public static func workshopFiles(effectFile: String, read: (String) -> Data?) -> [String] {
        var files: [String] = []
        var seen = Set<String>()
        func add(_ path: String) -> Data? {
            guard !seen.contains(path) else { return nil }
            seen.insert(path)
            guard let data = read(path) else { return nil }
            files.append(path)
            return data
        }
        guard let effectData = add(effectFile),
              let effect = try? TolerantJSON.object(from: effectData) as? [String: Any] else { return files }
        for dependency in effect["dependencies"] as? [Any] ?? [] {
            if let path = dependency as? String { _ = add(path) }
        }
        let materials = (effect["passes"] as? [[String: Any]] ?? []).compactMap { $0["material"] as? String }
        for materialPath in materials {
            // Optional: a material the wallpaper doesn't ship is WE's (found in its assets).
            guard let data = add(materialPath),
                  let material = try? TolerantJSON.object(from: data) as? [String: Any] else { continue }
            for pass in material["passes"] as? [[String: Any]] ?? [] {
                if let shader = pass["shader"] as? String {
                    for stage in ["vert", "frag", "geom"] {
                        if let source = add("shaders/\(shader).\(stage)") { addIncludes(of: source, add: add) }
                    }
                }
                for texture in pass["textures"] as? [Any] ?? [] {
                    guard let name = texture as? String, !name.isEmpty, !name.hasPrefix("_rt_") else { continue }
                    for candidate in ["materials/\(name).tex", "materials/\(name).tex-json", "materials/\(name).png",
                                      "materials/\(name).jpg"] {
                        _ = add(candidate)
                    }
                }
            }
        }
        return files
    }

    /// Adds the headers a shader includes (`#include "common.h"` → `shaders/common.h`), and theirs.
    private static func addIncludes(of source: Data, add: (String) -> Data?) {
        let text = String(decoding: source, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"#include\s+"([^"]+)""#) else { return }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            if let header = add("shaders/\(text[range])") { addIncludes(of: header, add: add) }
        }
    }

    // MARK: Particles

    /// A default system's scene object: the system at the middle of the scene.
    public static func systemObjects(path: String, is3D: Bool) -> [SceneJSONValue] {
        [.object([
            "id": .number(1), "name": .string("Particle System"), "particle": .string(path), "visible": .bool(true),
            "origin": .string(is3D ? "0 0 0" : "\(particleFrame.width / 2) \(particleFrame.height / 2) 0"),
            "scale": .string("1 1 1"), "angles": .string("0 0 0"),
        ])]
    }

    /// A preset variant's objects, numbered and placed as WE's editor adds them: their origins
    /// are offsets from the middle of a 2D scene.
    public static func presetObjects(_ objects: [SceneJSONValue], is3D: Bool) -> [SceneJSONValue] {
        let centre: [Double] = is3D ? [0, 0, 0] : [Double(particleFrame.width / 2), Double(particleFrame.height / 2), 0]
        return objects.enumerated().compactMap { index, authored in
            guard case .object(var fields) = authored else { return nil }
            fields["id"] = .number(Double(index + 1))
            let origin = SceneVector.components(fields["origin"], fallback: [0, 0, 0])
            fields["origin"] = SceneVector.value([origin[0] + centre[0], origin[1] + centre[1], origin[2] + centre[2]])
            return .object(fields)
        }
    }

    /// project.json and scene.json of a particle preview showing `objects`; a 2D one in `framing`.
    public static func particleFiles(objects: [SceneJSONValue], is3D: Bool,
                                     framing: Framing = particleFraming) throws -> [String: Data] {
        let placed: [SceneJSONValue] = is3D ? objects : objects.map { framing.place($0) }
        return try sceneFiles(scene(frame: is3D ? nil : framing.frame, clearColor: particleBackground,
                                    camera: is3D ? camera3D : nil, objects: placed.map(\.any)))
    }

    // MARK: Particle timing

    /// The longest a particle preview runs, its lead-in and loop together, in seconds.
    public static let particleSecondsCap = 8.0
    /// A particle loop's shortest and longest length, in seconds.
    public static let particleLoopSeconds: ClosedRange<Double> = 2...5
    /// A particle preview's shortest lead-in, in seconds.
    public static let particleMinimumLeadIn = 1.5

    /// How long a particle preview runs before its loop, and its loop, in seconds.
    public struct ParticleTiming: Equatable, Sendable {
        public var leadIn: Double
        public var loop: Double
    }

    /// The timing of a preview whose systems take `cycle` seconds to play out (`cycleSeconds`):
    /// a whole cycle runs before the loop, so it is under way, and the loop holds a whole cycle,
    /// within `particleLoopSeconds` and `particleSecondsCap`.
    public static func particleTiming(cycle: Double) -> ParticleTiming {
        let loop: Double = min(max(cycle, particleLoopSeconds.lowerBound), particleLoopSeconds.upperBound)
        let leadIn: Double = min(max(cycle, particleMinimumLeadIn), particleSecondsCap - loop)
        return ParticleTiming(leadIn: leadIn, loop: loop)
    }

    /// How long one cycle of the system at `path` takes to play out, in seconds: its emitters'
    /// longest `delay`, then the longest of an emission's period (1 / `rate`, or a periodic
    /// emitter's longest duration plus delay), a particle's longest life (the last
    /// `lifetimerandom`'s `max`; WE's default 1 s without one) and its children's cycles (an
    /// `eventdeath` child's after the particle's life). `read` gives a system's definition; a
    /// system inside its own children counts once.
    public static func cycleSeconds(ofSystem path: String, read: (String) -> ParticleDefinition?) -> Double {
        cycleSeconds(ofSystem: path, read: read, open: [])
    }

    private static func cycleSeconds(ofSystem path: String, read: (String) -> ParticleDefinition?,
                                     open: Set<String>) -> Double {
        let key = path.lowercased()
        guard !open.contains(key), let system = read(path) else { return 0 }
        let inner: Set<String> = open.union([key])
        var delay: Double = 0
        var period: Double = 0
        for emitter in system.items(.emitter) {
            delay = max(delay, number(emitter["delay"]))
            let rate: Double = number(emitter["rate"])
            if rate > 0 { period = max(period, 1 / rate) }
            let periodic: Double = number(emitter["maxperiodicduration"]) + number(emitter["maxperiodicdelay"])
            period = max(period, periodic)
        }
        let lifetimes = system.items(.initializer).filter { $0["name"]?.stringValue?.lowercased() == "lifetimerandom" }
        let lifetime: Double = lifetimes.last.map { number($0["max"], fallback: 1) } ?? 1
        var cycle: Double = max(period, lifetime)
        for child in system.items(.children) {
            guard let name = child["name"]?.stringValue else { continue }
            let childCycle: Double = cycleSeconds(ofSystem: name, read: read, open: inner)
            let afterDeath: Bool = child["type"]?.stringValue?.lowercased() == "eventdeath"
            cycle = max(cycle, afterDeath ? lifetime + childCycle : childCycle)
        }
        return delay + cycle
    }

    /// A field's first component; `fallback` when it has none, 0 when negative.
    private static func number(_ value: SceneJSONValue?, fallback: Double = 0) -> Double {
        max(SceneVector.components(value).first ?? fallback, 0)
    }

    // MARK: Particle framing

    /// Where a 2D particle preview looks: the scene's size, and how far its objects are moved from
    /// where `systemObjects` and `presetObjects` place them (the middle of `particleFrame`).
    public struct Framing: Equatable, Sendable {
        public var frame: Frame
        public var shift: [Double]

        /// `object` moved by `shift`.
        func place(_ object: SceneJSONValue) -> SceneJSONValue {
            guard case .object(var fields) = object else { return object }
            let origin = SceneVector.components(fields["origin"], fallback: [0, 0, 0])
            let moved: [Double] = [origin[0] + shift[0], origin[1] + shift[1], origin[2]]
            fields["origin"] = SceneVector.value(moved)
            return .object(fields)
        }
    }

    /// The framing a 2D particle preview starts from: `particleFrame`.
    public static let particleFraming = Framing(frame: particleFrame, shift: [0, 0])
    /// How much wider than `particleFrame` the probe that finds a system's content looks.
    public static let particleProbeScale = 4
    /// How much of the preview the content fills, and the closest it is framed (a share of
    /// `particleFrame`'s width), so a tiny system isn't blown up.
    public static let particleFill = 0.8
    public static let particleClosest = 0.25

    /// `particleFrame` zoomed out `particleProbeScale` times about its middle, at the same pixel size.
    public static var probeFraming: Framing {
        let scale = particleProbeScale
        let frame = Frame(width: particleFrame.width * scale, height: particleFrame.height * scale,
                          pixelWidth: particleFrame.pixelWidth, pixelHeight: particleFrame.pixelHeight)
        let shift: [Double] = [Double(frame.width - particleFrame.width) / 2, Double(frame.height - particleFrame.height) / 2]
        return Framing(frame: frame, shift: shift)
    }

    /// How close content comes to the probe's edge, as a share of its size, to run on past it
    /// (the content's bounds are trimmed, and a stream's ends are sparse).
    static let probeEdge = 0.05

    /// The framing in which `content` (a rectangle of `probe`'s pixels, from the top left) fills
    /// `particleFill` of the preview, centred, at `particleFrame`'s proportions. Content reaching
    /// the probe's edge on an axis runs on past it (rain falling out of the scene), so that axis
    /// isn't fitted and keeps `particleFrame`'s middle; on both axes, `particleFraming` stays.
    public static func fittedFraming(content: CGRect, probe: Framing) -> Framing {
        let pixelWidth = Double(probe.frame.pixelWidth)
        let pixelHeight = Double(probe.frame.pixelHeight)
        let edgeX: Double = pixelWidth * probeEdge
        let edgeY: Double = pixelHeight * probeEdge
        let runsX: Bool = Double(content.minX) <= edgeX || Double(content.maxX) >= pixelWidth - edgeX
        let runsY: Bool = Double(content.minY) <= edgeY || Double(content.maxY) >= pixelHeight - edgeY
        if runsX, runsY { return particleFraming }
        let unitsX: Double = Double(probe.frame.width) / pixelWidth
        let unitsY: Double = Double(probe.frame.height) / pixelHeight
        let contentWidth: Double = runsX ? 0 : Double(content.width) * unitsX
        let contentHeight: Double = runsY ? 0 : Double(content.height) * unitsY
        // Scene units have y up; pixels have it down.
        let centreX: Double = runsX ? Double(probe.frame.width) / 2 : Double(content.midX) * unitsX
        let centreY: Double = runsY ? Double(probe.frame.height) / 2 : (pixelHeight - Double(content.midY)) * unitsY
        let aspect: Double = Double(particleFrame.width) / Double(particleFrame.height)
        let fitted: Double = max(contentWidth, contentHeight * aspect) / particleFill
        let width: Double = max(fitted, Double(particleFrame.width) * particleClosest)
        let height: Double = width / aspect
        let frame = Frame(width: Int(width.rounded()), height: Int(height.rounded()),
                          pixelWidth: particleFrame.pixelWidth, pixelHeight: particleFrame.pixelHeight)
        let shiftX: Double = probe.shift[0] + Double(frame.width) / 2 - centreX
        let shiftY: Double = probe.shift[1] + Double(frame.height) / 2 - centreY
        return Framing(frame: frame, shift: [shiftX.rounded(), shiftY.rounded()])
    }

    /// Where a preview's content is: per column and row of its pixels, how many pixels of the
    /// frames added differ from the background (the first frame's most common colour).
    public struct ContentBounds: Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        private var columns: [Int]
        private var rows: [Int]
        private var background: [UInt8]?
        /// A channel this far from the background's (of 255) is content.
        static let tolerance = 6

        public init(pixelWidth: Int, pixelHeight: Int) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            columns = Array(repeating: 0, count: pixelWidth)
            rows = Array(repeating: 0, count: pixelHeight)
        }

        public mutating func add(_ image: CGImage) {
            guard let pixels = EditorPreviewScene.rgba(image, width: pixelWidth, height: pixelHeight) else { return }
            let background: [UInt8] = self.background ?? Self.commonest(pixels)
            self.background = background
            for y in 0..<pixelHeight {
                for x in 0..<pixelWidth {
                    let index = (y * pixelWidth + x) * 4
                    let red: Int = abs(Int(pixels[index]) - Int(background[0]))
                    let green: Int = abs(Int(pixels[index + 1]) - Int(background[1]))
                    let blue: Int = abs(Int(pixels[index + 2]) - Int(background[2]))
                    guard max(red, green, blue) > Self.tolerance else { continue }
                    columns[x] += 1
                    rows[y] += 1
                }
            }
        }

        /// The pixel rectangle (from the top left) holding the content but `trim` of it at each
        /// side, so a stray spark doesn't stretch it; nil when nothing differs from the background.
        public func rect(trim: Double = 0.01) -> CGRect? {
            guard let horizontal = Self.span(columns, trim: trim), let vertical = Self.span(rows, trim: trim) else { return nil }
            return CGRect(x: horizontal.lowerBound, y: vertical.lowerBound,
                          width: horizontal.count, height: vertical.count)
        }

        /// The indices holding all but `trim` of the counts at each end.
        private static func span(_ counts: [Int], trim: Double) -> ClosedRange<Int>? {
            let total = counts.reduce(0, +)
            guard total > 0 else { return nil }
            let cut = Int(Double(total) * trim)
            var low = 0
            var sum = 0
            while low < counts.count - 1, sum + counts[low] <= cut {
                sum += counts[low]
                low += 1
            }
            var high = counts.count - 1
            sum = 0
            while high > low, sum + counts[high] <= cut {
                sum += counts[high]
                high -= 1
            }
            return low...high
        }

        private static func commonest(_ pixels: [UInt8]) -> [UInt8] {
            var counts: [UInt32: Int] = [:]
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let key: UInt32 = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
                counts[key, default: 0] += 1
            }
            let key: UInt32 = counts.max { $0.value < $1.value }?.key ?? 0
            return [UInt8(key >> 16 & 0xFF), UInt8(key >> 8 & 0xFF), UInt8(key & 0xFF)]
        }
    }

    // MARK: Effect motion

    /// A channel this far apart (of 255) is a change, and a frame with more than `movingFraction`
    /// of its pixels changed has moved.
    public static let changeTolerance = 3
    public static let movingFraction = 0.0005

    /// The share of `image`'s pixels with a channel more than `changeTolerance` from
    /// `reference`'s, 0…1; nil when their sizes differ or they can't be read.
    public static func changedFraction(_ image: CGImage, from reference: CGImage) -> Double? {
        let width = reference.width
        let height = reference.height
        guard image.width == width, image.height == height, width > 0, height > 0,
              let a = rgba(image, width: width, height: height),
              let b = rgba(reference, width: width, height: height) else { return nil }
        var changed = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            let red: Int = abs(Int(a[index]) - Int(b[index]))
            let green: Int = abs(Int(a[index + 1]) - Int(b[index + 1]))
            let blue: Int = abs(Int(a[index + 2]) - Int(b[index + 2]))
            if max(red, green, blue) > changeTolerance { changed += 1 }
        }
        return Double(changed) / Double(width * height)
    }

    /// Whether `frame` has visibly moved from `first`.
    public static func moved(_ frame: CGImage, from first: CGImage) -> Bool {
        (changedFraction(frame, from: first) ?? 0) > movingFraction
    }

    /// `image` drawn into RGBA bytes of `width` × `height`.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: Writing

    static func scene(frame: Frame?, clearColor: String, camera: (eye: String, center: String, up: String)?,
                      objects: [Any]) -> [String: Any] {
        var general: [String: Any] = [
            "ambientcolor": "0.3 0.3 0.3", "skylightcolor": "0.3 0.3 0.3", "bloom": false,
            "clearcolor": clearColor, "clearenabled": true, "camerapreview": true,
        ]
        if let frame {
            general["orthogonalprojection"] = ["width": frame.width, "height": frame.height]
        } else {
            general["fov"] = 50
            general["nearz"] = 0.01
            general["farz"] = 10000
        }
        let view = camera ?? (eye: "0 0 0", center: "0 0 -1", up: "0 1 0")
        return [
            "camera": ["eye": view.eye, "center": view.center, "up": view.up],
            "general": general,
            "objects": objects,
        ]
    }

    static func sceneFiles(_ scene: [String: Any]) throws -> [String: Data] {
        [
            WEProjectFile.fileName: try json(["file": "scene.json", "title": "Editor preview", "type": "scene"]),
            "scene.json": try json(scene),
        ]
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
