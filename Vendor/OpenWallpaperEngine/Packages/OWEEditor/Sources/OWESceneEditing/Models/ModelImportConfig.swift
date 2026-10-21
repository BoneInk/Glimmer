import Foundation
import simd

/// The configuration beside an imported model's source (`models/<name>/<name>.json` next to
/// `<name>.fbx` or `.obj`), which WE's resource compiler reads with the source to write the
/// `.mdl` (`resourcecompiler64.exe -mdl`), and which WE's Model Editor edits
/// (docs/model-import.md).
///
/// The layout is WE 2.8.0.42's (capture 546; `resourcecompiler64.exe` reads the lists from
/// `editor`, 0x14009f3a9…, and an event's keys at 0x1400a28dd):
///
/// ```
/// { "normals": true, "tangentspace": true, "skinning": true, "seconduvchannel": …, "skins": […],
///   "editor": { "animationmapping": {"<animation>": id},
///               "additionalfiles": ["<file>"],
///               "clips": [{"animation": "<animation>", "start", "end", "frameoffset", "id",
///                          "matchloop", "motionflags", "name", "rootmotion": "<bone>"}],
///               "events": [{"id", "name", "frame", "clip": id | "animation": "<animation>"}],
///               "attachments": [{"bone", "id", "name", "transform": "<16 numbers>"}],
///               "constraints": [{"bone", "config": {Puppet Warp's constraint keys}}] } }
/// ```
///
/// The reader also takes the shape this project wrote before (beta 7: `clips`, `events`,
/// `attachments` and a `constraints` object by bone at the top level, clips naming their
/// animation by id, `motionflags` as the flags' second byte); the writer writes WE's. Keys this
/// type doesn't know are kept as they were, at the top level and in `editor`.
public struct ModelImportConfig: Sendable, Equatable {
    /// A clip cut from an animation (Model Editor › Animation › Add Clip): an `MDLA` record with
    /// the clip record (flag 0x1) after it.
    public struct Clip: Sendable, Equatable, Identifiable {
        public var id: UInt64
        public var name: String
        /// The id of the animation it is cut from (`animationMapping`'s, else the compiler's).
        public var animation: UInt64
        public var start: Int
        public var end: Int
        public var frameOffset: Int
        /// "Match loop" (flag 0x400), on by default in WE's editor.
        public var matchLoop: Bool
        /// The Motion root bone's name; empty for None.
        public var rootMotion: String
        /// The root motion axes as the clip record's flags: 0x800, 0x1000 and 0x2000 position x,
        /// y and z, 0x8000 rotation about y (docs/models-plan.md §2.8). WE's configuration keeps
        /// the flags as they are (`motionflags` 43008 = 0xA800: x, z and yaw, what Add Clip sets).
        public var motionFlags: UInt32
        /// The clip's frame rate; nil keeps the source animation's. Not WE's (its clips keep
        /// the animation's rate).
        public var fps: Float?
        /// `MDLA`'s mode: "" (WE's: no mode, which plays as a loop), "mirror" or "single". Only
        /// the empty mode is WE's.
        public var mode: String

        public init(id: UInt64, name: String, animation: UInt64, start: Int, end: Int, frameOffset: Int = 0, matchLoop: Bool = true,
                    rootMotion: String = "", motionFlags: UInt32 = 0, fps: Float? = nil, mode: String = "") {
            self.id = id
            self.name = name
            self.animation = animation
            self.start = start
            self.end = end
            self.frameOffset = frameOffset
            self.matchLoop = matchLoop
            self.rootMotion = rootMotion
            self.motionFlags = motionFlags
            self.fps = fps
            self.mode = mode
        }

        public static let positionX: UInt32 = 0x800
        public static let positionY: UInt32 = 0x1000
        public static let positionZ: UInt32 = 0x2000
        public static let rotationY: UInt32 = 0x8000
        /// What WE's Add Clip writes (capture 546): position x and z and rotation y.
        public static let defaultMotionFlags: UInt32 = positionX | positionZ | rotationY
    }

    /// A named frame of an animation or clip (`MDLA`'s events, which a scene's
    /// `animationEvent` scripts receive).
    public struct Event: Sendable, Equatable, Identifiable {
        public var id: UInt64
        public var name: String
        public var frame: Float
        /// The animation or clip it belongs to.
        public var animation: UInt64

        public init(id: UInt64, name: String, frame: Float, animation: UInt64) {
            self.id = id
            self.name = name
            self.frame = frame
            self.animation = animation
        }
    }

    /// A named point on a bone (`MDAT0001`), which a scene object's `attachment` names.
    public struct Attachment: Sendable, Equatable, Identifiable {
        public var id: UInt64
        public var name: String
        public var bone: String
        public var origin: SIMD3<Float>
        /// Radians, as WE's scene vectors.
        public var angles: SIMD3<Float>

        public init(id: UInt64, name: String, bone: String, origin: SIMD3<Float> = .zero, angles: SIMD3<Float> = .zero) {
            self.id = id
            self.name = name
            self.bone = bone
            self.origin = origin
            self.angles = angles
        }

        /// From WE's `transform` (the `MDAT` matrix's 16 numbers in its memory order).
        init(id: UInt64, name: String, bone: String, transform: simd_float4x4) {
            let basis = simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                      SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                      SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
            self.init(id: id, name: name, bone: bone,
                      origin: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z), angles: PuppetMath.angles(basis))
        }

        /// The `MDAT` offset matrix: `T · R`, R = Rz·Ry·Rx.
        public var matrix: simd_float4x4 {
            PuppetMath.matrix(translation: origin, euler: angles, scale: SIMD3(repeating: 1))
        }
    }

    public var normals: Bool
    public var tangentSpace: Bool
    public var secondUVChannel: Bool
    /// `skinning`: WE's compiler writes the blend indices and weights (and so the skeleton)
    /// only when it is true (0x1400207bf…0x140020c86). Nil (a configuration without the key, as
    /// this project wrote them before) skins whatever the source skins; the importer writes true
    /// for a skinned source.
    public var skinning: Bool?
    /// `editor.animationmapping`: the ids of the source's animations by name, which a scene's
    /// animation layers name. WE's are its editor's object counter (41 and 42 in capture 546);
    /// an animation without one gets its position (1, 2, …).
    public var animationMapping: [String: UInt64]
    /// More source files whose animations the model gets (Add FBX File), by name beside the source.
    public var additionalFiles: [String]
    public var clips: [Clip]
    public var events: [Event]
    public var attachments: [Attachment]
    /// Bone physics by bone name, compiled into the bones' properties JSON as WE compiles them.
    public var constraints: [String: PuppetBonePhysics]
    /// Each bone's constraint settings as the file has them (WE's whole key set: the IK keys,
    /// `layout`, `preset`, …), which `constraints` edits and the compiler passes through.
    public var constraintSettings: [String: [String: SceneJSONValue]] = [:]
    /// Materials edited in the Model Editor by source material name: the material file the
    /// model names instead of the import's own. Not WE's: WE's editor changes the material file
    /// in place, which the edits' files never do (`materials`).
    public var materials: [String: String] = [:]
    /// Keys this type doesn't read, kept as they were.
    public var other: [String: SceneJSONValue]
    /// `editor` keys this type doesn't read.
    public var editorOther: [String: SceneJSONValue] = [:]

    /// What WE's importer writes for a new FBX or OBJ: normals and tangents on.
    public init(normals: Bool = true, tangentSpace: Bool = true, secondUVChannel: Bool = false, skinning: Bool? = nil,
                animationMapping: [String: UInt64] = [:], additionalFiles: [String] = [],
                clips: [Clip] = [], events: [Event] = [], attachments: [Attachment] = [],
                constraints: [String: PuppetBonePhysics] = [:], other: [String: SceneJSONValue] = [:]) {
        self.normals = normals
        self.tangentSpace = tangentSpace
        self.secondUVChannel = secondUVChannel
        self.skinning = skinning
        self.animationMapping = animationMapping
        self.additionalFiles = additionalFiles
        self.clips = clips
        self.events = events
        self.attachments = attachments
        self.constraints = constraints
        self.other = other
    }

    /// A model without a configuration file: WE's compiler then writes neither normals nor
    /// tangents (the default projects' `techno/glow.mdl`, format 0x9).
    public static let missing = ModelImportConfig(normals: false, tangentSpace: false)

    /// The next id no animation, clip, event or attachment uses.
    public func nextID(after animations: Int) -> UInt64 {
        let used = clips.map(\.id) + events.map(\.id) + attachments.map(\.id) + Array(animationMapping.values)
        return max(used.max() ?? 0, UInt64(animations), 1000) + 1
    }

    /// The ids of the source's animations, `names` in order: the mapping's, else the
    /// animation's position (1, 2, …) or the next id after it no other animation has.
    public func animationIDs(_ names: [String]) -> [UInt64] {
        let mapped = Set(animationMapping.values)
        var used = Set<UInt64>()
        return names.enumerated().map { index, name in
            if let id = animationMapping[name], used.insert(id).inserted { return id }
            var id = UInt64(index + 1)
            while used.contains(id) || mapped.contains(id) { id += 1 }
            used.insert(id)
            return id
        }
    }

    /// The configuration as the importer saves it with the model compiled from it: `skinning`
    /// on for a skinned model, and every source animation in `animationmapping` with its id.
    public func completed(with output: ModelCompiler.Output) -> ModelImportConfig {
        var config = self
        if config.skinning == nil, !output.bones.isEmpty { config.skinning = true }
        for animation in output.animations where !animation.isClip && config.animationMapping[animation.name] == nil {
            config.animationMapping[animation.name] = animation.id
        }
        return config
    }

    // MARK: JSON

    static let knownKeys: Set<String> = ["normals", "tangentspace", "seconduvchannel", "skinning", "editor", "additionalfiles", "clips",
                                         "events", "attachments", "constraints", "materials"]
    static let editorKeys: Set<String> = ["animationmapping", "additionalfiles", "clips", "events", "attachments", "constraints"]

    public init(json data: Data) throws {
        guard case .object(let root)? = SceneJSONValue(any: try JSONSerialization.jsonObject(with: data)) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        self.init(object: root)
    }

    public init(object root: [String: SceneJSONValue]) {
        self.init(normals: root["normals"]?.boolValue ?? false, tangentSpace: root["tangentspace"]?.boolValue ?? false,
                  secondUVChannel: root["seconduvchannel"]?.boolValue ?? false, skinning: root["skinning"]?.boolValue)
        var editor: [String: SceneJSONValue] = [:]
        if case .object(let object)? = root["editor"] { editor = object }
        if case .object(let mapping)? = editor["animationmapping"] {
            animationMapping = mapping.compactMapValues(\.idValue)
        }
        // WE's records are in `editor`; this project's earlier ones at the top level.
        let legacy = root["editor"] == nil
        let lists = legacy ? root : editor
        additionalFiles = (editor["additionalfiles"] ?? root["additionalfiles"])?.arrayValue?.compactMap(\.stringValue) ?? []
        for case .object(let o) in lists["clips"]?.arrayValue ?? [] {
            let flags = UInt32(clamping: o["motionflags"]?.intValue ?? 0)
            clips.append(Clip(id: o["id"]?.idValue ?? 0, name: o["name"]?.stringValue ?? "", animation: animationID(o["animation"]),
                              start: o["start"]?.intValue ?? 0, end: o["end"]?.intValue ?? 0, frameOffset: o["frameoffset"]?.intValue ?? 0,
                              matchLoop: o["matchloop"]?.boolValue ?? true, rootMotion: o["rootmotion"]?.stringValue ?? "",
                              motionFlags: legacy ? (flags & 0xFF) << 8 : flags, fps: o["fps"]?.numberValue.map(Float.init),
                              mode: o["mode"]?.stringValue ?? ""))
        }
        for case .object(let o) in lists["events"]?.arrayValue ?? [] {
            events.append(Event(id: o["id"]?.idValue ?? 0, name: o["name"]?.stringValue ?? "", frame: Float(o["frame"]?.numberValue ?? 0),
                                animation: o["clip"]?.idValue ?? animationID(o["animation"])))
        }
        for case .object(let o) in lists["attachments"]?.arrayValue ?? [] {
            let id = o["id"]?.idValue ?? 0, name = o["name"]?.stringValue ?? "", bone = o["bone"]?.stringValue ?? ""
            if let transform = Self.matrix(o["transform"]) {
                attachments.append(Attachment(id: id, name: name, bone: bone, transform: transform))
            } else {
                attachments.append(Attachment(id: id, name: name, bone: bone, origin: Self.vector(o["origin"]) ?? .zero,
                                              angles: Self.vector(o["angles"]) ?? .zero))
            }
        }
        switch lists["constraints"] {
        case .object(let bones)?:  // this project's earlier shape: {bone: compiled keys}
            for (bone, value) in bones {
                if case .object(let settings) = value { addConstraint(bone, settings) }
            }
        case .array(let list)?:
            for case .object(let entry) in list {
                if let bone = entry["bone"]?.stringValue, case .object(let settings)? = entry["config"] { addConstraint(bone, settings) }
            }
        default:
            break
        }
        if case .object(let materials)? = root["materials"] {
            self.materials = materials.compactMapValues(\.stringValue)
        }
        other = root.filter { !Self.knownKeys.contains($0.key) }
        editorOther = editor.filter { !Self.editorKeys.contains($0.key) }
    }

    private mutating func addConstraint(_ bone: String, _ settings: [String: SceneJSONValue]) {
        constraintSettings[bone] = settings
        if let physics = PuppetBonePhysics(properties: settings) { constraints[bone] = physics }
    }

    /// A clip's or event's animation: WE's name (an unmapped one gets the next free id, which
    /// the compiler then gives it), or this project's earlier id.
    private mutating func animationID(_ value: SceneJSONValue?) -> UInt64 {
        guard case .string(let name)? = value else { return value?.idValue ?? 0 }
        if let id = animationMapping[name] { return id }
        let id = max(animationMapping.values.max() ?? 0, 1000) + 1
        animationMapping[name] = id
        return id
    }

    public var object: [String: SceneJSONValue] {
        var root = other
        root["normals"] = .bool(normals)
        root["tangentspace"] = .bool(tangentSpace)
        if secondUVChannel { root["seconduvchannel"] = .bool(true) }
        if let skinning { root["skinning"] = .bool(skinning) }
        if !materials.isEmpty { root["materials"] = .object(materials.mapValues { .string($0) }) }
        var editor = editorOther
        let names = Dictionary(animationMapping.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        func animation(_ id: UInt64) -> SceneJSONValue { names[id].map { .string($0) } ?? .number(Double(id)) }
        if !animationMapping.isEmpty { editor["animationmapping"] = .object(animationMapping.mapValues { .number(Double($0)) }) }
        if !additionalFiles.isEmpty { editor["additionalfiles"] = .array(additionalFiles.map { .string($0) }) }
        if !clips.isEmpty {
            editor["clips"] = .array(clips.map { clip in
                var o: [String: SceneJSONValue] = [
                    "id": .number(Double(clip.id)), "name": .string(clip.name), "animation": animation(clip.animation),
                    "start": .number(Double(clip.start)), "end": .number(Double(clip.end)),
                    "frameoffset": .number(Double(clip.frameOffset)), "matchloop": .bool(clip.matchLoop),
                    "rootmotion": .string(clip.rootMotion), "motionflags": .number(Double(clip.motionFlags)),
                ]
                if let fps = clip.fps { o["fps"] = .number(Double(fps)) }
                if !clip.mode.isEmpty { o["mode"] = .string(clip.mode) }
                return .object(o)
            })
        }
        if !events.isEmpty {
            let clipIDs = Set(clips.map(\.id))
            editor["events"] = .array(events.map { event in
                var o: [String: SceneJSONValue] = ["id": .number(Double(event.id)), "name": .string(event.name),
                                                   "frame": .number(Double(event.frame))]
                if clipIDs.contains(event.animation) {
                    o["clip"] = .number(Double(event.animation))
                } else {
                    o["animation"] = animation(event.animation)
                }
                return .object(o)
            })
        }
        if !attachments.isEmpty {
            editor["attachments"] = .array(attachments.map {
                .object(["id": .number(Double($0.id)), "name": .string($0.name), "bone": .string($0.bone),
                         "transform": .string(Self.matrixString($0.matrix))])
            })
        }
        let bones = constraintBones
        if !bones.isEmpty {
            editor["constraints"] = .array(bones.map { bone in
                .object(["bone": .string(bone), "config": .object(constraintConfig(bone))])
            })
        }
        if !editor.isEmpty { root["editor"] = .object(editor) }
        return root
    }

    /// The bones with a constraint: the simulated ones, and those whose settings simulate
    /// nothing this type edits (IK), sorted.
    public var constraintBones: [String] {
        Set(constraints.keys).union(constraintSettings.filter { PuppetBonePhysics(properties: $0.value) == nil }.keys).sorted()
    }

    /// A bone's constraint settings as WE's Model Editor saves them: its defaults for a 3D bone
    /// (`makeDefaultPhysicsConstraintSettings`), the settings the file had, and the physics as
    /// edited (without the compiled tip, which the compiler adds).
    public func constraintConfig(_ bone: String) -> [String: SceneJSONValue] {
        var config = Self.defaultConstraintSettings.merging(constraintSettings[bone] ?? [:]) { $1 }
        if let physics = constraints[bone] {
            // A setting the physics leave as they were keeps the file's text ("1 0 0").
            config.merge(physics.properties(childDistance: nil).filter { $0.key != "tp" }) { old, new in
                Self.sameSetting(old, new) ? old : new
            }
        }
        return config
    }

    /// The same value as WE reads it: numbers and vectors as floats.
    public static func sameSetting(_ a: SceneJSONValue, _ b: SceneJSONValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return Float(x) == Float(y)
        case (.string(let x), .string(let y)): return x == y || PuppetPhysicsConstraint.vector(x) == PuppetPhysicsConstraint.vector(y)
        default: return a == b
        }
    }

    /// `makeDefaultPhysicsConstraintSettings("simple", true)` in WE 2.8.0.42's `scripts.js`.
    public static let defaultConstraintSettings: [String: SceneJSONValue] = [
        "se": .bool(false), "rs": .number(200), "rf": .number(20), "ri": .number(30), "ts": .number(200), "tf": .number(20),
        "ti": .number(30), "re": .bool(false), "ge": .bool(false), "gd": .string("0 -1 0"), "m": .number(20), "s": .number(0),
        "a": .string("1 0 0"), "r": .bool(true), "rax": .bool(true), "ray": .bool(true), "raz": .bool(true), "t": .bool(false),
        "tax": .bool(true), "tay": .bool(true), "taz": .bool(true), "tm": .number(200), "la": .bool(false),
        "lamin": .string("0 0 -3.14159265358"), "lamax": .string("0 0 3.14159265358"), "lt": .bool(false), "ltmax": .number(100),
        "ik": .bool(false), "ikd": .number(2), "ikg": .bool(true), "ikr": .bool(true), "ikrd": .number(25), "ikce": .bool(false),
        "ikrmin": .number(0), "ikrmax": .number(Double.pi), "ikcp": .bool(false), "ikcpn": .number(1), "ikm": .string(""),
        "ikse": .bool(true), "ikfe": .bool(false), "layout": .string("simple"), "preset": .string("none"),
    ]

    /// The configuration as WE's files write JSON (tab-indented by WE; sorted keys here so the
    /// same edits always write the same bytes).
    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: SceneJSONValue.object(object).any, options: [.prettyPrinted, .sortedKeys])
    }

    static func vector(_ value: SceneJSONValue?) -> SIMD3<Float>? {
        guard case .string(let text)? = value else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
        return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : nil
    }

    static func matrix(_ value: SceneJSONValue?) -> simd_float4x4? {
        guard case .string(let text)? = value else { return nil }
        let p = text.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
        guard p.count == 16 else { return nil }
        return simd_float4x4(columns: (SIMD4(p[0], p[1], p[2], p[3]), SIMD4(p[4], p[5], p[6], p[7]),
                                       SIMD4(p[8], p[9], p[10], p[11]), SIMD4(p[12], p[13], p[14], p[15])))
    }

    /// WE's `transform`: the matrix's 16 numbers in memory order, whole numbers without a
    /// fraction ("1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1").
    static func matrixString(_ m: simd_float4x4) -> String {
        (0..<4).flatMap { column in (0..<4).map { m[column][$0] } }.map { value -> String in
            let v: Float = abs(value) < 1e-7 ? 0 : value
            return v == v.rounded() && abs(v) < 1e7 ? String(Int(v)) : v.description
        }.joined(separator: " ")
    }
}

extension SceneJSONValue {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? { numberValue.map { Int($0.rounded()) } }

    var idValue: UInt64? { numberValue.flatMap { $0 >= 0 ? UInt64($0.rounded()) : nil } }
}
