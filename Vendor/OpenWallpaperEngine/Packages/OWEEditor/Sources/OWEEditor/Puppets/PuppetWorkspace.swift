import Combine
import CoreGraphics
import Foundation
import OWESceneEditing
import simd

/// One image layer's Puppet Warp editor: the rig being edited, the tool and selection, and
/// the preview (the posed mesh, its picture, the clip's frame, the physics). Every finished
/// edit is one undo step in the editor window's session (`SceneEditSession.setPuppet`); a drag
/// shows a draft and commits once when it ends.
@MainActor
final class PuppetWorkspace: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case mesh, skeleton, weights, animate, physics, clipping
        var id: String { rawValue }
    }

    enum MeshTool: String, CaseIterable { case select, add }
    enum SkeletonTool: String, CaseIterable { case select, add }

    let session: SceneEditSession
    let layerID: Int
    let source: PuppetSource?

    /// The rig shown: the session's, a draft while a drag lasts.
    @Published private(set) var document: PuppetDocument?
    @Published var tool: Tool = .mesh { didSet { toolChanged() } }
    @Published var meshTool: MeshTool = .select
    @Published var skeletonTool: SkeletonTool = .select
    @Published var selectedVertices: Set<Int> = []
    @Published var selectedBone: Int?
    @Published var meshOptions = PuppetMeshGenerator.Options(spacing: 40, threshold: 8, padding: 2)
    @Published var weightMethod: PuppetAutoWeights.Method = .heat
    @Published var brush = PuppetWeightBrush()
    @Published var showsHeatMap = true

    // Clipping masks
    /// The limb (mesh island) the Clipping Masks tool works on.
    @Published var selectedLimb: Int?
    /// A clipping mask being painted over the image.
    @Published var clippingPainting: MaskPainting?
    /// Why the last clipping mask painting couldn't be kept.
    @Published var clippingProblem: String?
    /// Saves a painted mask and reads one back (`PuppetEditorAssets`); nil paints nothing.
    let assets: PuppetEditorAssets?

    // Animation
    @Published var clipIndex: Int?
    @Published var frame: Float = 0 {
        didSet {
            guard !isTicking else { return }
            clock?.time = frame / max(clip?.fps ?? 30, 1)
            refreshPose()
        }
    }
    @Published private(set) var isPlaying = false
    /// Play the image's animation layers (as the wallpaper will) instead of the clip being edited.
    @Published var previewsLayers = false { didSet { restartPlayback() } }
    @Published var showsOnionSkin = false
    @Published var onionFrames = 2

    // Physics
    /// The physics preview runs (in the Physics tool, or while playing).
    @Published var simulatesPhysics = true { didSet { restartPlayback() } }
    /// Where the preview has dragged the puppet, to shake its physics bones.
    @Published var objectOffset = SIMD2<Float>.zero

    // Preview
    /// The posed mesh (mesh space).
    @Published private(set) var positions: [SIMD2<Float>] = []
    /// The pose's model-space bone matrices.
    @Published private(set) var worlds: [simd_float4x4] = []
    /// The picture through the posed mesh, and the mesh-space rect it covers.
    @Published private(set) var picture: (image: CGImage, bounds: (min: SIMD2<Float>, max: SIMD2<Float>))?
    @Published private(set) var heatMap: (image: CGImage, bounds: (min: SIMD2<Float>, max: SIMD2<Float>))?

    private var isDrafting = false
    private var isTicking = false
    private var rig: PuppetRig?
    private var player: PuppetLayerPlayer?
    private var clock: PuppetClipClock?
    private var simulation: PuppetPhysicsSimulation?
    /// The kinematic chains' solver (`PuppetIKSolver`), nil without a chain.
    private var solver: PuppetIKSolver?
    private var timer: Timer?
    private var lastTick: Date?
    private var observers: Set<AnyCancellable> = []

    init(session: SceneEditSession, layerID: Int, source: PuppetSource?, assets: PuppetEditorAssets? = nil) {
        self.session = session
        self.layerID = layerID
        self.source = source
        self.assets = assets
        document = session.puppet(of: layerID) ?? source?.document
        clipIndex = (document?.clips.isEmpty ?? true) ? nil : 0
        rebuild()
        session.$overlay
            .dropFirst()
            .sink { [weak self] overlay in
                MainActor.assumeIsolated { self?.overlayChanged(overlay) }
            }
            .store(in: &observers)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// The rig as the wallpaper has it (nil for an image without one).
    var original: PuppetDocument? { source?.document }
    var hasEdits: Bool { session.puppet(of: layerID) != nil }
    var imageSize: SIMD2<Float> { document?.imageSize ?? source?.imageSize ?? SIMD2(512, 512) }

    // MARK: Session

    private func overlayChanged(_ overlay: SceneEditOverlay) {
        guard !isDrafting else { return }
        let stored = overlay.puppet(of: layerID) ?? original
        guard stored != document else { return }
        document = stored
        clampSelection()
        rebuild()
    }

    /// One finished edit: applied and stored as an undo step.
    func edit(_ actionName: String, coalescing: Bool = false, _ change: (inout PuppetDocument) -> Void) {
        guard var next = document else { return }
        change(&next)
        guard next != document else { return }
        document = next
        rebuild()
        session.setPuppet(next, of: layerID, actionName: actionName, coalescing: coalescing)
    }

    /// A drag's change, shown but not stored until `endDraft`.
    func draft(_ change: (inout PuppetDocument) -> Void) {
        guard var next = document else { return }
        isDrafting = true
        change(&next)
        document = next
        rebuild()
    }

    func endDraft(_ actionName: String) {
        guard isDrafting else { return }
        isDrafting = false
        guard let document, document != (session.puppet(of: layerID) ?? original) else { return }
        session.setPuppet(document, of: layerID, actionName: actionName)
    }

    func cancelDraft() {
        guard isDrafting else { return }
        isDrafting = false
        document = session.puppet(of: layerID) ?? original
        rebuild()
    }

    /// Drops the editor's changes to this layer's puppet (undoable).
    func discardEdits() {
        session.setPuppet(nil, of: layerID, actionName: PL("Discard Puppet Edits"))
    }

    private func clampSelection() {
        guard let document else {
            selectedBone = nil
            selectedVertices = []
            clipIndex = nil
            return
        }
        if let bone = selectedBone, !document.bones.indices.contains(bone) { selectedBone = nil }
        if let limb = selectedLimb, limb >= document.mesh.islandCount { selectedLimb = nil }
        selectedVertices = selectedVertices.filter { document.mesh.vertices.indices.contains($0) }
        if let clip = clipIndex, !document.clips.indices.contains(clip) { clipIndex = document.clips.isEmpty ? nil : 0 }
        if clipIndex == nil, !document.clips.isEmpty { clipIndex = 0 }
    }

    // MARK: Creating

    /// A new rig over the picture: a mesh fitted to its alpha, one root bone at its centre,
    /// every vertex on it.
    func createPuppet() {
        guard let source else { return }
        var next = PuppetDocument.new(imageSize: source.imageSize, material: source.material)
        if let texture = source.texture {
            next.replaceMesh(PuppetMeshGenerator.generate(texture.alphaMask, options: meshOptions))
        } else {
            next.replaceMesh(Self.rectangle(size: source.imageSize))
        }
        next.weights = next.mesh.vertices.map { _ in [PuppetWeight(bone: 0, weight: 1)] }
        document = next
        selectedBone = 0
        tool = .mesh
        rebuild()
        session.setPuppet(next, of: layerID, actionName: PL("Create Puppet"))
    }

    /// The whole picture as two triangles.
    static func rectangle(size: SIMD2<Float>) -> PuppetMesh {
        let h = size / 2
        let corners = [SIMD2(-h.x, -h.y), SIMD2(h.x, -h.y), SIMD2(h.x, h.y), SIMD2(-h.x, h.y)]
        let vertices = corners.map { PuppetVertex(position: $0, uv: SIMD2($0.x / size.x + 0.5, 0.5 - $0.y / size.y)) }
        return PuppetMesh(vertices: vertices, triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)])
    }

    // MARK: Mesh

    /// Replaces the mesh with one fitted to the picture's alpha and weights it again.
    func generateMesh() {
        guard let texture = source?.texture else { return }
        let mesh = PuppetMeshGenerator.generate(texture.alphaMask, options: meshOptions)
        guard !mesh.vertices.isEmpty else { return }
        let method = weightMethod
        edit(PL("Generate Mesh")) { document in
            document.replaceMesh(mesh)
            document.weights = PuppetAutoWeights.compute(document, method: method)
        }
        selectedVertices = []
    }

    func deleteSelectedVertices() {
        let selection = selectedVertices
        guard !selection.isEmpty else { return }
        edit(PL("Delete Vertices")) { $0.deleteVertices(selection) }
        selectedVertices = []
    }

    // MARK: Weights

    func autoWeights() {
        let method = weightMethod
        edit(PL("Automatic Weights")) { $0.weights = PuppetAutoWeights.compute($0, method: method) }
    }

    // MARK: Bones

    func deleteSelectedBone() {
        guard let bone = selectedBone, let document, document.bones.count > 1 else { return }
        edit(PL("Delete Bone")) { $0.deleteBone(bone) }
        selectedBone = nil
    }

    func renameBone(_ bone: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, document?.bones.indices.contains(bone) == true, document?.bones[bone].name != trimmed else { return }
        edit(PL("Rename Bone")) { $0.bones[bone].name = $0.uniqueBoneName(trimmed) }
    }

    func reparentBone(_ bone: Int, to parent: Int?) {
        guard let document, document.bones.indices.contains(bone) else { return }
        let name = document.bones[bone].name
        edit(PL("Change Parent")) { _ = $0.reparent(bone, to: parent) }
        selectedBone = self.document?.bones.firstIndex { $0.name == name }
    }

    // MARK: Clips

    var clip: PuppetClip? {
        guard let document, let clipIndex, document.clips.indices.contains(clipIndex) else { return nil }
        return document.clips[clipIndex]
    }

    func addClip() {
        guard let document else { return }
        let name = Self.unique(PL("Animation"), in: document.clips.map(\.name))
        var added = 0
        edit(PL("New Animation")) { document in
            added = document.addClip(named: name)
            // The first clip plays: WE plays only what the image's animation layers name.
            if document.layers.isEmpty {
                document.layers.append(PuppetAnimationLayer(id: document.nextLayerID, name: name, clipID: document.clips[added].id))
            }
        }
        clipIndex = added
        frame = 0
    }

    func deleteClip() {
        guard let clipIndex else { return }
        edit(PL("Delete Animation")) { $0.deleteClip(clipIndex) }
        self.clipIndex = (document?.clips.isEmpty ?? true) ? nil : max(0, clipIndex - 1)
        frame = 0
    }

    func updateClip(_ actionName: String, coalescing: Bool = true, _ change: (inout PuppetClip) -> Void) {
        guard let clipIndex else { return }
        edit(actionName, coalescing: coalescing) { document in
            guard document.clips.indices.contains(clipIndex) else { return }
            change(&document.clips[clipIndex])
        }
    }

    /// The selected bone's transform in the clip at the current frame.
    func keyTransform(of bone: Int) -> PuppetTransform? {
        guard let document, let clip, document.bones.indices.contains(bone) else { return nil }
        return clip.transform(of: bone, at: frame.rounded(), rest: document.restLocals[bone])
    }

    /// Keys the selected bone (every bone without a selection) at the current frame, with its
    /// blend rules' weights.
    func addKey() {
        guard let document, let clipIndex else { return }
        let key = Int(frame.rounded())
        let bones = selectedBone.map { [$0] } ?? Array(document.bones.indices)
        let transforms = bones.map { keyTransform(of: $0)! }
        let clipID = document.clips[clipIndex].id
        edit(PL("Add Key")) { document in
            for (bone, transform) in zip(bones, transforms) { document.clips[clipIndex].tracks[bone].keys[key] = transform }
            for bone in bones {
                for (index, rule) in (document.bones[bone].blendRules ?? []).enumerated() {
                    document.setBlendRuleWeight(bone: bone, rule: index, clip: clipID, frame: key,
                                                to: rule.weight(clip: clipID, at: Float(key)))
                }
                if let ik = document.bones[bone].ik {
                    for controller in PuppetBoneIK.Controller.allCases {
                        document.bones[bone].ik!.setKey(controller, clip: clipID, frame: key,
                                                        to: ik.key(controller, clip: clipID, at: Float(key)))
                    }
                }
            }
        }
    }

    // MARK: Kinematic chains

    func updateIK(of bone: Int, _ actionName: String, coalescing: Bool = true, _ change: (inout PuppetBoneIK?) -> Void) {
        edit(actionName, coalescing: coalescing) { document in
            guard document.bones.indices.contains(bone) else { return }
            change(&document.bones[bone].ik)
            if document.bones[bone].ik != nil { document.bones[bone].physics = nil }
        }
    }

    /// The chains' controllers: each one's bone and kind with its place at the current frame.
    var controllers: [(bone: Int, controller: PuppetBoneIK.Controller, place: SIMD2<Float>)] {
        guard let document else { return [] }
        let layout = PuppetKinematicsLayout(document)
        return layout.links.indices.map { index in
            let link = layout.links[index]
            return (link.bone, link.controller, layout.linkPose(index, document: document, clip: clip?.id, frame: frame.rounded()).offset)
        }
    }

    /// Keys a controller at `place` (mesh space) at the current frame of the animation.
    func setController(bone: Int, _ controller: PuppetBoneIK.Controller, to place: SIMD2<Float>, draft isDraft: Bool) {
        guard let document, let clip, let ik = document.bones[bone].ik else { return }
        let layout = PuppetKinematicsLayout(document)
        guard let rest = layout.links.first(where: { $0.bone == bone && $0.controller == controller })?.rest else { return }
        let key = Int(frame.rounded()), id = clip.id
        var value = ik.key(controller, clip: id, at: Float(key))
        value.offset = place - rest
        let change: (inout PuppetDocument) -> Void = { $0.bones[bone].ik?.setKey(controller, clip: id, frame: key, to: value) }
        if isDraft { draft(change) } else { edit(controller == .target ? PL("Move IK Target") : PL("Move Orientation Controller"), change) }
    }

    // MARK: Blend rules

    func addBlendRule(target: Int) {
        guard let bone = selectedBone else { return }
        edit(PL("Add Blend Rule")) { $0.addBlendRule(bone: bone, target: target) }
    }

    func removeBlendRule(_ index: Int) {
        guard let bone = selectedBone else { return }
        edit(PL("Delete Blend Rule")) { $0.removeBlendRule(bone: bone, at: index) }
    }

    /// The selected bone's rule `index` weight at the current frame of the animation.
    func blendRuleWeight(_ index: Int) -> Float {
        guard let document, let bone = selectedBone, let clip, let rules = document.bones[bone].blendRules,
              rules.indices.contains(index) else { return 0 }
        return rules[index].weight(clip: clip.id, at: frame.rounded())
    }

    /// Keys the selected bone's rule `index` weight at the current frame.
    func setBlendRuleWeight(_ index: Int, to value: Float) {
        guard let bone = selectedBone, let clip else { return }
        let key = Int(frame.rounded()), id = clip.id
        edit(PL("Change Blend Rule Weight"), coalescing: true) {
            $0.setBlendRuleWeight(bone: bone, rule: index, clip: id, frame: key, to: value)
        }
    }

    func deleteKey() {
        guard let clipIndex else { return }
        let key = Int(frame.rounded())
        let bones = selectedBone.map { [$0] } ?? Array((document?.bones ?? []).indices)
        edit(PL("Delete Key")) { document in
            for bone in bones where document.clips[clipIndex].tracks.indices.contains(bone) {
                document.clips[clipIndex].tracks[bone].keys[key] = nil
                let id = document.clips[clipIndex].id
                for index in (document.bones[bone].blendRules ?? []).indices {
                    document.setBlendRuleWeight(bone: bone, rule: index, clip: id, frame: key, to: nil)
                }
                for controller in PuppetBoneIK.Controller.allCases {
                    document.bones[bone].ik?.setKey(controller, clip: id, frame: key, to: nil)
                }
            }
        }
    }

    /// Frames with a key: the selected bone's, else any bone's.
    var keyFrames: Set<Int> {
        guard let clip else { return [] }
        if let bone = selectedBone, clip.tracks.indices.contains(bone) {
            let item = document?.bones.indices.contains(bone) == true ? document?.bones[bone] : nil
            let rules = item?.blendRules ?? []
            let controllers = PuppetBoneIK.Controller.allCases.flatMap { (item?.ik?.keys($0)[clip.id] ?? [:]).keys }
            return Set(clip.tracks[bone].keys.keys).union(rules.flatMap { ($0.weights[clip.id] ?? [:]).keys }).union(controllers)
        }
        return Set(clip.tracks.flatMap { $0.keys.keys })
    }

    func addLayer() {
        guard let clip else { return }
        edit(PL("Add Animation Layer")) { document in
            document.layers.append(PuppetAnimationLayer(id: document.nextLayerID, name: clip.name, clipID: clip.id))
        }
    }

    func updateLayer(_ index: Int, _ actionName: String, coalescing: Bool = true, _ change: (inout PuppetAnimationLayer) -> Void) {
        edit(actionName, coalescing: coalescing) { document in
            guard document.layers.indices.contains(index) else { return }
            change(&document.layers[index])
        }
    }

    func deleteLayer(_ index: Int) {
        edit(PL("Remove Animation Layer")) { document in
            guard document.layers.indices.contains(index) else { return }
            document.layers.remove(at: index)
        }
    }

    func moveLayer(_ index: Int, by offset: Int) {
        edit(PL("Reorder Animation Layers")) { document in
            let target = index + offset
            guard document.layers.indices.contains(index), document.layers.indices.contains(target) else { return }
            document.layers.swapAt(index, target)
        }
    }

    static func unique(_ base: String, in names: [String]) -> String {
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Physics

    func updatePhysics(of bone: Int, _ actionName: String, coalescing: Bool = true, _ change: (inout PuppetBonePhysics?) -> Void) {
        edit(actionName, coalescing: coalescing) { document in
            guard document.bones.indices.contains(bone) else { return }
            change(&document.bones[bone].physics)
        }
    }

    func resetPhysics() {
        objectOffset = .zero
        simulation?.reset()
        refreshPose()
    }

    /// Shakes the selected bone (`applyBonePhysicsImpulse`).
    func impulse() {
        guard let bone = selectedBone else { return }
        simulation?.applyImpulse(bone: bone, linear: SIMD3(0, 200, 0), angularDegrees: SIMD3(0, 0, 25))
    }

    // MARK: Playback

    func togglePlayback() {
        isPlaying.toggle()
        restartPlayback()
    }

    private func toolChanged() {
        if tool != .animate && tool != .physics { isPlaying = false }
        restartPlayback()
    }

    /// Whether the preview runs on a clock: playing, or the physics tool's live preview.
    private var runsClock: Bool {
        guard document != nil else { return false }
        return isPlaying || (tool == .physics && simulatesPhysics)
    }

    private func restartPlayback() {
        if let document {
            player = PuppetLayerPlayer(rig: rig ?? PuppetRig(document), layers: document.layers)
            clock = clip.map(PuppetClipClock.init)
            clock?.time = frame / max(clip?.fps ?? 30, 1)
            simulation = simulatesPhysics ? PuppetPhysicsSimulation(document) : nil
            solver?.reset(document)
        }
        lastTick = nil
        if runsClock {
            if timer == nil {
                let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        refreshPose()
    }

    private func tick() {
        let now = Date()
        let delta = Float(min(lastTick.map { now.timeIntervalSince($0) } ?? 0, 0.1))
        lastTick = now
        guard document != nil else { return }
        if isPlaying, !previewsLayers, var clock {
            clock.advance(by: delta)
            self.clock = clock
            isTicking = true
            frame = clock.frame
            isTicking = false
            if clock.finished { isPlaying = false }
        }
        refreshPose(delta: delta)
    }

    // MARK: Preview

    /// After the document changed: the rig, the player and the pose again.
    private func rebuild() {
        guard let document else {
            rig = nil
            positions = []
            worlds = []
            picture = nil
            heatMap = nil
            return
        }
        rig = PuppetRig(document)
        solver = PuppetIKSolver(document)
        if player != nil || simulation != nil || clock != nil { restartPlayback() } else { refreshPose() }
    }

    /// Whether the preview shows a pose rather than the bind pose.
    var showsPose: Bool { tool == .animate || tool == .physics }

    /// Poses the mesh for the tool: the bind pose while building, the clip's frame (or the
    /// layers) while animating, with the physics bones stepped by `delta`.
    func refreshPose(delta: Float = 0) {
        guard let document, let rig else { return }
        var pose = rig.restPose
        var blendWeights: [Float] = []
        if showsPose {
            if previewsLayers || clip == nil {
                if isPlaying || tool == .physics, var player {
                    pose = player.evaluate(delta: isPlaying ? delta : 0)
                    blendWeights = player.blendWeights
                    self.player = player
                }
            } else if let clipIndex {
                pose = rig.pose(clip: clipIndex, frame: frame)
                blendWeights = rig.blendWeights(clip: clipIndex, frame: frame)
            }
        }
        // The chains reach for their controllers where the clip (or the top layer) has them.
        let solver = showsPose ? self.solver : nil
        if let solver {
            var clipID = clip?.id, at = frame.rounded()
            if previewsLayers || clip == nil, let layer = player?.layers.first(where: { $0.settings.visible }) {
                clipID = rig.clips[layer.clip].id
                at = Float(layer.clock.samplePosition.frame0) + layer.clock.samplePosition.fraction
            }
            solver.begin(links: solver.layout.links.indices.map { solver.layout.linkPose($0, document: document, clip: clipID, frame: at) },
                         delta: delta)
        }
        var models: [simd_float4x4]
        if showsPose, tool == .physics || isPlaying, var simulation {
            let world = PuppetMath.matrix(translation: SIMD3(objectOffset.x, objectOffset.y, 0), euler: .zero, scale: SIMD3(repeating: 1))
            let locals = pose.map(\.matrix)
            let adjust = rig.blendRules.contains(where: { !$0.isEmpty })
                ? PuppetBlendMath.adjust(rules: rig.blendRules, weights: blendWeights,
                                         fallback: PuppetMath.worlds(locals: locals, parents: rig.parents)) : nil
            models = simulation.step(locals: locals, parents: rig.parents, delta: delta, objectWorld: world, adjust: adjust,
                                     ik: solver)
            self.simulation = simulation
        } else if let solver {
            let locals = pose.map(\.matrix)
            let adjust = rig.blendRules.contains(where: { !$0.isEmpty })
                ? PuppetBlendMath.adjust(rules: rig.blendRules, weights: blendWeights,
                                         fallback: PuppetMath.worlds(locals: locals, parents: rig.parents)) : nil
            models = solver.worlds(locals: locals, adjust: adjust)
        } else {
            models = showsPose ? rig.worlds(pose, blendWeights: blendWeights) : rig.bindWorld
        }
        worlds = models
        let palette = showsPose ? rig.palette(worlds: models) : models.map { _ in matrix_identity_float4x4 }
        positions = showsPose ? PuppetRig.skin(document, palette: palette) : document.mesh.vertices.map(\.position)
        renderPicture(document, posed: showsPose)
        renderHeatMap(document)
    }

    /// The largest side the preview's picture is drawn at.
    static let previewPixels: Float = 1024

    private func renderPicture(_ document: PuppetDocument, posed: Bool) {
        guard let source, let texture = source.texture else { picture = nil; return }
        let size = document.imageSize
        let half = size / 2
        if !posed, document.isTextureLayout, let image = source.image {
            // The bind pose of a rig laid out as its texture is the picture itself.
            picture = (image, (-half, half))
            return
        }
        guard !positions.isEmpty, !document.mesh.triangles.isEmpty else { picture = nil; return }
        var low = positions[0], high = positions[0]
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        let extent = max(high.x - low.x, high.y - low.y, 1)
        // Half the size while the preview runs on a clock: it is redrawn every frame.
        let limit = timer != nil ? Self.previewPixels / 2 : Self.previewPixels
        let scale = min(1, limit / extent)
        let viewport = PuppetRasterViewport(bounds: (low, high), scale: scale)
        let image = PuppetRasterizer.render(document, positions: positions, texture: texture, viewport: viewport)
        let topLeft = viewport.origin
        let bottomRight = SIMD2(topLeft.x + Float(viewport.width) / scale, topLeft.y - Float(viewport.height) / scale)
        picture = image.cgImage.map { ($0, (SIMD2(topLeft.x, bottomRight.y), SIMD2(bottomRight.x, topLeft.y))) }
    }

    private func renderHeatMap(_ document: PuppetDocument) {
        guard tool == .weights, showsHeatMap, let bone = selectedBone, !positions.isEmpty else { heatMap = nil; return }
        var low = positions[0], high = positions[0]
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        let extent = max(high.x - low.x, high.y - low.y, 1)
        let scale = min(1, 512 / extent)
        let viewport = PuppetRasterViewport(bounds: (low, high), scale: scale)
        let image = PuppetRasterizer.renderWeights(document, positions: positions, bone: bone, viewport: viewport)
        let topLeft = viewport.origin
        let bottomRight = SIMD2(topLeft.x + Float(viewport.width) / scale, topLeft.y - Float(viewport.height) / scale)
        heatMap = image.cgImage.map { ($0, (SIMD2(topLeft.x, bottomRight.y), SIMD2(bottomRight.x, topLeft.y))) }
    }

    /// The posed mesh at another frame of the clip (onion skin).
    func positions(atFrame other: Float) -> [SIMD2<Float>]? {
        guard let document, let rig, let clipIndex, document.clips.indices.contains(clipIndex) else { return nil }
        return PuppetRig.skin(document, palette: rig.palette(worlds: rig.worlds(clip: clipIndex, frame: other)))
    }

    /// The bones' segments in the shown pose.
    var segments: [(SIMD2<Float>, SIMD2<Float>)] {
        guard let document else { return [] }
        return PuppetAutoWeights.segments(document, worlds: worlds)
    }

    // MARK: Posing (Animate)

    /// The clip's key for `bone` at the current frame becomes `transform` (a draft while dragging).
    func setPoseKey(bone: Int, transform: PuppetTransform, draft isDraft: Bool) {
        guard let clipIndex else { return }
        let key = Int(frame.rounded())
        let change: (inout PuppetDocument) -> Void = { document in
            guard document.clips.indices.contains(clipIndex), document.clips[clipIndex].tracks.indices.contains(bone) else { return }
            document.clips[clipIndex].tracks[bone].keys[key] = transform
        }
        if isDraft { draft(change) } else { edit(PL("Set Key"), change) }
    }

    /// The pose's parent matrix of `bone` (model space).
    func poseParentWorld(of bone: Int) -> simd_float4x4 {
        guard let document, let parent = document.bones[bone].parent, worlds.indices.contains(parent) else {
            return matrix_identity_float4x4
        }
        return worlds[parent]
    }
}
