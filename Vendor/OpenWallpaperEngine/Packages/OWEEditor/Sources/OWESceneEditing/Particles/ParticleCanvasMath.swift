import Foundation

/// A control point of a particle system as the canvas shows it.
public struct ParticleControlPointHandle: Hashable, Sendable {
    /// Its slot (0…7).
    public let index: Int
    /// Its `offset`: from the system's origin in the system's space, or a position in the scene
    /// for a worldspace point.
    public let offset: SIMD3<Double>
    /// Where it is in the scene.
    public let position: SIMD2<Double>
    /// Flag 2 (not on point 0): the offset is in the scene, not the system (`ParticleSystemBuilder.controlPoints`).
    public let isWorldSpace: Bool
    /// Flag 1: it follows the pointer while the wallpaper runs.
    public let followsPointer: Bool
}

extension ParticleEditingModel {
    /// How near (scene units at the canvas's scale, converted by the caller) a press must be.
    public static let handleRadius: Double = 8

    /// The layer's space to the scene's, its parents' transforms included.
    public func sceneTransform(of layerID: Int) -> SceneTransform2D {
        parentTransform(of: layerID).concatenating(session.transform(of: layerID).local)
    }

    /// The layer's parent space to the scene's.
    public func parentTransform(of layerID: Int) -> SceneTransform2D {
        var parent = SceneTransform2D.identity
        for ancestor in session.outline.ancestors(of: layerID).reversed() {
            parent = parent.concatenating(session.transform(of: ancestor.id).local)
        }
        return parent
    }

    /// The system's origin in the scene: where its emitters are.
    public func origin(of layerID: Int) -> SIMD2<Double> {
        sceneTransform(of: layerID).apply(.zero)
    }

    /// The particle layers the canvas shows a handle for: visible systems of a 2D scene.
    public var canvasSystems: [Int] {
        guard session.outline.size != nil else { return [] }
        return session.outline.layers.filter { $0.kind == .particle && session.isVisible($0.id) }.map(\.id)
    }

    /// The topmost visible, unlocked system whose origin is within `radius` (scene units) of `scenePoint`.
    public func system(at scenePoint: SIMD2<Double>, radius: Double) -> Int? {
        for id in canvasSystems.reversed() where !session.isLocked(id) {
            let delta = origin(of: id) - scenePoint
            if (delta * delta).sum() <= radius * radius { return id }
        }
        return nil
    }

    /// The control points of the layer's system the canvas shows, as the definition lists them
    /// (a point WE's editor is told to hide, flag 16, is left out), the dragged one where the
    /// drag has it.
    public func controlPoints(of layerID: Int) -> [ParticleControlPointHandle] {
        guard session.outline.size != nil, let path = particlePath(of: layerID), let definition = definition(path) else { return [] }
        let world = sceneTransform(of: layerID)
        return definition.items(.controlpoint).prefix(ParticleDefinition.capacity(of: .controlpoint)).enumerated()
            .compactMap { index, item in
                let flags = Int(item["flags"]?.doubleValue ?? 0)
                guard flags & 16 == 0 else { return nil }
                var components = SceneVector.components(item["offset"], fallback: [0, 0, 0])
                if let preview = controlPointPreview, preview.layer == layerID, preview.index == index {
                    components = [preview.offset.x, preview.offset.y, preview.offset.z]
                }
                let offset = SIMD3(components[0], components[1], components[2])
                let worldSpace = flags & 2 != 0 && index != 0
                let position = worldSpace ? SIMD2(offset.x, offset.y) : world.apply(SIMD2(offset.x, offset.y))
                return ParticleControlPointHandle(index: index, offset: offset, position: position,
                                                  isWorldSpace: worldSpace, followsPointer: flags & 1 != 0)
            }
    }

    /// The control point under `scenePoint`, within `radius` scene units.
    public func controlPoint(of layerID: Int, at scenePoint: SIMD2<Double>, radius: Double) -> ParticleControlPointHandle? {
        controlPoints(of: layerID).reversed().first { handle in
            let delta = handle.position - scenePoint
            return (delta * delta).sum() <= radius * radius
        }
    }

    /// The offset that puts `handle` at `scenePoint`, its depth kept.
    public func controlPointOffset(_ handle: ParticleControlPointHandle, at scenePoint: SIMD2<Double>,
                                   of layerID: Int) -> SIMD3<Double> {
        let local = handle.isWorldSpace ? scenePoint : (sceneTransform(of: layerID).inverted?.apply(scenePoint) ?? scenePoint)
        return SIMD3(local.x, local.y, handle.offset.z)
    }

    /// The gizmo drag that moves the system with its origin (`LayerGizmo`'s body drag on a point).
    public func moveDrag(of layerID: Int, from scenePoint: SIMD2<Double>) -> LayerGizmo.Drag {
        let geometry = LayerGeometry(transform: session.transform(of: layerID), parent: parentTransform(of: layerID),
                                     size: SIMD2(1, 1))
        return LayerGizmo.Drag(handle: .body, start: geometry, startPoint: scenePoint)
    }
}
