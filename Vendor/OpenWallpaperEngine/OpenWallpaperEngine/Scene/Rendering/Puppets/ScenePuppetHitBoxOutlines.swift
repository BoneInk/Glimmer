import Foundation
import simd

/// A Puppet Warp image's hit boxes as WE's editor draws them (View › Show Debug › Show Hitboxes):
/// one per bone, the skeleton's per-bone box (`MDLSkeleton.boneVectors`, which WE's editor
/// compiles as the bounds of the vertices the bone moves, in the bone's frame, and as a 1-unit box
/// for a bone that moves none), posed by the bone's world this frame, the box the cursor's
/// `hitBox` is taken from (`SceneScriptCursorHitTest.hitBox`).
struct ScenePuppetHitBoxOutline: Equatable, Sendable {
    var layerID: String
    var bone: Int
    var name: String
    /// The box's corners in scene units (y up), in order around it.
    var corners: [SIMD2<Float>]

    /// `skeleton`'s boxes posed by `boneWorlds` (model space) and `world` (the image's), none
    /// without the per-bone block.
    static func outlines(layerID: String, skeleton: MDLSkeleton, boneWorlds: [simd_float4x4],
                         world: simd_float4x4) -> [Self] {
        guard let boxes = skeleton.boneVectors else { return [] }
        return boxes.enumerated().compactMap { index, box in
            guard index < boneWorlds.count else { return nil }
            let frame = world * boneWorlds[index] * box.matrix
            let h = box.vector
            let corners = [SIMD2<Float>(-h.x, -h.y), SIMD2(h.x, -h.y), SIMD2(h.x, h.y), SIMD2(-h.x, h.y)].map { corner in
                let point: SIMD4<Float> = frame * SIMD4<Float>(corner.x, corner.y, 0, 1)
                return SIMD2<Float>(point.x, point.y)
            }
            let name = index < skeleton.bones.count ? skeleton.bones[index].name : ""
            return Self(layerID: layerID, bone: index, name: name.isEmpty ? String(index) : name, corners: corners)
        }
    }
}

/// The outlines the last frame posed, for the editor's canvas on the main thread while the render
/// thread draws. Only a reader keeps them coming: a frame computes them while one asked within
/// the last second.
final class ScenePuppetHitBoxFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var outlines: [ScenePuppetHitBoxOutline] = []
    private var lastRequest: CFAbsoluteTime = -.infinity

    /// The last frame's outlines; asks the next frames for theirs.
    func read() -> [ScenePuppetHitBoxOutline] {
        lock.withLock {
            lastRequest = CFAbsoluteTimeGetCurrent()
            return outlines
        }
    }

    /// Whether a reader asked within the last second (render thread).
    var isWanted: Bool {
        lock.withLock { CFAbsoluteTimeGetCurrent() - lastRequest < 1 }
    }

    func publish(_ outlines: [ScenePuppetHitBoxOutline]) {
        lock.withLock { self.outlines = outlines }
    }
}
