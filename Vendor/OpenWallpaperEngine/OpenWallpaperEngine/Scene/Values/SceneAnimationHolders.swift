import Foundation

/// Finds every animated property of a scene document: a bound value (`{"value", "animation", …}`)
/// whose `animation` is an object, at each site WE binds values (docs/timeline-plan.md §1.1):
///
/// - a layer's fields (`objects[i].<key>`), except its `effects` and `instanceoverride` blocks;
/// - its particle overrides (`objects[i].instanceoverride.<key>`);
/// - its effects' own fields (`effects[e].<key>`, e.g. `visible`), except `passes`;
/// - their materials' constants (`effects[e].passes[p].constantshadervalues.<name>`);
/// - a model's or puppet's animation layers' fields (`animationlayers[l].<key>`: `rate`, `blend`);
/// - the scene's settings (`general.<key>`), except `properties`, the user-property table.
///
/// Holders come in document order (objects, then `general`); within one block, keys are sorted,
/// since the JSON object doesn't keep its order.
enum SceneAnimationHolders {
    /// A site and its bound value's fields (`value`, `animation`, …).
    struct Holder {
        var site: SceneAnimationSite
        var fields: [String: SceneJSON]
    }

    static func holders(in document: SceneJSON) -> [Holder] {
        var holders: [Holder] = []
        for (index, fields) in SceneScriptSceneDescriber.objects(of: document).enumerated() {
            holders += Self.holders(ofObject: fields, id: SceneScriptSceneDescriber.objectID(fields, index: index))
        }
        if case .object(let root) = document, case .object(let general)? = root["general"] {
            holders += bound(in: general, owner: .scene, skipping: ["properties"])
        }
        return holders
    }

    /// The animated properties of one layer (a scene object or a layer a script created).
    static func holders(ofObject fields: [String: SceneJSON], id: Int) -> [Holder] {
        var holders = bound(in: fields, owner: .object(id), skipping: ["effects", "instanceoverride"])
        if case .object(let overrides)? = fields["instanceoverride"] {
            holders += bound(in: overrides, owner: .particleInstance(id), skipping: [])
        }
        if case .array(let layers)? = fields["animationlayers"] {
            for (index, entry) in layers.enumerated() {
                guard case .object(let layer) = entry else { continue }
                holders += bound(in: layer, owner: .animationLayer(object: id, layer: index), skipping: [])
            }
        }
        guard case .array(let effects)? = fields["effects"] else { return holders }
        for (effectIndex, entry) in effects.enumerated() {
            guard case .object(let effect) = entry else { continue }
            holders += bound(in: effect, owner: .effect(object: id, effect: effectIndex), skipping: ["passes"])
            guard case .array(let passes)? = effect["passes"] else { continue }
            for (passIndex, passEntry) in passes.enumerated() {
                guard case .object(let pass) = passEntry, case .object(let constants)? = pass["constantshadervalues"] else {
                    continue
                }
                holders += bound(in: constants, owner: .material(object: id, effect: effectIndex, pass: passIndex),
                                 skipping: [])
            }
        }
        return holders
    }

    private static func bound(in block: [String: SceneJSON], owner: SceneAnimationOwner,
                              skipping skipped: Set<String>) -> [Holder] {
        block.keys.sorted().compactMap { key in
            guard !skipped.contains(key), case .object(let fields)? = block[key],
                  case .object? = fields["animation"] else { return nil }
            return Holder(site: SceneAnimationSite(owner: owner, key: key), fields: fields)
        }
    }
}
