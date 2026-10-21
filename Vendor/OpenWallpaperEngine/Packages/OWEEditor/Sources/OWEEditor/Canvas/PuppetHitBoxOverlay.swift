import SwiftUI
import OWESceneEditing

/// A Puppet Warp bone's hit box as the canvas's renderer posed it last frame: the box a cursor
/// event's `hitBox` names the bone from.
public struct EditorHitBox: Equatable, Sendable {
    public var layerID: String
    /// The bone's index in its rig, which picks its colour.
    public var bone: Int
    public var name: String
    /// Its corners in scene units (y up), in order around it.
    public var corners: [SIMD2<Double>]

    public init(layerID: String, bone: Int, name: String, corners: [SIMD2<Double>]) {
        self.layerID = layerID
        self.bone = bone
        self.name = name
        self.corners = corners
    }
}

/// View › Show Debug › Show Hitboxes (WE's `ui_editor_filemenu_show_hitboxes`): every visible
/// puppet's hit boxes, one per bone in the bone's colour, posed as the scene plays. A bone that
/// moves no vertex has a 1-unit box, which shows as a dot.
struct PuppetHitBoxOverlay: View {
    let hitBoxes: () -> [EditorHitBox]
    let viewport: CanvasViewport

    /// Bone colours by index, as WE's puppet editor gives the first bones theirs.
    static let colors: [Color] = [.red, .green, .blue, .yellow, .purple, .cyan, .orange, .pink]

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, _ in
                for box in hitBoxes() where box.corners.count == 4 {
                    var path = Path()
                    path.addLines(box.corners.map { CGPoint(viewport.canvasPoint($0)) })
                    path.closeSubpath()
                    context.stroke(path, with: .color(Self.colors[box.bone % Self.colors.count]), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
