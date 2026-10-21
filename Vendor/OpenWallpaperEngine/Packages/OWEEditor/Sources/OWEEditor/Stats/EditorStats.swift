import SwiftUI
import OWEInspectorKit

/// The canvas's stats overlay mode (WE's View › Show Stats), kept with the editor's other choices.
@MainActor
final class EditorStatsSettings: ObservableObject {
    static let key = "WallpaperEditorShowStats"
    @Published var mode: RenderStatsMode {
        didSet { preferences.set(mode.rawValue, forKey: Self.key) }
    }
    private let preferences: UserDefaults

    init(preferences: UserDefaults) {
        self.preferences = preferences
        // Auto until chosen: only the numbers past WE's limits show.
        mode = preferences.string(forKey: Self.key).flatMap(RenderStatsMode.init(rawValue:)) ?? .auto
    }
}

/// The toolbar's Show Stats menu: Never, Auto (only warnings) or Always.
struct EditorStatsMenu: View {
    @ObservedObject var settings: EditorStatsSettings

    var body: some View {
        Menu {
            Picker(L("Show Stats"), selection: $settings.mode) {
                ForEach(RenderStatsMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(L("Show Stats"), systemImage: "gauge.with.dots.needle.33percent")
        }
        .help(L("Show the canvas’s frame statistics: draw calls, memory, particles, scripts"))
    }
}
