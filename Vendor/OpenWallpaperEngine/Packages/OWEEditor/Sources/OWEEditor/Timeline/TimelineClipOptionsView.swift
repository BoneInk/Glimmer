import SwiftUI
import OWESceneEditing

/// A clip's options as WE stores them (`options` of the `animation` block): frame rate, length in
/// frames, mode, wrap loop, start paused and the name scripts find it by.
struct TimelineClipOptionsView: View {
    @ObservedObject var timeline: SceneTimelineEditor
    let target: TimelineTarget
    let title: String

    var body: some View {
        Form {
            if let clip = timeline.clip(target) {
                Section {
                    TextField(T("Frame Rate"), value: binding(clip.fps, coalescing: "fps") { clip, fps in
                        if fps > 0, fps.isFinite { clip.fps = fps }
                    }, format: .number.precision(.fractionLength(0...3)))
                    TextField(T("Length (frames)"), value: binding(clip.length, coalescing: "length") { clip, length in
                        if length > 0 { clip.length = length }
                    }, format: .number)
                    LabeledContent(T("Duration")) {
                        Text(verbatim: TimelineNames.time(clip.duration)).monospacedDigit()
                    }
                    Picker(T("Mode"), selection: binding(clip.mode) { clip, mode in clip.mode = mode }) {
                        ForEach(TimelineClip.Mode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text(verbatim: title).font(.headline)
                }
                Section {
                    Toggle(isOn: binding(clip.wrapLoop) { clip, on in clip.wrapLoop = on }) {
                        Text(T("Wrap Loop"))
                        Text(T("Ends each channel on its first value, so the loop is seamless"))
                    }
                    Toggle(isOn: binding(clip.startPaused) { clip, on in clip.startPaused = on }) {
                        Text(T("Start Paused"))
                        Text(T("Holds the first frame until a script plays the timeline"))
                    }
                    TextField(T("Name"), text: binding(clip.name ?? "", coalescing: "name") { clip, name in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        clip.name = trimmed.isEmpty ? nil : trimmed
                    }, prompt: Text(T("What scripts find it by")))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A binding over one option: each change is an undo step, typing in one field coalesced.
    private func binding<Value>(_ value: Value, coalescing: String? = nil,
                                set: @escaping (inout TimelineClip, Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { newValue in
            timeline.change(target, actionName: T("Change Clip Options"),
                            coalescingKey: coalescing.map { "timeline-option-\($0)" }) { set(&$0, newValue) }
        })
    }
}
