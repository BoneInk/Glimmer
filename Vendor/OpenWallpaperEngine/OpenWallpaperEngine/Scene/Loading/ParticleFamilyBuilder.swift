import simd

/// Flattens a particle object's system and its `children`, depth first, into the scene's list
/// of particle systems: each child follows its parent and names it by index
/// (`ParticleChildLink.parentIndex`).
struct ParticleFamilyBuilder {
    /// Reads a particle json; nil when it can't be read (the reader logs why).
    let load: (String) -> WEParticleSystem?
    /// Builds one system of the family from its json, emitter transform and instance overrides;
    /// nil when it can't draw (no material or texture).
    let build: (_ path: String, _ system: WEParticleSystem, _ world: SceneAffineTransform,
                _ overrides: SceneParticleOverrides) -> SceneMetalParticleSystem?
    /// Where a failure is reported, with the object it belongs to.
    let report: (String) -> Void

    /// Bounds for malformed files only, far above any authored family: a list that names the same
    /// child many times at every level would otherwise grow the family exponentially.
    static let maximumDepth = 16
    static let maximumMembers = 4096

    /// The family of the system at `path`, the root first. `world` is the root emitter's authored
    /// world transform.
    func family(_ path: String, world: SceneAffineTransform,
                overrides: SceneParticleOverrides) -> [SceneMetalParticleSystem] {
        var family: [SceneMetalParticleSystem] = []
        append(path, link: nil, linkSpace: .identity, world: world, overrides: overrides, ancestors: [], into: &family)
        return family
    }

    private func append(_ path: String, link: ParticleChildLink?, linkSpace: ParticleLinkSpace, world: SceneAffineTransform,
                        overrides: SceneParticleOverrides, ancestors: [String],
                        into family: inout [SceneMetalParticleSystem]) {
        guard let json = load(path) else {
            if link != nil { report("child particle system \(path) can't be read") }
            return
        }
        guard var system = build(path, json, world, overrides) else {
            if link != nil { report("child particle system \(path) has no drawable material") }
            return
        }
        let children = json.children ?? []
        system.link = link
        system.linkSpace = linkSpace.space
        system.hasEventChildren = children.contains { Self.kind($0) != .static }
        let index = family.count
        family.append(system)
        for child in children {
            guard family.count < Self.maximumMembers else {
                report("particle system \(path)'s family reached \(Self.maximumMembers) systems; its remaining children are skipped")
                break
            }
            guard ancestors.count + 1 < Self.maximumDepth else {
                report("particle system \(path) is nested \(Self.maximumDepth) levels deep; its children are skipped")
                break
            }
            guard let name = child.name, !name.isEmpty else { continue }
            guard !ancestors.contains(name), name != path else {
                report("particle system \(path) lists its own ancestor \(name) as a child; skipped")
                continue
            }
            guard let kind = Self.kind(child) else {
                report("particle child \(name) has an unknown type \(child.type ?? ""); skipped")
                continue
            }
            let childLink = Self.link(child, kind: kind, parentIndex: index, parent: link)
            append(name, link: childLink, linkSpace: linkSpace.appending(Self.local(child), kind: kind),
                   world: childLink.emitter(parent: world), overrides: overrides,
                   ancestors: ancestors + [path], into: &family)
        }
    }

    /// A child's type; `static` when it has none.
    static func kind(_ child: WEParticleChild) -> ParticleChildLink.Kind? {
        switch child.type?.lowercased() {
        case nil, "", "static": return .static
        case "eventfollow": return .follow
        case "eventspawn": return .spawn
        case "eventdeath": return .death
        default: return nil
        }
    }

    /// A link's `origin`, `scale` and `angles` (0x1401d09ea…0x1401d0c43: "0 0 0", "1 1 1", "0 0 0").
    static func local(_ child: WEParticleChild) -> SceneLocalTransform3D {
        func vector(_ value: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let v = value?.vectorValue else { return fallback }
            return SIMD3(Float(v.0), Float(v.1), Float(v.2))
        }
        return SceneLocalTransform3D(origin: vector(child.origin, .zero), scale: vector(child.scale, SIMD3(repeating: 1)),
                                     angles: vector(child.angles, .zero))
    }

    static func link(_ child: WEParticleChild, kind: ParticleChildLink.Kind, parentIndex: Int,
                     parent: ParticleChildLink?) -> ParticleChildLink {
        // The plane's part; the rest is `ParticleLinkSpace`'s.
        let local = Self.local(child).planar
        let parentInstanced = parent?.instanced == true
        let instances: Int
        if kind != .static {
            instances = max(child.maxcount ?? 10, 0)
        } else {
            instances = parentInstanced ? parent?.maximumInstances ?? 1 : 1
        }
        // Bit 0: the child's control points from `controlpointstartindex` on are the parent's particles.
        let controlPointStart = ((child.flags ?? 0) & 1) != 0 ? max(child.controlpointstartindex ?? 0, 0) : nil
        return ParticleChildLink(parentIndex: parentIndex, kind: kind, local: local,
                                 probability: Float(child.probability ?? 1), maximumInstances: instances,
                                 instanced: kind != .static || parentInstanced, controlPointStart: controlPointStart,
                                 restartsWithParentPeriod: ((child.flags ?? 0) & 2) != 0)
    }
}
