import AppKit
import SwiftUI
import OWESceneEditing

private struct SceneTimelineKey: EnvironmentKey {
    static let defaultValue: SceneTimelineEditor? = nil
}

extension EnvironmentValues {
    /// The window's timeline, for the inspector's keyframe buttons; nil without one.
    var sceneTimeline: SceneTimelineEditor? {
        get { self[SceneTimelineKey.self] }
        set { self[SceneTimelineKey.self] = newValue }
    }
}

/// The timeline docked under the canvas: shown while the timeline is active, its height dragged
/// from the bar between them and remembered.
struct TimelineDock<Content: View>: View {
    let timeline: SceneTimelineEditor?
    /// Where the height is kept: the app's defaults (`WallpaperEditorServices.preferences`), so a
    /// test or an isolated copy never writes the user's real domain.
    let preferences: UserDefaults
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let timeline {
            TimelineDockContent(timeline: timeline, content: content(), preferences: preferences)
        } else {
            content()
        }
    }
}

private struct TimelineDockContent<Content: View>: View {
    @ObservedObject var timeline: SceneTimelineEditor
    let content: Content
    @AppStorage private var height: Double
    @State private var dragStartHeight: Double?

    private static var heights: ClosedRange<Double> { 150...640 }

    init(timeline: SceneTimelineEditor, content: Content, preferences: UserDefaults) {
        self.timeline = timeline
        self.content = content
        _height = AppStorage(wrappedValue: 250, "WallpaperEditorTimelineHeight", store: preferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if timeline.isActive {
                resizeBar
                TimelinePanel(timeline: timeline, session: timeline.session)
                    .frame(height: min(max(height, Self.heights.lowerBound), Self.heights.upperBound))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: timeline.isActive)
    }

    private var resizeBar: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    height = min(max(start - drag.translation.height, Self.heights.lowerBound), Self.heights.upperBound)
                }
                .onEnded { _ in dragStartHeight = nil })
    }
}

/// The toolbar's switch for the timeline.
struct TimelineToolbarButton: View {
    @ObservedObject var timeline: SceneTimelineEditor

    var body: some View {
        Toggle(isOn: $timeline.isActive) {
            Label(T("Timeline"), systemImage: "timeline.selection")
        }
        .help(T("Show or hide the timeline"))
    }
}

/// The diamond beside an animatable property: adds a keyframe at the playhead, or removes the
/// one there (After Effects' and Motion's keyframe button). Filled on a keyframe, outlined in
/// the accent colour between keyframes, plain when the property isn't animated.
struct KeyframeButton: View {
    let target: TimelineTarget
    @Environment(\.sceneTimeline) private var timeline

    init(target: TimelineTarget) {
        self.target = target
    }

    var body: some View {
        if let timeline, timeline.index.property(target) != nil {
            KeyframeDiamond(timeline: timeline, target: target)
        }
    }
}

struct KeyframeDiamond: View {
    @ObservedObject var timeline: SceneTimelineEditor
    let target: TimelineTarget

    var body: some View {
        let state = timeline.keyState(target)
        let bound = timeline.index.property(target)?.isUserBound == true
        Button {
            timeline.toggleKeyframe(target, addName: T("Add Keyframe"), removeName: T("Remove Keyframe"))
        } label: {
            Image(systemName: symbol(state))
                .foregroundStyle(tint(state))
                .imageScale(.small)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(bound)
        .help(help(state, bound: bound))
        .accessibilityLabel(help(state, bound: bound))
    }

    private func symbol(_ state: SceneTimelineEditor.KeyState) -> String {
        switch state {
        case .none, .animated: return "diamond"
        case .keyed(let partial): return partial ? "diamond.bottomhalf.filled" : "diamond.fill"
        }
    }

    private func tint(_ state: SceneTimelineEditor.KeyState) -> AnyShapeStyle {
        if case .none = state { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tint)
    }

    private func help(_ state: SceneTimelineEditor.KeyState, bound: Bool) -> String {
        if bound { return T("A user property sets this value") }
        if case .keyed(partial: false) = state { return T("Remove the keyframe at the playhead") }
        return T("Add a keyframe at the playhead")
    }
}
