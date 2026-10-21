import Foundation
import OWEControlProtocol
import OWEEditor
import OWESceneEditing

/// Puppet Warp edits, as the puppet editor makes them (`PuppetWorkspace`): a new rig for an image
/// layer, its bones, automatic weights, its animations and their keys, and the image's animation
/// layers with their blend weights. Each changes the layer's rig in the overlay
/// (`SceneEditSession.setPuppet`); bones, animations and animation layers are named by their
/// index, as `puppets_list` lists them. Angles are in degrees, positions in the picture's pixels
/// from its centre.
extension SceneEditOperations {
    static var puppetOperations: [String: Operation] {
        [
            "puppet_create": createPuppet,
            "puppet_discard_edits": { edit, context in
                let layer = try Self.imageLayer(edit, context)
                context.session.setPuppet(nil, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id))]
            },
            "puppet_add_bone": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let parent = try edit.int("parent")
                    if let parent { try Self.bone(parent, in: document) }
                    let name = document.uniqueBoneName(try edit.string("name") ?? "Bone")
                    let head = SIMD2(Float(try edit.requiredDouble("x")), Float(try edit.requiredDouble("y")))
                    let angle = Float((try edit.double("angle") ?? 0) * .pi / 180)
                    let index = document.addBone(named: name, parent: parent, head: head, angle: angle)
                    return ["bone": .number(Double(index))]
                }
            },
            "puppet_move_bone": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try edit.requiredInt("bone")
                    try Self.bone(index, in: document)
                    document.moveBone(index, toHead: SIMD2(Float(try edit.requiredDouble("x")), Float(try edit.requiredDouble("y"))))
                    return ["bone": .number(Double(index))]
                }
            },
            "puppet_rotate_bone": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try edit.requiredInt("bone")
                    try Self.bone(index, in: document)
                    document.rotateBone(index, toAngle: Float(try edit.requiredDouble("angle") * .pi / 180))
                    return ["bone": .number(Double(index))]
                }
            },
            "puppet_rename_bone": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try edit.requiredInt("bone")
                    try Self.bone(index, in: document)
                    let name = try edit.required("name").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { throw ControlError(.invalidParams, "name must not be empty.") }
                    if document.bones[index].name != name { document.bones[index].name = document.uniqueBoneName(name) }
                    return ["bone": .number(Double(index)), "name": .string(document.bones[index].name)]
                }
            },
            "puppet_reparent_bone": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try edit.requiredInt("bone")
                    try Self.bone(index, in: document)
                    let parent = try edit.int("parent")
                    if let parent { try Self.bone(parent, in: document) }
                    let name = document.bones[index].name
                    guard document.reparent(index, to: parent) else {
                        throw ControlError(.refused, "Bone \(index) can't go under \(parent.map(String.init) ?? "nothing"): not under itself or a bone under it.")
                    }
                    return ["bone": .number(Double(document.bones.firstIndex { $0.name == name } ?? index))]
                }
            },
            "puppet_delete_bone": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try edit.requiredInt("bone")
                    try Self.bone(index, in: document)
                    guard document.bones.count > 1 else { throw ControlError(.refused, "A rig keeps at least one bone.") }
                    document.deleteBone(index)
                    return [:]
                }
            },
            "puppet_auto_weights": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let method = try edit.string("method").map { name -> PuppetAutoWeights.Method in
                        guard let method = PuppetAutoWeights.Method(rawValue: name) else {
                            throw ControlError(.invalidParams, "method must be \"heat\" or \"distance\".")
                        }
                        return method
                    } ?? .heat
                    document.weights = PuppetAutoWeights.compute(document, method: method)
                    return [:]
                }
            },
            "puppet_add_animation": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let name = try edit.string("name") ?? "Animation"
                    let index = document.addClip(named: Self.unique(name, in: document.clips.map(\.name)),
                                                 fps: Float(try edit.double("fps") ?? 30), frames: try edit.int("frames") ?? 60,
                                                 mode: try Self.clipMode(edit) ?? .loop)
                    // The first animation plays: WE plays only what the image's animation layers name.
                    if document.layers.isEmpty {
                        document.layers.append(PuppetAnimationLayer(id: document.nextLayerID, name: document.clips[index].name,
                                                                    clipID: document.clips[index].id))
                    }
                    return ["animation": .number(Double(index))]
                }
            },
            "puppet_update_animation": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try Self.animation(edit, in: document)
                    if let name = try edit.string("name"), !name.isEmpty { document.clips[index].name = name }
                    if let fps = try edit.double("fps") {
                        guard fps > 0 else { throw ControlError(.invalidParams, "fps must be above 0.") }
                        document.clips[index].fps = Float(fps)
                    }
                    if let frames = try edit.int("frames") {
                        guard frames > 0 else { throw ControlError(.invalidParams, "frames must be at least 1.") }
                        document.clips[index].setFrames(frames)
                    }
                    if let mode = try Self.clipMode(edit) { document.clips[index].mode = mode }
                    return ["animation": .number(Double(index))]
                }
            },
            "puppet_delete_animation": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    document.deleteClip(try Self.animation(edit, in: document))
                    return [:]
                }
            },
            "puppet_set_key": setPuppetKey,
            "puppet_delete_key": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try Self.animation(edit, in: document)
                    let frame = try edit.requiredInt("frame")
                    let bones = try edit.int("bone").map { bone -> [Int] in
                        try Self.bone(bone, in: document)
                        return [bone]
                    } ?? Array(document.bones.indices)
                    for bone in bones where document.clips[index].tracks.indices.contains(bone) {
                        document.clips[index].tracks[bone].keys[frame] = nil
                    }
                    return ["animation": .number(Double(index)), "frame": .number(Double(frame))]
                }
            },
            "puppet_add_animation_layer": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let clip = document.clips[try Self.animation(edit, in: document)]
                    document.layers.append(PuppetAnimationLayer(id: document.nextLayerID, name: clip.name, clipID: clip.id))
                    return ["animation_layer": .number(Double(document.layers.count - 1))]
                }
            },
            "puppet_update_animation_layer": updateAnimationLayer,
            "puppet_remove_animation_layer": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    document.layers.remove(at: try Self.animationLayer(edit, in: document))
                    return [:]
                }
            },
            "puppet_move_animation_layer": { edit, context in
                try Self.editPuppet(edit, context) { document in
                    let index = try Self.animationLayer(edit, in: document)
                    let target = index + (try edit.requiredInt("offset"))
                    guard document.layers.indices.contains(target) else {
                        throw ControlError(.invalidParams, "offset moves it out of the list (it has \(document.layers.count)).")
                    }
                    document.layers.swapAt(index, target)
                    return ["animation_layer": .number(Double(target))]
                }
            },
        ]
    }

    // MARK: The rig

    private static func imageLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> SceneLayer {
        let layer = try Self.layer(edit, context)
        guard layer.imageRole == .picture else {
            throw ControlError(.unsupported, "Layer \(layer.id) isn't an image layer with a picture; Puppet Warp rigs pictures.")
        }
        return layer
    }

    /// The layer's rig as the editor shows it: its edit, else the wallpaper's own.
    static func puppet(of layer: SceneLayer, _ context: SceneEditOperationContext) -> (document: PuppetDocument?, source: PuppetSource?) {
        let source = PuppetSource.load(layer: layer, assets: context.resources.puppetAssets)
        return (context.session.puppet(of: layer.id) ?? source?.document, source)
    }

    /// Changes the layer's rig as one edit; `change` returns the edit's result.
    private static func editPuppet(_ edit: ControlParameters, _ context: SceneEditOperationContext,
                                   _ change: (inout PuppetDocument) throws -> JSONValue) throws -> JSONValue {
        let layer = try Self.imageLayer(edit, context)
        guard var document = Self.puppet(of: layer, context).document else {
            throw ControlError(.unsupported, "Layer \(layer.id) has no puppet; puppet_create makes one.")
        }
        let result = try change(&document)
        context.session.setPuppet(document, of: layer.id, actionName: "")
        guard case .object(var object) = result else { return ["layer": .number(Double(layer.id))] }
        object["layer"] = .number(Double(layer.id))
        return .object(object)
    }

    private static func createPuppet(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.imageLayer(edit, context)
        let (current, source) = Self.puppet(of: layer, context)
        guard current == nil else { throw ControlError(.refused, "Layer \(layer.id) has a puppet already.") }
        guard let source else { throw ControlError(.unsupported, "Layer \(layer.id)'s picture can't be read.") }
        var document = PuppetDocument.new(imageSize: source.imageSize, material: source.material)
        if let texture = source.texture {
            document.replaceMesh(PuppetMeshGenerator.generate(texture.alphaMask, options: PuppetMeshGenerator.Options(spacing: 40, threshold: 8, padding: 2)))
        }
        if document.mesh.vertices.isEmpty {
            // The whole picture as two triangles, as the puppet editor makes one without a picture.
            let half = source.imageSize / 2
            let corners = [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)]
            let vertices = corners.map { corner in
                PuppetVertex(position: corner, uv: SIMD2(corner.x / source.imageSize.x + 0.5, 0.5 - corner.y / source.imageSize.y))
            }
            document.replaceMesh(PuppetMesh(vertices: vertices, triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)]))
        }
        document.weights = document.mesh.vertices.map { _ in [PuppetWeight(bone: 0, weight: 1)] }
        context.session.setPuppet(document, of: layer.id, actionName: "")
        return ["layer": .number(Double(layer.id)), "bones": .number(Double(document.bones.count)),
                "vertices": .number(Double(document.mesh.vertices.count))]
    }

    // MARK: Naming parts

    private static func bone(_ index: Int, in document: PuppetDocument) throws {
        guard document.bones.indices.contains(index) else {
            throw ControlError(.notFound, "No bone \(index): the rig has \(document.bones.count) (0 to \(document.bones.count - 1)).")
        }
    }

    private static func animation(_ edit: ControlParameters, in document: PuppetDocument) throws -> Int {
        let index = try edit.requiredInt("animation")
        guard document.clips.indices.contains(index) else {
            throw ControlError(.notFound, document.clips.isEmpty ? "The rig has no animations; puppet_add_animation adds one."
                               : "No animation \(index): 0 to \(document.clips.count - 1).")
        }
        return index
    }

    private static func animationLayer(_ edit: ControlParameters, in document: PuppetDocument) throws -> Int {
        let index = try edit.requiredInt("animation_layer")
        guard document.layers.indices.contains(index) else {
            throw ControlError(.notFound, document.layers.isEmpty ? "The image has no animation layers."
                               : "No animation layer \(index): 0 to \(document.layers.count - 1).")
        }
        return index
    }

    private static func clipMode(_ edit: ControlParameters) throws -> PuppetClip.Mode? {
        try edit.string("mode").map { name in
            guard let mode = PuppetClip.Mode(rawValue: name) else {
                throw ControlError(.invalidParams, "mode must be \"loop\", \"mirror\" or \"single\".")
            }
            return mode
        }
    }

    static func unique(_ base: String, in names: [String]) -> String {
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Keys and layers

    private static func setPuppetKey(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        try Self.editPuppet(edit, context) { document in
            let index = try Self.animation(edit, in: document)
            let boneIndex = try edit.requiredInt("bone")
            try Self.bone(boneIndex, in: document)
            let frame = try edit.requiredInt("frame")
            guard frame >= 0, frame <= document.clips[index].frames else {
                throw ControlError(.invalidParams, "frame must be from 0 to \(document.clips[index].frames).")
            }
            while document.clips[index].tracks.count < document.bones.count { document.clips[index].tracks.append(PuppetTrack()) }
            let rest = document.restLocals[boneIndex]
            var transform = document.clips[index].tracks[boneIndex].keys[frame]
                ?? document.clips[index].transform(of: boneIndex, at: Float(frame), rest: rest)
            if let x = try edit.double("x") { transform.translation.x = Float(x) }
            if let y = try edit.double("y") { transform.translation.y = Float(y) }
            if let angle = try edit.double("angle") { transform.euler.z = Float(angle * .pi / 180) }
            if let scale = try edit.string("scale") {
                let parts = try SceneControlValues.vector(scale, count: 2, fallback: [Double(transform.scale.x), Double(transform.scale.y)],
                                                          name: "scale")
                transform.scale.x = Float(parts[0])
                transform.scale.y = Float(parts[1])
            }
            document.clips[index].tracks[boneIndex].keys[frame] = transform
            return ["animation": .number(Double(index)), "bone": .number(Double(boneIndex)), "frame": .number(Double(frame))]
        }
    }

    private static func updateAnimationLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        try Self.editPuppet(edit, context) { document in
            let index = try Self.animationLayer(edit, in: document)
            var layer = document.layers[index]
            if let clip = try edit.int("animation") {
                guard document.clips.indices.contains(clip) else { throw ControlError(.notFound, "No animation \(clip).") }
                layer.clipID = document.clips[clip].id
            }
            if let blend = try edit.double("blend") {
                guard (0...1).contains(blend) else { throw ControlError(.invalidParams, "blend must be from 0 to 1.") }
                layer.blend = Float(blend)
            }
            if let rate = try edit.double("rate") { layer.rate = Float(rate) }
            if let visible = try edit.bool("visible") { layer.visible = visible }
            if let additive = try edit.bool("additive") { layer.additive = additive }
            if let blendIn = try edit.bool("blend_in") { layer.blendIn = blendIn }
            if let blendOut = try edit.bool("blend_out") { layer.blendOut = blendOut }
            if let blendTime = try edit.double("blend_time") { layer.blendTime = Float(max(blendTime, 0)) }
            if let name = try edit.string("name"), !name.isEmpty { layer.name = name }
            document.layers[index] = layer
            return ["animation_layer": .number(Double(index))]
        }
    }
}
