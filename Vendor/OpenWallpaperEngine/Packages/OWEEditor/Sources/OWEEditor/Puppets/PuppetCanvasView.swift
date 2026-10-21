import AppKit
import OWESceneEditing
import simd
import SwiftUI
import OWEInspectorKit

/// Where the puppet's mesh space (the image's pixels, centred, y up) lands in the canvas.
struct PuppetCanvasMapping: Equatable {
    var zoom: Double = 1
    var pan = SIMD2<Double>.zero
    var size = SIMD2<Double>(800, 600)

    func view(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: size.x / 2 + pan.x + Double(p.x) * zoom, y: size.y / 2 + pan.y - Double(p.y) * zoom)
    }

    func mesh(_ v: SIMD2<Double>) -> SIMD2<Float> {
        SIMD2(Float((v.x - size.x / 2 - pan.x) / zoom), Float(-(v.y - size.y / 2 - pan.y) / zoom))
    }

    func rect(_ bounds: (min: SIMD2<Float>, max: SIMD2<Float>)) -> CGRect {
        let topLeft = view(SIMD2(bounds.min.x, bounds.max.y))
        return CGRect(x: topLeft.x, y: topLeft.y, width: Double(bounds.max.x - bounds.min.x) * zoom,
                      height: Double(bounds.max.y - bounds.min.y) * zoom)
    }

    /// Mesh units in `points` canvas points.
    func units(_ points: Double) -> Float { Float(points / max(zoom, 1e-6)) }

    mutating func fit(_ imageSize: SIMD2<Float>) {
        let room = SIMD2(max(size.x - 80, 1), max(size.y - 80, 1))
        zoom = min(room.x / Double(max(imageSize.x, 1)), room.y / Double(max(imageSize.y, 1)))
        pan = .zero
    }

    /// Zooms to `zoom` keeping the mesh point under `anchor` (canvas points) still.
    mutating func zoom(to value: Double, anchor: SIMD2<Double>) {
        let fixed = mesh(anchor)
        zoom = min(max(value, 0.02), 64)
        let moved = view(fixed)
        pan += anchor - SIMD2(moved.x, moved.y)
    }
}

/// The puppet editor's canvas: the picture through the posed mesh, the mesh, the bones, the
/// weight heat map and the onion skin, and the pointer input of each tool.
struct PuppetCanvasView: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var workspace: PuppetWorkspace
    @State private var mapping = PuppetCanvasMapping()
    @State private var drag: Drag?
    @State private var hover: SIMD2<Float>?
    @State private var fitted = false

    private enum Drag {
        case pan(startPan: SIMD2<Double>, start: SIMD2<Double>)
        case vertices(start: SIMD2<Float>, original: [Int: SIMD2<Float>], textureLayout: Bool, moved: Bool)
        case marquee(start: SIMD2<Double>, current: SIMD2<Double>, adding: Bool)
        case boneMove(bone: Int, startHead: SIMD2<Float>, start: SIMD2<Float>, keepChildren: Bool, moved: Bool)
        case boneRotate(bone: Int, moved: Bool)
        case boneAdd(start: SIMD2<Float>, current: SIMD2<Float>)
        case paint(last: SIMD2<Float>, bone: Int, brush: PuppetWeightBrush)
        case poseMove(bone: Int, base: PuppetTransform, grab: SIMD2<Float>, moved: Bool)
        case poseRotate(bone: Int, base: PuppetTransform, startAngle: Float, moved: Bool)
        case shake(startOffset: SIMD2<Float>, start: SIMD2<Float>)
        case controller(bone: Int, controller: PuppetBoneIK.Controller, grab: SIMD2<Float>, moved: Bool)
        case maskPaint
    }

    /// Hit radius, canvas points.
    private static let reach: Double = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Canvas { context, _ in draw(&context) }
                if let painting = workspace.clippingPainting {
                    PuppetClippingPaintOverlay(painting: painting, mapping: mapping, imageSize: workspace.imageSize, hover: hover)
                        .allowsHitTesting(false)
                }
                CanvasEventView(handlers: handlers)
            }
            .onAppear {
                mapping.size = SIMD2(Double(proxy.size.width), Double(proxy.size.height))
                if !fitted {
                    mapping.fit(workspace.imageSize)
                    fitted = true
                }
            }
            .onChange(of: proxy.size) { _, size in mapping.size = SIMD2(Double(size.width), Double(size.height)) }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Button { mapping.zoom(to: mapping.zoom / 1.25, anchor: mapping.size / 2) } label: {
                    Label(PL("Zoom Out"), systemImage: "minus.magnifyingglass").labelStyle(.iconOnly)
                }
                Button { mapping.fit(workspace.imageSize) } label: {
                    Text(verbatim: (mapping.zoom).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(minWidth: 44)
                }
                .help(PL("Zoom to Fit"))
                Button { mapping.zoom(to: mapping.zoom * 1.25, anchor: mapping.size / 2) } label: {
                    Label(PL("Zoom In"), systemImage: "plus.magnifyingglass").labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .editorGlass(in: Capsule())
            .padding(12)
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext) {
        guard let document = workspace.document else { return }
        let half = document.imageSize / 2
        let frame = Path(mapping.rect((-half, half)))
        context.stroke(frame, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        if let picture = workspace.picture {
            context.draw(Image(decorative: picture.image, scale: 1), in: mapping.rect(picture.bounds))
        }
        if workspace.tool == .weights, let heat = workspace.heatMap {
            context.draw(Image(decorative: heat.image, scale: 1), in: mapping.rect(heat.bounds))
        }
        let positions = workspace.positions
        if workspace.tool == .animate, workspace.showsOnionSkin, let clip = workspace.clip {
            for step in 1...max(workspace.onionFrames, 1) {
                let fade = 0.5 / Double(step)
                for (sign, colour) in [(Float(-1), Color.red), (Float(1), Color.green)] {
                    let other = workspace.frame + sign * Float(step)
                    guard other >= 0, other <= Float(clip.frames), let posed = workspace.positions(atFrame: other) else { continue }
                    context.stroke(outline(document, posed), with: .color(colour.opacity(fade)), lineWidth: 1.5)
                }
            }
        }
        let wireframeOpacity: Double = workspace.tool == .mesh ? 0.9 : workspace.tool == .weights ? 0.45 : 0.18
        context.stroke(wireframe(document, positions), with: .color(.white.opacity(wireframeOpacity)), lineWidth: 0.75)
        context.stroke(wireframe(document, positions), with: .color(.black.opacity(wireframeOpacity * 0.4)),
                       style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
        if workspace.tool == .mesh {
            for (index, p) in positions.enumerated() {
                let point = mapping.view(p)
                let selected = workspace.selectedVertices.contains(index)
                let size: Double = selected ? 7 : 5
                let dot = Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
                context.fill(dot, with: .color(selected ? accentColor : .white))
                context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 0.75)
            }
        }
        if workspace.tool == .clipping {
            drawLimbs(&context, document, positions)
        } else if workspace.tool != .mesh {
            drawBones(&context, document)
        }
        if workspace.tool == .animate || workspace.tool == .physics { drawControllers(&context) }
        switch drag {
        case let .marquee(start, current, _):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x),
                              height: abs(current.y - start.y))
            context.fill(Path(rect), with: .color(accentColor.opacity(0.12)))
            context.stroke(Path(rect), with: .color(accentColor), lineWidth: 1)
        case let .boneAdd(start, current):
            var line = Path()
            line.move(to: mapping.view(start))
            line.addLine(to: mapping.view(current))
            context.stroke(line, with: .color(accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
        default:
            break
        }
        if workspace.tool == .weights, let hover {
            let centre = mapping.view(hover)
            let radius = Double(workspace.brush.radius) * mapping.zoom
            let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
            context.stroke(circle, with: .color(.white), lineWidth: 1.5)
            context.stroke(circle, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    /// The Clipping Masks tool: the selected limb, the limbs its mask is painted over, and the
    /// other clipped limbs.
    private func drawLimbs(_ context: inout GraphicsContext, _ document: PuppetDocument, _ positions: [SIMD2<Float>]) {
        guard positions.count == document.mesh.vertices.count else { return }
        let islands = document.mesh.islands
        let clipping = workspace.clipping
        let masking = Set(workspace.selectedLimbMask?.maskingLimbs ?? [])
        var selected = Path(), painted = Path(), clipped = Path()
        for (index, t) in document.mesh.triangles.enumerated() where index < islands.count {
            let limb = islands[index]
            var triangle = Path()
            triangle.move(to: mapping.view(positions[Int(t.x)]))
            triangle.addLine(to: mapping.view(positions[Int(t.y)]))
            triangle.addLine(to: mapping.view(positions[Int(t.z)]))
            triangle.closeSubpath()
            if limb == workspace.selectedLimb {
                selected.addPath(triangle)
            } else if masking.contains(limb) {
                painted.addPath(triangle)
            } else if clipping.limbs.indices.contains(limb), clipping.limbs[limb] != nil {
                clipped.addPath(triangle)
            }
        }
        context.fill(clipped, with: .color(.orange.opacity(0.15)))
        context.fill(painted, with: .color(.green.opacity(0.2)))
        context.fill(selected, with: .color(accentColor.opacity(0.3)))
    }

    private func wireframe(_ document: PuppetDocument, _ positions: [SIMD2<Float>]) -> Path {
        var path = Path()
        guard positions.count == document.mesh.vertices.count else { return path }
        for t in document.mesh.triangles {
            let a = mapping.view(positions[Int(t.x)]), b = mapping.view(positions[Int(t.y)]), c = mapping.view(positions[Int(t.z)])
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            path.closeSubpath()
        }
        return path
    }

    private func outline(_ document: PuppetDocument, _ positions: [SIMD2<Float>]) -> Path {
        var path = Path()
        guard positions.count == document.mesh.vertices.count else { return path }
        for (a, b) in document.mesh.boundaryEdges {
            path.move(to: mapping.view(positions[Int(a)]))
            path.addLine(to: mapping.view(positions[Int(b)]))
        }
        return path
    }

    private func drawBones(_ context: inout GraphicsContext, _ document: PuppetDocument) {
        let segments = workspace.segments
        for (index, segment) in segments.enumerated() {
            let selected = workspace.selectedBone == index
            let head = mapping.view(segment.0), tail = mapping.view(segment.1)
            let dx = tail.x - head.x, dy = tail.y - head.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            let width = min(8, length * 0.2)
            let normal = CGPoint(x: -dy / length * width, y: dx / length * width)
            let shoulder = CGPoint(x: head.x + dx * 0.18, y: head.y + dy * 0.18)
            var shape = Path()
            shape.move(to: head)
            shape.addLine(to: CGPoint(x: shoulder.x + normal.x, y: shoulder.y + normal.y))
            shape.addLine(to: tail)
            shape.addLine(to: CGPoint(x: shoulder.x - normal.x, y: shoulder.y - normal.y))
            shape.closeSubpath()
            let physics = document.bones.indices.contains(index) && document.bones[index].physics != nil
            let fill: Color = selected ? accentColor : physics ? .orange : .white
            context.fill(shape, with: .color(fill.opacity(selected ? 0.85 : 0.6)))
            context.stroke(shape, with: .color(.black.opacity(0.7)), lineWidth: 1)
            let joint = Path(ellipseIn: CGRect(x: head.x - 5, y: head.y - 5, width: 10, height: 10))
            context.fill(joint, with: .color(selected ? accentColor : .white))
            context.stroke(joint, with: .color(.black.opacity(0.7)), lineWidth: 1)
            if selected, workspace.tool == .skeleton || workspace.tool == .animate {
                let handle = Path(ellipseIn: CGRect(x: tail.x - 5, y: tail.y - 5, width: 10, height: 10))
                context.fill(handle, with: .color(.white))
                context.stroke(handle, with: .color(accentColor), lineWidth: 2)
            }
        }
    }

    /// The kinematic chains' controllers, as WE's viewport shows them in animation mode: the IK
    /// target as a diamond, the orientation controller as a dot, each tied to its chain's end.
    private func drawControllers(_ context: inout GraphicsContext) {
        let segments = workspace.segments
        for item in workspace.controllers {
            let point = mapping.view(item.place)
            if segments.indices.contains(item.bone) {
                var tie = Path()
                tie.move(to: mapping.view(segments[item.bone].0))
                tie.addLine(to: point)
                context.stroke(tie, with: .color(.yellow.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            let size: Double = 7
            var shape = Path()
            switch item.controller {
            case .target:
                shape.move(to: CGPoint(x: point.x, y: point.y - size))
                shape.addLine(to: CGPoint(x: point.x + size, y: point.y))
                shape.addLine(to: CGPoint(x: point.x, y: point.y + size))
                shape.addLine(to: CGPoint(x: point.x - size, y: point.y))
                shape.closeSubpath()
            case .orientation:
                shape = Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            }
            let selected = workspace.selectedBone == item.bone
            context.fill(shape, with: .color(item.controller == .target ? .orange : .yellow))
            context.stroke(shape, with: .color(selected ? accentColor : .black.opacity(0.7)), lineWidth: selected ? 2 : 1)
        }
    }

    // MARK: Hit testing

    private func controller(at point: SIMD2<Double>) -> (bone: Int, controller: PuppetBoneIK.Controller, place: SIMD2<Float>)? {
        workspace.controllers.reversed().first { item in
            let view = mapping.view(item.place)
            return hypot(view.x - point.x, view.y - point.y) <= Self.reach
        }
    }

    private func bone(atJoint point: SIMD2<Double>) -> Int? {
        let segments = workspace.segments
        return segments.indices.reversed().first { index in
            let head = mapping.view(segments[index].0)
            return hypot(head.x - point.x, head.y - point.y) <= Self.reach
        }
    }

    private func bone(onSegment point: SIMD2<Double>) -> Int? {
        let p = mapping.mesh(point)
        let segments = workspace.segments
        let reach = mapping.units(Self.reach * 0.75)
        return segments.indices.reversed().first { PuppetMath.distance(p, segment: segments[$0].0, segments[$0].1) <= reach }
    }

    private func isOnTailHandle(_ point: SIMD2<Double>) -> Bool {
        guard let bone = workspace.selectedBone, workspace.segments.indices.contains(bone) else { return false }
        let tail = mapping.view(workspace.segments[bone].1)
        return hypot(tail.x - point.x, tail.y - point.y) <= Self.reach
    }

    private func vertex(at point: SIMD2<Double>) -> Int? {
        let p = mapping.mesh(point)
        let reach = mapping.units(Self.reach)
        var best: (Int, Float)?
        for (index, q) in workspace.positions.enumerated() {
            let d = simd_distance(p, q)
            if d <= reach, d < (best?.1 ?? .infinity) { best = (index, d) }
        }
        return best?.0
    }

    // MARK: Input

    private var handlers: CanvasEventView.Handlers {
        var handlers = CanvasEventView.Handlers()
        handlers.mouseDown = { point, event, pans in mouseDown(point, event: event, pans: pans) }
        handlers.mouseDragged = { point, event in mouseDragged(point, event: event) }
        handlers.mouseUp = { point, event in mouseUp(point, event: event) }
        handlers.mouseMoved = { point in hover = point.map { mapping.mesh($0) } }
        handlers.scroll = { delta, point, event in
            if event.modifierFlags.contains(.command) {
                mapping.zoom(to: mapping.zoom * (1 + delta.y / 200), anchor: point)
            } else {
                mapping.pan += delta
            }
        }
        handlers.magnify = { factor, point in mapping.zoom(to: mapping.zoom * factor, anchor: point) }
        handlers.key = { event in key(event) }
        handlers.cursor = { _ in
            switch workspace.tool {
            case .mesh: return workspace.meshTool == .add ? .crosshair : .arrow
            case .skeleton: return workspace.skeletonTool == .add ? .crosshair : .arrow
            case .weights: return .crosshair
            case .animate, .physics: return .arrow
            case .clipping: return workspace.clippingPainting != nil ? .crosshair : .arrow
            }
        }
        return handlers
    }

    private func mouseDown(_ point: SIMD2<Double>, event: NSEvent, pans: Bool) {
        guard workspace.document != nil else { return }
        if pans {
            drag = .pan(startPan: mapping.pan, start: point)
            return
        }
        let p = mapping.mesh(point)
        let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
        switch workspace.tool {
        case .mesh:
            if workspace.meshTool == .add {
                workspace.edit(PL("Add Vertex")) { $0.addVertex(at: p) }
                workspace.selectedVertices = [workspace.positions.count - 1]
                return
            }
            if let hit = vertex(at: point) {
                if shift {
                    workspace.selectedVertices.formSymmetricDifference([hit])
                } else if !workspace.selectedVertices.contains(hit) {
                    workspace.selectedVertices = [hit]
                }
                let original = Dictionary(uniqueKeysWithValues: workspace.selectedVertices.map { ($0, workspace.positions[$0]) })
                drag = .vertices(start: p, original: original, textureLayout: workspace.document?.isTextureLayout ?? true, moved: false)
            } else {
                if !shift { workspace.selectedVertices = [] }
                drag = .marquee(start: point, current: point, adding: shift)
            }
        case .skeleton:
            if workspace.skeletonTool == .add {
                drag = .boneAdd(start: p, current: p)
                return
            }
            if isOnTailHandle(point), let bone = workspace.selectedBone {
                drag = .boneRotate(bone: bone, moved: false)
            } else if let bone = bone(atJoint: point) ?? bone(onSegment: point) {
                workspace.selectedBone = bone
                let head = PuppetMath.origin(of: workspace.worlds[bone])
                drag = .boneMove(bone: bone, startHead: head, start: p, keepChildren: option, moved: false)
            } else {
                workspace.selectedBone = nil
            }
        case .weights:
            if let bone = bone(atJoint: point) {
                workspace.selectedBone = bone
                workspace.refreshPose()
                return
            }
            guard let bone = workspace.selectedBone else { return }
            var brush = workspace.brush
            if option { brush.mode = brush.mode == .subtract ? .add : .subtract }
            workspace.draft { brush.apply(to: &$0, bone: bone, at: p) }
            drag = .paint(last: p, bone: bone, brush: brush)
        case .animate:
            guard workspace.clip != nil else { return }
            if let hit = controller(at: point) {
                workspace.selectedBone = hit.bone
                drag = .controller(bone: hit.bone, controller: hit.controller, grab: p - hit.place, moved: false)
            } else if isOnTailHandle(point), let bone = workspace.selectedBone, let base = workspace.keyTransform(of: bone) {
                let head = PuppetMath.origin(of: workspace.worlds[bone])
                drag = .poseRotate(bone: bone, base: base, startAngle: atan2(p.y - head.y, p.x - head.x), moved: false)
            } else if let bone = bone(atJoint: point) ?? bone(onSegment: point) {
                workspace.selectedBone = bone
                guard let base = workspace.keyTransform(of: bone) else { return }
                let head = PuppetMath.origin(of: workspace.worlds[bone])
                drag = .poseMove(bone: bone, base: base, grab: p - head, moved: false)
            } else {
                workspace.selectedBone = nil
            }
        case .physics:
            if let bone = bone(atJoint: point) ?? bone(onSegment: point) {
                workspace.selectedBone = bone
            } else {
                drag = .shake(startOffset: workspace.objectOffset, start: p)
            }
        case .clipping:
            if let painting = workspace.clippingPainting {
                painting.begin(at: SIMD2<Double>(p))
                drag = .maskPaint
            } else {
                workspace.selectedLimb = workspace.document?.limb(at: p)
            }
        }
    }

    private func mouseDragged(_ point: SIMD2<Double>, event: NSEvent) {
        let p = mapping.mesh(point)
        switch drag {
        case let .pan(startPan, start):
            mapping.pan = startPan + (point - start)
        case let .vertices(start, original, textureLayout, _):
            let delta = p - start
            workspace.draft { document in
                for (index, position) in original { document.moveVertex(index, to: position + delta, textureLayout: textureLayout) }
            }
            drag = .vertices(start: start, original: original, textureLayout: textureLayout, moved: true)
        case let .marquee(start, _, adding):
            drag = .marquee(start: start, current: point, adding: adding)
        case let .boneMove(bone, startHead, start, keepChildren, _):
            workspace.draft { $0.moveBone(bone, toHead: startHead + (p - start), keepingChildren: keepChildren) }
            drag = .boneMove(bone: bone, startHead: startHead, start: start, keepChildren: keepChildren, moved: true)
        case let .boneRotate(bone, _):
            guard workspace.worlds.indices.contains(bone) else { return }
            let head = PuppetMath.origin(of: workspace.worlds[bone])
            var angle = atan2(p.y - head.y, p.x - head.x)
            if event.modifierFlags.contains(.shift) { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
            let leaf = workspace.document?.children(of: bone).isEmpty ?? false
            let length = simd_distance(p, head)
            workspace.draft { document in
                document.rotateBone(bone, toAngle: angle)
                if leaf { document.bones[bone].length = length }
            }
            drag = .boneRotate(bone: bone, moved: true)
        case let .boneAdd(start, _):
            drag = .boneAdd(start: start, current: p)
        case let .paint(last, bone, brush):
            // A dab every quarter of the brush.
            guard simd_distance(last, p) >= max(brush.radius * 0.25, mapping.units(2)) else { return }
            workspace.draft { brush.apply(to: &$0, bone: bone, at: p) }
            drag = .paint(last: p, bone: bone, brush: brush)
        case let .poseMove(bone, base, grab, _):
            let parentWorld = workspace.poseParentWorld(of: bone)
            let target = p - grab
            let local = parentWorld.inverse * SIMD4(target.x, target.y, 0, 1)
            var transform = base
            transform.translation = SIMD3(local.x, local.y, base.translation.z)
            workspace.setPoseKey(bone: bone, transform: transform, draft: true)
            drag = .poseMove(bone: bone, base: base, grab: grab, moved: true)
        case let .poseRotate(bone, base, startAngle, _):
            guard workspace.worlds.indices.contains(bone) else { return }
            let head = PuppetMath.origin(of: workspace.worlds[bone])
            var delta = atan2(p.y - head.y, p.x - head.x) - startAngle
            if event.modifierFlags.contains(.shift) { delta = (delta / (.pi / 12)).rounded() * (.pi / 12) }
            var transform = base
            transform.euler.z = base.euler.z + delta
            workspace.setPoseKey(bone: bone, transform: transform, draft: true)
            drag = .poseRotate(bone: bone, base: base, startAngle: startAngle, moved: true)
        case let .shake(startOffset, start):
            workspace.objectOffset = startOffset + (p - start)
        case let .controller(bone, controller, grab, _):
            workspace.setController(bone: bone, controller, to: p - grab, draft: true)
            drag = .controller(bone: bone, controller: controller, grab: grab, moved: true)
        case .maskPaint:
            workspace.clippingPainting?.dab(to: SIMD2<Double>(p))
        case nil:
            break
        }
    }

    private func mouseUp(_ point: SIMD2<Double>, event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case let .vertices(_, _, _, moved):
            if moved { workspace.endDraft(PL("Move Vertices")) }
        case let .marquee(start, current, adding):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x),
                              height: abs(current.y - start.y))
            let inside = Set(workspace.positions.indices.filter { rect.contains(mapping.view(workspace.positions[$0])) })
            workspace.selectedVertices = adding ? workspace.selectedVertices.union(inside) : inside
        case let .boneMove(_, _, _, _, moved):
            if moved { workspace.endDraft(PL("Move Bone")) }
        case let .boneRotate(_, moved):
            if moved { workspace.endDraft(PL("Rotate Bone")) }
        case let .boneAdd(start, current):
            let length = simd_distance(start, current)
            let long = length >= mapping.units(4)
            let angle = long ? atan2(current.y - start.y, current.x - start.x) : 0
            let parent = workspace.selectedBone
            var added = 0
            workspace.edit(PL("Add Bone")) { document in
                added = document.addBone(named: PL("Bone"), parent: parent, head: start, angle: angle, length: long ? length : nil)
            }
            workspace.selectedBone = added
        case .paint:
            workspace.endDraft(PL("Paint Weights"))
        case let .poseMove(_, _, _, moved), let .poseRotate(_, _, _, moved):
            if moved { workspace.endDraft(PL("Set Key")) }
        case let .controller(_, controller, _, moved):
            if moved { workspace.endDraft(controller == .target ? PL("Move IK Target") : PL("Move Orientation Controller")) }
        case .maskPaint:
            workspace.clippingPainting?.end()
        default:
            break
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            switch workspace.tool {
            case .mesh: workspace.deleteSelectedVertices()
            case .skeleton: workspace.deleteSelectedBone()
            case .animate: workspace.deleteKey()
            default: return false
            }
            return true
        case 53: // Escape
            if drag != nil {
                workspace.cancelDraft()
                drag = nil
            } else {
                workspace.selectedVertices = []
                workspace.selectedBone = nil
            }
            return true
        default:
            return false
        }
    }
}

/// A clipping mask being painted, over the image (texture space: the bind pose's image rect), and
/// the brush under the pointer.
private struct PuppetClippingPaintOverlay: View {
    @ObservedObject var painting: MaskPainting
    let mapping: PuppetCanvasMapping
    let imageSize: SIMD2<Float>
    let hover: SIMD2<Float>?

    var body: some View {
        Canvas { context, _ in
            _ = painting.revision
            let half = imageSize / 2
            if let image = painting.image {
                context.opacity = 0.45
                context.draw(Image(decorative: image, scale: 1), in: mapping.rect((-half, half)))
                context.opacity = 1
            }
            if let hover {
                let centre = mapping.view(hover)
                let radius = painting.brushSize / 2 * mapping.zoom
                let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
                context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                context.stroke(circle, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
    }
}
