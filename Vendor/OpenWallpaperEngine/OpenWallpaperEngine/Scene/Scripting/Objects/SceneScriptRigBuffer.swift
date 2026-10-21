import Foundation
import simd

/// A Puppet Warp image's rig as scripts see it at load (docs/models-plan.md §2.8, §4.3 P2): its
/// bones, clips, authored animation layers (in the order the animator plays them) and attachment
/// points. `SceneScriptSceneDescriber` makes it; the object store places it with the layer and
/// hands the record to `objects-layers.js`.
struct SceneScriptRigDescription: Equatable {
    struct Bone: Equatable {
        var name: String
        /// −1 for a root.
        var parent: Int
        /// The bind pose, local and in the rig's model space (column-major): what scripts read
        /// until the renderer's first frame.
        var local: [Float] = SceneScriptRigLayout.components(matrix_identity_float4x4)
        var model: [Float] = SceneScriptRigLayout.components(matrix_identity_float4x4)
    }

    struct Clip: Equatable {
        var id: UInt64
        var name: String
        var fps: Float
        var frameCount: Int
        var duration: Float
    }

    struct Layer: Equatable {
        var key: Int
        var name: String
        var clip: Int
        var additive: Bool
        var rate: Float = 1
        var blend: Float = 1
        var visible = true
        /// Its index in the object's `animationlayers`, where its timelines are found
        /// (`IAnimationLayer.getAnimation`).
        var authored: Int?
    }

    struct Attachment: Equatable {
        var name: String
        var bone: Int
        /// Column-major, the `.mdl`'s memory.
        var matrix: [Float]
    }

    var bones: [Bone]
    var clips: [Clip]
    var layers: [Layer]
    var attachments: [Attachment]
    /// The first mesh's blend-shape (`MDMP` target) names, in index order (`getBlendShapeIndex`).
    var blendShapes: [String] = []

    /// The JS record's `rig` (with the buffer slot the store gave it).
    func javaScriptRecord(slot: Int) -> [String: Any] {
        [
            "slot": slot,
            "bones": bones.map { ["name": $0.name, "parent": $0.parent] as [String: Any] },
            "clips": clips.map {
                ["id": Double($0.id), "name": $0.name, "fps": $0.fps, "frameCount": $0.frameCount,
                 "duration": $0.duration] as [String: Any]
            },
            "layers": layers.map {
                ["key": $0.key, "name": $0.name, "clip": $0.clip, "additive": $0.additive, "authored": $0.authored ?? -1]
                    as [String: Any]
            },
            "attachments": attachments.map { ["name": $0.name, "bone": $0.bone, "matrix": $0.matrix] as [String: Any] },
            "blendShapes": blendShapes,
        ]
    }
}

extension SceneScriptRigDescription {
    /// The rig of `model` played by the image's `animationlayers`; nil without a skeleton.
    init?(model: MDLModel, layers authored: [WEAnimationLayer]) {
        guard let skeleton = model.skeleton, !skeleton.bones.isEmpty else { return nil }
        let clips = model.animations ?? []
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: authored)
        let bind = SceneSkeleton(skeleton)
        bones = skeleton.bones.enumerated().map { index, bone in
            Bone(name: bone.name, parent: bone.parentIndex.flatMap { $0 < index ? $0 : nil } ?? -1,
                 local: SceneScriptRigLayout.components(bind.bindLocal[index]),
                 model: SceneScriptRigLayout.components(bind.bindWorld[index]))
        }
        self.clips = clips.map {
            Clip(id: $0.id, name: $0.name, fps: $0.fps, frameCount: Int($0.frames), duration: $0.duration)
        }
        layers = animator.stack.layers.map {
            Layer(key: $0.key, name: $0.name, clip: $0.clip, additive: $0.additive, rate: $0.rate, blend: $0.blend,
                  visible: $0.visible, authored: $0.authored)
        }
        attachments = (model.attachments ?? []).map { attachment in
            let m = attachment.matrix
            return Attachment(name: attachment.name, bone: Int(attachment.bone),
                              matrix: [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] })
        }
        blendShapes = model.morphTargets?.first { $0.mesh == 0 }?.targets.map(\.name) ?? []
    }
}

/// The rig buffer's layout: one slot per placed rig. The mirror writes each rig's state as the
/// renderer left it before every script frame (`SceneScriptRigFeedback`); `objects-layers.js`
/// reads it, and applies its own calls to it in call order so a script reads back what it did.
enum SceneScriptRigLayout {
    static let maximumBones = 128
    static let maximumLayers = 32
    static let maximumBlendShapes = 256
    // Header.
    static let boneCount = 0
    static let layerCount = 1
    static let blendShapeCount = 2
    // Layers, in evaluation order, from `layers`, `layerStride` floats each.
    static let layers = 4
    static let layerStride = 12
    static let layerKey = 0
    static let layerClip = 1
    static let layerTime = 2
    static let layerFrame = 3
    /// `flagPaused`, `flagFinished`, `flagBackwards`.
    static let layerFlags = 4
    static let layerRate = 5
    static let layerBlend = 6
    static let layerVisible = 7
    static let layerAdditive = 8
    /// How many times the clip has ended (`addEndedCallback`), counted by the mirror.
    static let layerEnded = 9
    static let flagPaused = 1
    static let flagFinished = 2
    static let flagBackwards = 4
    // Bones, `boneStride` floats each: the local matrix, then the world matrix (column-major).
    static let bones = layers + maximumLayers * layerStride
    static let boneStride = 32
    static let boneWorld = 16
    // The first mesh's blend-shape weights, one float each.
    static let blendShapes = bones + maximumBones * boneStride
    static let stride = blendShapes + maximumBlendShapes

    static var javaScriptObject: [String: Int] {
        ["boneCount": boneCount, "layerCount": layerCount, "layers": layers, "layerStride": layerStride,
         "layerKey": layerKey, "layerClip": layerClip, "layerTime": layerTime, "layerFrame": layerFrame,
         "layerFlags": layerFlags, "layerRate": layerRate, "layerBlend": layerBlend, "layerVisible": layerVisible,
         "layerAdditive": layerAdditive, "layerEnded": layerEnded, "flagPaused": flagPaused,
         "flagFinished": flagFinished, "flagBackwards": flagBackwards, "bones": bones, "boneStride": boneStride,
         "boneWorld": boneWorld, "maximumLayers": maximumLayers, "maximumBones": maximumBones,
         "blendShapeCount": blendShapeCount, "blendShapes": blendShapes, "maximumBlendShapes": maximumBlendShapes]
    }

    /// The rig as placed: its authored layers at time 0 and its bind pose (in model space, the
    /// object's world not yet known).
    static func write(_ rig: SceneScriptRigDescription, into buffer: SceneScriptSlotBuffer, slot: Int) {
        buffer.write(Array(repeating: 0, count: stride), slot: slot, offset: 0)
        let layers = rig.layers.prefix(maximumLayers)
        buffer[slot, layerCount] = Float(layers.count)
        for (index, layer) in layers.enumerated() {
            buffer.write([Float(layer.key), Float(layer.clip), 0, 0, 0, layer.rate, layer.blend, layer.visible ? 1 : 0,
                          layer.additive ? 1 : 0, 0], slot: slot, offset: self.layers + index * layerStride)
        }
        let bones = rig.bones.prefix(maximumBones)
        buffer[slot, boneCount] = Float(bones.count)
        for (index, bone) in bones.enumerated() {
            buffer.write(bone.local, slot: slot, offset: self.bones + index * boneStride)
            buffer.write(bone.model, slot: slot, offset: self.bones + index * boneStride + boneWorld)
        }
        buffer[slot, blendShapeCount] = Float(min(rig.blendShapes.count, maximumBlendShapes))
        buffer.dirty[slot] = 0
    }

    /// Writes `feedback` into `slot` of `buffer`; `ended` holds each layer's ended count.
    static func write(_ feedback: SceneScriptRigFeedback, into buffer: SceneScriptSlotBuffer, slot: Int,
                      ended: [Int: Int]) {
        let layerCount = min(feedback.layers.count, maximumLayers)
        buffer[slot, self.layerCount] = Float(layerCount)
        for (index, layer) in feedback.layers.prefix(layerCount).enumerated() {
            let base = layers + index * layerStride
            var flags = 0
            if layer.flags.contains(.paused) { flags |= flagPaused }
            if layer.flags.contains(.finished) { flags |= flagFinished }
            if layer.flags.contains(.reversed) { flags |= flagBackwards }
            buffer.write([Float(layer.key), Float(layer.clip), layer.time, layer.frame, Float(flags), layer.rate,
                          layer.blend, layer.visible ? 1 : 0, layer.additive ? 1 : 0, Float(ended[layer.key] ?? 0)],
                         slot: slot, offset: base)
        }
        let boneCount = min(feedback.locals.count, feedback.worlds.count, maximumBones)
        buffer[slot, self.boneCount] = Float(boneCount)
        for bone in 0..<boneCount {
            let base = bones + bone * boneStride
            buffer.write(components(feedback.locals[bone]), slot: slot, offset: base)
            buffer.write(components(feedback.worlds[bone]), slot: slot, offset: base + boneWorld)
        }
        buffer.write(Array(feedback.blendShapeWeights.prefix(maximumBlendShapes)), slot: slot, offset: blendShapes)
    }

    static func components(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ values: ArraySlice<Float>) -> simd_float4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        let v = Array(values)
        return simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                       SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
    }

    /// A rig opcode's numbers and strings as a command; nil when malformed.
    static func decode(_ opcode: SceneScriptCommandRing.Opcode, numbers: [Float], strings: [String]) -> SceneScriptRigCommand? {
        func key(_ value: Float?) -> Int? { value.flatMap { SceneScriptNumber.index($0, in: 0...Int(Int32.max)) } }
        func bone(_ value: Float?) -> Int? { value.flatMap { SceneScriptNumber.index($0, in: 0...(maximumBones - 1)) } }
        switch opcode {
        case .rigLayerCreate:
            guard numbers.count == 10, let key = key(numbers[0]), let clip = strings.first else { return nil }
            var config = SceneScriptRigCommand.LayerConfig()
            config.name = strings.count > 1 ? strings[1] : nil
            config.additive = numbers[2] != 0
            config.blendIn = numbers[3] != 0
            config.blendOut = numbers[4] != 0
            config.autosort = numbers[5] != 0
            config.blendTime = numbers[6]
            config.rate = numbers[7]
            config.blend = numbers[8]
            config.visible = numbers[9] != 0
            return .createLayer(key: key, clip: clip, config: config, singlePlay: numbers[1] != 0)
        case .rigLayerDestroy:
            return key(numbers.first).map { .destroyLayer(key: $0) }
        case .rigLayerSet:
            guard numbers.count == 3, let key = key(numbers[0]),
                  let field = SceneScriptNumber.index(numbers[1], in: 0...2).flatMap(SceneScriptRigCommand.LayerField.init)
            else { return nil }
            return .setLayer(key: key, field: field, value: numbers[2])
        case .rigLayerPlayback:
            guard numbers.count >= 2, let key = key(numbers[0]),
                  let action = SceneScriptNumber.index(numbers[1], in: 0...3) else { return nil }
            switch action {
            case 0: return .playback(key: key, .play)
            case 1: return .playback(key: key, .pause)
            case 2: return .playback(key: key, .stop)
            default:
                guard numbers.count == 3, numbers[2].isFinite else { return nil }
                return .playback(key: key, .setFrame(numbers[2]))
            }
        case .rigBoneLocal, .rigBoneWorld:
            guard numbers.count == 17, let bone = bone(numbers[0]), let matrix = matrix(numbers[1...]) else { return nil }
            return opcode == .rigBoneLocal ? .setLocal(bone: bone, matrix: matrix) : .setWorld(bone: bone, matrix: matrix)
        case .rigBlendShape:
            guard numbers.count == 2, numbers[1].isFinite,
                  let index = SceneScriptNumber.index(numbers[0], in: 0...Int(UInt16.max)) else { return nil }
            return .setBlendShape(index: index, weight: numbers[1])
        case .rigBonePhysicsImpulse:
            guard numbers.count == 7, numbers.allSatisfy(\.isFinite), let bone = bone(numbers[0]) else { return nil }
            return .physicsImpulse(bone: bone, linear: SIMD3(numbers[1], numbers[2], numbers[3]),
                                   angularDegrees: SIMD3(numbers[4], numbers[5], numbers[6]))
        case .rigBonePhysicsReset:
            return bone(numbers.first).map { .resetPhysics(bone: $0) }
        default:
            return nil
        }
    }
}

/// The mirror's side of the rig buffers: which slot each rig object has and how often each of
/// its layers has ended, written into the buffer before every script frame. Script thread only.
final class SceneScriptRigMirror {
    private var endedCounts: [Int: [Int: Int]] = [:]

    /// Writes every rig's feedback (by object id) into its slot (`rigSlot(objectID)`).
    func publish(_ rigs: [Int: SceneScriptRigFeedback], into buffer: SceneScriptSlotBuffer, rigSlot: (Int) -> Int?) {
        for (id, feedback) in rigs {
            guard let slot = rigSlot(id) else { continue }
            var counts = endedCounts[id] ?? [:]
            for key in feedback.ended { counts[key, default: 0] += 1 }
            endedCounts[id] = counts
            SceneScriptRigLayout.write(feedback, into: buffer, slot: slot, ended: counts)
        }
    }

    func forget(objectID: Int) { endedCounts[objectID] = nil }
}
