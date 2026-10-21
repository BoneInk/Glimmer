import Foundation

/// The user-bound dynamic constants of one pass (`ShaderConstantResolver.DynamicConstant`), resolved
/// once per binding revision of their owner (`SceneValueContext.bindingRevision`) instead of every
/// frame. Only a constant bound to a user property alone is kept: one with a timeline or a script,
/// or whose property follows the music, still resolves every frame. Without a revision (a context
/// outside the renderer) nothing is kept.
struct SceneUserConstantCache {
    private var revision: UInt64?
    private var values: [ShaderValue?] = []

    /// Takes `context`'s revision: resolves the kept constants again when it moved. Allocates only then.
    mutating func begin(_ constants: [ShaderConstantResolver.DynamicConstant], in context: SceneValueContext) {
        guard let current = context.bindingRevision else {
            revision = nil
            return
        }
        guard current != revision else { return }
        revision = current
        values = constants.map { constant in
            guard case .user(let name, _, .literal) = constant.source, !context.isMusicSynced(name) else { return nil }
            return ShaderConstantResolver.shape(SceneValueResolver.resolve(constant.source, in: context),
                                                count: constant.count, isInt: constant.isInt)
        }
    }

    /// Constant `index`'s value this frame: kept, or resolved now.
    func value(_ index: Int, of constant: ShaderConstantResolver.DynamicConstant, in context: SceneValueContext) -> ShaderValue {
        if revision != nil, index < values.count, let kept = values[index] { return kept }
        return ShaderConstantResolver.shape(SceneValueResolver.resolve(constant.source, in: context),
                                            count: constant.count, isInt: constant.isInt)
    }
}
