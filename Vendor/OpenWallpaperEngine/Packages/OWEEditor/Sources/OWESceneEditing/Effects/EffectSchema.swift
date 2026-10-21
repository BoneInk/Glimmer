import Foundation

/// What an effect lets the editor change, read from its material and shaders by the app
/// (`SceneEffectParameters`): its constants with their controls, its combos and its texture slots.
public struct EffectSchema: Hashable, Sendable {
    /// A uniform with a `material` key: a slider, a colour, a vector or a switch.
    public struct Parameter: Hashable, Sendable, Identifiable {
        /// The constant's key in `constantshadervalues`.
        public var key: String
        public var title: String
        public var defaultValue: [Double]
        public var minimum: Double
        public var maximum: Double
        public var isInteger: Bool
        public var isColor: Bool
        /// WE's linked vec2: one slider for both components while they are equal.
        public var isLinked: Bool
        /// `"position": true`: a point in the layer's UV (0…1, y down), which the canvas shows as a
        /// handle to drag.
        public var isPosition: Bool
        /// `"direction": true`: an angle in radians, shown as a dial.
        public var isDirection: Bool
        /// `"conversion": "rad2deg"`: radians stored, degrees shown.
        public var showsDegrees: Bool

        public var id: String { key }

        public init(key: String, title: String, defaultValue: [Double], minimum: Double = 0, maximum: Double = 1,
                    isInteger: Bool = false, isColor: Bool = false, isLinked: Bool = false,
                    isPosition: Bool = false, isDirection: Bool = false, showsDegrees: Bool = false) {
            self.key = key
            self.title = title
            self.defaultValue = defaultValue
            self.minimum = minimum
            self.maximum = maximum
            self.isInteger = isInteger
            self.isColor = isColor
            self.isLinked = isLinked
            self.isPosition = isPosition
            self.isDirection = isDirection
            self.showsDegrees = showsDegrees
        }

        /// The control WE's editor shows for it.
        public enum Control: Hashable, Sendable {
            /// An integer 0…1 shown as a checkbox.
            case toggle
            case slider
            case color
            /// Several components, each a slider.
            case vector(Int)
            /// A point on the layer: X and Y fields, dragged on the canvas.
            case position
            /// An angle: a dial with its value in degrees or radians.
            case direction
        }

        public var control: Control {
            if isColor { return .color }
            if isPosition, defaultValue.count == 2 { return .position }
            if isDirection, defaultValue.count == 1 { return .direction }
            if defaultValue.count > 1 { return .vector(defaultValue.count) }
            if isInteger, minimum == 0, maximum == 1 { return .toggle }
            return .slider
        }
    }

    /// A `// [COMBO]` switch: options, or on/off when it has none.
    public struct Combo: Hashable, Sendable, Identifiable {
        public struct Option: Hashable, Sendable {
            public var title: String
            public var value: Int
            /// The heading WE groups it under, if any.
            public var group: String?

            public init(title: String, value: Int, group: String? = nil) {
                self.title = title
                self.value = value
                self.group = group
            }
        }

        public var name: String
        public var title: String
        public var defaultValue: Int
        public var options: [Option]
        /// Other combos' values this one is shown for (WE's `require`).
        public var requirements: [String: Int]

        public var id: String { name }

        public init(name: String, title: String, defaultValue: Int, options: [Option] = [], requirements: [String: Int] = [:]) {
            self.name = name
            self.title = title
            self.defaultValue = defaultValue
            self.options = options
            self.requirements = requirements
        }
    }

    /// A sampler the editor shows: a texture to pick, or a mask to paint.
    public struct TextureSlot: Hashable, Sendable, Identifiable {
        /// `g_TextureN`'s N: its index in the pass's `textures`.
        public var slot: Int
        /// The effect's pass whose shader samples it (`effect.json`'s `passes` index, which the
        /// scene object's `passes` follow): 0 for most, 3 for Blur's mask.
        public var pass: Int
        /// That pass's material's name (`blur_combine` for `materials/effects/blur_combine.json`),
        /// which WE's editor names the pass's masks after (`masks/blur_combine_mask_<hash>`).
        public var materialName: String?
        public var title: String
        /// What fills it when nothing is set (`util/white`), if anything.
        public var defaultTexture: String?
        /// WE's `"mode": "opacitymask"` and other painted masks: the editor offers a brush.
        public var isMask: Bool
        /// The combo it switches on while bound (`MASK`).
        public var combo: String?
        /// The colour a new mask is painted from (`paintdefaultcolor`), 0…1 RGBA.
        public var paintDefault: [Double]?
        /// The sampler's `mode`, lowercased (`opacitymask`, `flowmask`, `depth`…), if it has one.
        public var mode: String?

        public var id: Int { pass * 1000 + slot }

        /// WE's grey mask (`"mode": "opacitymask"`): its red channel scales the effect, white
        /// showing it, so a depth map can serve as one. A flow mask's channels are directions.
        public var isOpacityMask: Bool { mode == Self.opacityMaskMode }

        public static let opacityMaskMode = "opacitymask"

        public init(slot: Int, title: String, defaultTexture: String? = nil, isMask: Bool = false, combo: String? = nil,
                    paintDefault: [Double]? = nil, mode: String? = nil, pass: Int = 0, materialName: String? = nil) {
            self.slot = slot
            self.pass = pass
            self.materialName = materialName
            self.title = title
            self.defaultTexture = defaultTexture
            self.isMask = isMask
            self.combo = combo
            self.paintDefault = paintDefault
            self.mode = mode
        }
    }

    public var parameters: [Parameter]
    public var combos: [Combo]
    public var textures: [TextureSlot]
    /// How many passes `effect.json` lists, which an added effect's scene object lists too.
    public var passCount: Int
    /// `effect.json`'s `gizmos`: the handles the canvas shows for the effect.
    public var gizmos: [EffectGizmo]

    public init(parameters: [Parameter] = [], combos: [Combo] = [], textures: [TextureSlot] = [], passCount: Int = 1,
                gizmos: [EffectGizmo] = []) {
        self.parameters = parameters
        self.combos = combos
        self.textures = textures
        self.passCount = passCount
        self.gizmos = gizmos
    }

    public func parameter(_ key: String) -> Parameter? {
        parameters.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Whether `combo` shows given the effect's current combo values (WE hides one whose
    /// requirements don't hold).
    public static func requirementsHold(_ combo: Combo, values: (String) -> Int) -> Bool {
        combo.requirements.allSatisfy { values($0.key) == $0.value }
    }
}
