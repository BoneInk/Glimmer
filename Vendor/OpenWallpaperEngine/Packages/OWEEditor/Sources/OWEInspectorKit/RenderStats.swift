import Foundation

/// A frame's numbers as the stats overlay shows them (WE's editor `renderStats`): the app's
/// renderer counts them, the overlay lists them with WE's rules for which show and which warn.
public struct RenderStats: Equatable, Sendable {
    public var framesPerSecond = 0
    public var gpuMilliseconds = 0.0
    public var drawCalls = 0
    public var primitives = 0
    public var shaderPrograms = 0
    public var renderTargetChanges = 0
    public var framebufferCopies = 0
    public var textureBytes = 0
    public var particleCount = 0
    public var particleBytes = 0
    public var particleMilliseconds = 0.0
    public var scriptMilliseconds = 0.0
    public var lightCount = 0
    public var videoTextureCount = 0
    public var clippingMaskPasses = 0
    public var expensiveEffects = 0
    public var veryExpensiveEffects = 0

    public init() {}

    public static func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

    /// One line of the overlay.
    public struct Row: Hashable, Sendable, Identifiable {
        public enum ID: String, Sendable, CaseIterable {
            case fps, gpu, textureMemory, lights, scriptTime, expensive, veryExpensive, drawCalls, primitives
            case programs, framebufferCopies, particleCount, particleMemory, particleTime, renderTargetChanges
            case videoTextures, clippingMasks
        }

        public let id: ID
        public let title: String
        public let value: String
        /// Over WE's limit: shown in red, and the only rows the Auto mode shows.
        public let isWarning: Bool
    }

    /// The rows in WE's order, the ones WE hides while zero left out (lights, video textures,
    /// clipping masks, expensive effects), each warning past WE's limit (`editorSceneStatsOverlay`).
    public var rows: [Row] {
        var rows: [Row] = []
        func add(_ id: Row.ID, _ title: String, _ value: String, warns: Bool = false) {
            rows.append(Row(id: id, title: title, value: value, isWarning: warns))
        }
        let textureMegabytes = Self.megabytes(textureBytes)
        add(.fps, S("FPS"), String(framesPerSecond))
        add(.gpu, S("GPU time (ms)"), Self.decimal(gpuMilliseconds, 3))
        add(.textureMemory, S("Active texture memory (MB)"), Self.decimal(textureMegabytes, 0), warns: textureMegabytes > 400)
        if lightCount > 0 { add(.lights, S("Dynamic light count"), String(lightCount), warns: lightCount > 6) }
        add(.scriptTime, S("Script execution time (ms)"), Self.decimal(scriptMilliseconds, 3), warns: scriptMilliseconds > 10)
        if expensiveEffects > 0 {
            let warns = expensiveEffects > 10
            add(.expensive, warns ? S("Too many expensive effects used") : S("Expensive effects used"),
                String(expensiveEffects), warns: warns)
        }
        if veryExpensiveEffects > 0 {
            let warns = veryExpensiveEffects > 1
            add(.veryExpensive, warns ? S("Too many very expensive effects used") : S("Very expensive effects used"),
                String(veryExpensiveEffects), warns: warns)
        }
        add(.drawCalls, S("Draw calls"), String(drawCalls))
        add(.primitives, S("Primitives drawn"), String(primitives))
        add(.programs, S("Shader program count"), String(shaderPrograms), warns: shaderPrograms > 100)
        add(.framebufferCopies, S("Framebuffer copies"), String(framebufferCopies))
        add(.particleCount, S("Particle count"), String(particleCount))
        add(.particleMemory, S("Particle memory (MB)"), Self.decimal(Self.megabytes(particleBytes), 2))
        add(.particleTime, S("Particle simulation time (ms)"), Self.decimal(particleMilliseconds, 3),
            warns: particleMilliseconds > 10)
        add(.renderTargetChanges, S("Render target changes"), String(renderTargetChanges), warns: renderTargetChanges > 100)
        if videoTextureCount > 0 {
            add(.videoTextures, S("Video texture count"), String(videoTextureCount), warns: videoTextureCount > 3)
        }
        if clippingMaskPasses > 0 {
            add(.clippingMasks, S("Clipping mask passes"), String(clippingMaskPasses), warns: clippingMaskPasses > 5)
        }
        return rows
    }

    /// The compact readout of Scene Edit / Export: frames per second, GPU time, texture memory.
    public var summary: String {
        let gpu = Self.decimal(gpuMilliseconds, 1), memory = Self.decimal(Self.megabytes(textureBytes), 0)
        return S("\(framesPerSecond) FPS · GPU \(gpu) ms · \(memory) MB")
    }

    static func decimal(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}

/// The stats overlay's text, from this module's catalog (`Resources/Stats.xcstrings`).
let S = EditorText(table: "Stats", bundle: .module)
