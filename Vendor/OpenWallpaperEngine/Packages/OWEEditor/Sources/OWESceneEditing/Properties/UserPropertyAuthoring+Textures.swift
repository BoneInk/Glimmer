import Foundation

/// A texture slot of a layer bound to a `scenetexture` or `usershortcut` property.
public struct UserTextureBinding: Hashable, Sendable {
    public var layer: Int
    /// The material's texture slot (0, the albedo, is the one WE's editor binds).
    public var slot: Int

    public init(layer: Int, slot: Int = 0) {
        self.layer = layer
        self.slot = slot
    }
}

/// Binding texture slots to user textures and shortcuts. WE's editor binds a layer's texture
/// (Advanced Texture Settings › a texture's gear › Bind User Property, `onTextureContextMenu`, on
/// any of the material's texture slots) and writes the link into the layer's MATERIAL, its first
/// pass's `usertextures`, an array parallel to `textures` with one entry per slot (WE 2.8.0.42,
/// capture 541: `"usertextures": ["customtexture"]` beside `"textures": ["variant_a"]`, the scene
/// object unchanged). A `scenetexture` link is the property's key, a `usershortcut` link
/// `{"name": key, "type": "usershortcut"}`; WE's own system textures
/// (`{"name": "$mediaThumbnail", "type": "system"}`) sit in the same arrays. The edited material is
/// kept in the overlay (`SceneEditOverlay.documents`), as Lighting & Reflections keeps it. A layer
/// whose material can't be read, or is shared with another layer, keeps the link in its object's
/// `instance.usertextures` (the player reads that first), as do drafts saved before.
extension UserPropertyAuthoring {
    /// The layers that can take a user texture: images (a solid placeholder is an image).
    public var textureLayers: [SceneLayer] {
        session.outline.layers.filter { $0.kind == .image }
    }

    /// The slots bound to `key`.
    public func textureBindings(of key: String) -> [UserTextureBinding] {
        textureLayers.flatMap { layer in
            let count = max(Self.userTextures(in: session.value("instance", of: layer.id)).count,
                            materialUserTextures(of: layer.id).count)
            return (0..<count).compactMap { slot in
                let binding = UserTextureBinding(layer: layer.id, slot: slot)
                return textureProperty(of: binding) == key ? binding : nil
            }
        }
    }

    /// The property a slot is bound to, if any (a system texture is none): the object's
    /// `instance` link first, as the player reads them, then its material's.
    public func textureProperty(of binding: UserTextureBinding) -> String? {
        linkedEntry(binding).flatMap(Self.linkedKey)
    }

    /// Binds a slot to the user texture or shortcut `key`, replacing what it had; one undo step.
    public func bindTexture(_ binding: UserTextureBinding, to key: String, actionName: String) {
        guard let property = property(key), property.kind.bindsTexture else { return }
        let link: SceneJSONValue = property.kind == .userShortcut
            ? .object(["name": .string(key), "type": .string(UserPropertyDraft.Kind.userShortcut.rawValue)])
            : .string(key)
        session.editOverlay(actionName: actionName) { overlay in
            setUserTexture(link, binding, in: &overlay)
        }
    }

    /// Unbinds a slot: the layer shows its own texture again.
    public func unbindTexture(_ binding: UserTextureBinding, actionName: String) {
        guard textureProperty(of: binding) != nil else { return }
        session.editOverlay(actionName: actionName) { overlay in
            setUserTexture(nil, binding, in: &overlay)
        }
    }

    /// Re-points every slot bound to `key` at `newKey` (inside a rename's undo step).
    func renameTextureBindings(_ key: String, to newKey: String, in overlay: inout SceneEditOverlay) {
        for binding in textureBindings(of: key) {
            let link: SceneJSONValue
            if case .object(var fields)? = linkedEntry(binding) {
                fields["name"] = .string(newKey)
                link = .object(fields)
            } else {
                link = .string(newKey)
            }
            setUserTexture(link, binding, in: &overlay)
        }
    }

    // MARK: Where the links are

    /// The entry naming a property for the slot: the instance's, else the material's.
    private func linkedEntry(_ binding: UserTextureBinding) -> SceneJSONValue? {
        let instance = Self.userTextures(in: session.value("instance", of: binding.layer))
        if instance.indices.contains(binding.slot), Self.linkedKey(instance[binding.slot]) != nil { return instance[binding.slot] }
        let material = materialUserTextures(of: binding.layer)
        if material.indices.contains(binding.slot), Self.linkedKey(material[binding.slot]) != nil { return material[binding.slot] }
        return nil
    }

    /// The layer's own material as the scene now reads it, when a binding can be written into it:
    /// readable and named by no other image layer's model.
    private func ownMaterial(of layerID: Int) -> ImageLayerLighting? {
        guard let material = session.imageMaterial(of: layerID, readAsset: readAsset) else { return nil }
        let shared = textureLayers.contains { other in
            other.id != layerID && session.imageMaterial(of: other.id, readAsset: readAsset)?.path == material.path
        }
        return shared ? nil : material
    }

    /// The material's first pass's `usertextures` entries (null for a slot without one).
    private func materialUserTextures(of layerID: Int) -> [SceneJSONValue] {
        guard let material = session.imageMaterial(of: layerID, readAsset: readAsset),
              case .array(let entries)? = material.firstPass["usertextures"] else { return [] }
        return entries
    }

    private func setUserTexture(_ link: SceneJSONValue?, _ binding: UserTextureBinding,
                                in overlay: inout SceneEditOverlay) {
        // A link of a draft saved with the instance form goes; the material gets the new one.
        let instanceLinked = Self.userTextures(in: session.value("instance", of: binding.layer))
        if instanceLinked.indices.contains(binding.slot), Self.linkedKey(instanceLinked[binding.slot]) != nil {
            setInstanceUserTexture(nil, binding, in: &overlay)
        }
        if let material = ownMaterial(of: binding.layer) {
            let authored = SceneEditSession.documentJSON(readAsset(material.path))
            let edited = overlay.document(material.path).map { ImageLayerLighting(path: material.path, document: $0) } ?? material
            let next = edited.changingFirstPass { pass in
                var entries: [SceneJSONValue] = { if case .array(let entries)? = pass["usertextures"] { return entries }; return [] }()
                while entries.count <= binding.slot { entries.append(.null) }
                entries[binding.slot] = link ?? .null
                while entries.last == .null { entries.removeLast() }
                pass["usertextures"] = entries.isEmpty ? nil : .array(entries)
            }
            overlay.setDocument(material.path, to: next == authored ? nil : next)
        } else if link != nil {
            setInstanceUserTexture(link, binding, in: &overlay)
        }
    }

    /// The object's `instance.usertextures` entry for the slot (the form for a layer without a
    /// material of its own).
    private func setInstanceUserTexture(_ link: SceneJSONValue?, _ binding: UserTextureBinding,
                                        in overlay: inout SceneEditOverlay) {
        let layerID = binding.layer
        let current = overlay.field("instance", of: layerID)
            ?? SceneFieldBinding.literal(of: session.authoredOutline.layer(layerID)?.fields["instance"])
        var instance: [String: SceneJSONValue] = [:]
        if case .object(let fields)? = current { instance = fields }
        var entries = Self.userTextures(in: current)
        while entries.count <= binding.slot { entries.append(.null) }
        entries[binding.slot] = link ?? .null
        while entries.last == .null { entries.removeLast() }
        instance["usertextures"] = entries.isEmpty ? nil : .array(entries)
        let authored = SceneFieldBinding.literal(of: session.authoredOutline.layer(layerID)?.fields["instance"])
        let next: SceneJSONValue? = instance.isEmpty ? nil : .object(instance)
        overlay.setField("instance", to: next == authored ? nil : (next ?? .object([:])), of: layerID)
    }

    /// An `instance`'s `usertextures` entries (null for a slot without one).
    static func userTextures(in instance: SceneJSONValue?) -> [SceneJSONValue] {
        guard case .object(let fields)? = instance, case .array(let entries)? = fields["usertextures"] else { return [] }
        return entries
    }

    /// The property a `usertextures` entry names: a key, or `{"name", "type": "usershortcut"}`.
    static func linkedKey(_ entry: SceneJSONValue) -> String? {
        switch entry {
        case .string(let key): return key.isEmpty ? nil : key
        case .object(let fields):
            guard fields["type"]?.stringValue == UserPropertyDraft.Kind.userShortcut.rawValue else { return nil }
            return fields["name"]?.stringValue
        default: return nil
        }
    }
}
