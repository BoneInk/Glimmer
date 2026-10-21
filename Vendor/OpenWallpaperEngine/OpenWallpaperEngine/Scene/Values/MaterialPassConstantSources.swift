import Foundation

extension MaterialPass {
    /// The pass's material values by key, for `ShaderConstantResolver`: its
    /// `constantshadervalues` (literals or user-, script- or animation-bound), with each material
    /// key `usershadervalues` names bound to its user property. The map runs from the property to
    /// the key (`fade.json`'s `{"schemecolor": "tint"}`: every project has a `schemecolor`, and
    /// `tint` is the key `fade.frag`'s `color` declares). A user-bound key falls back to the
    /// constant, else to the declaring uniform's annotation default.
    func constantSources(uniforms: [ShaderUniformDeclaration]) -> [String: SceneValueSource] {
        var values = constantshadervalues.compactMapValues(\.valueSource)
        for (property, key) in usershadervalues ?? [:] {
            let declared: ShaderUniformDeclaration? = uniforms.first { (uniform: ShaderUniformDeclaration) -> Bool in
                uniform.materialKey == key
            }
            let annotationDefault = declared.flatMap { $0.annotation["default"] }.flatMap(ShaderValue.init(json:))
            let fallback = values[key] ?? annotationDefault.map(SceneValueSource.literal)
            values[key] = .user(name: property, condition: nil, fallback: fallback ?? .literal(.zero))
        }
        return values
    }
}
