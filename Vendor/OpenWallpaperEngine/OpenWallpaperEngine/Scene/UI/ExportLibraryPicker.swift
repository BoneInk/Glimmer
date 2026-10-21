import SwiftUI

/// The library to pick a batch export's wallpapers from ("Export More with These Settings…"): a
/// search field, a type filter and a list to tick, the ones the export can't take shown disabled
/// with why.
struct ExportLibraryPicker: View {
    enum TypeFilter: String, CaseIterable, Identifiable {
        case all, scene, video, web

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .all: return LocalizedStringResource("All", comment: "Batch export picker: every wallpaper type")
            case .scene: return LocalizedLabels.filterOption("Scene")
            case .video: return LocalizedLabels.filterOption("Video")
            case .web: return LocalizedLabels.filterOption("Web")
            }
        }

        func matches(_ wallpaper: WEWallpaper) -> Bool {
            let type = wallpaper.project.type.lowercased()
            switch self {
            case .all: return true
            case .scene: return type == "scene"
            case .video: return SceneContentLoader.isVideoType(type)
            case .web: return type == "web"
            }
        }
    }

    let wallpapers: [WEWallpaper]
    /// Why the export can't take a wallpaper; nil when it can.
    let skipReason: @MainActor (WEWallpaper) -> String?
    /// The ticked wallpapers' `identityPath`s.
    @Binding var selection: Set<String>
    @State private var query = ""
    @State private var filter = TypeFilter.all

    /// `wallpapers` whose title or tags match `query` and whose type matches `filter`, by title.
    static func matches(_ wallpapers: [WEWallpaper], query: String, filter: TypeFilter) -> [WEWallpaper] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return wallpapers
            .filter { filter.matches($0) }
            .filter { wallpaper in
                trimmed.isEmpty || wallpaper.project.displayTitle.localizedCaseInsensitiveContains(trimmed)
                    || (wallpaper.project.tags ?? []).contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
            .sorted { $0.project.displayTitle.localizedStandardCompare($1.project.displayTitle) == .orderedAscending }
    }

    /// The library for a batch of `edited`: `library` with it, whatever the library lists.
    static func library(_ library: [WEWallpaper], with edited: WEWallpaper) -> [WEWallpaper] {
        library.contains { $0.isSameWallpaper(as: edited) } ? library : [edited] + library
    }

    /// What a batch exports, in its order: the edited wallpaper first, then the others ticked, by title.
    static func picked(_ wallpapers: [WEWallpaper], selection: Set<String>, edited: WEWallpaper) -> [WEWallpaper] {
        let chosen = matches(wallpapers, query: "", filter: .all).filter { selection.contains($0.identityPath) }
        return chosen.filter { $0.isSameWallpaper(as: edited) } + chosen.filter { !$0.isSameWallpaper(as: edited) }
    }

    var body: some View {
        let shown = Self.matches(wallpapers, query: query, filter: filter)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $query, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $filter) {
                    ForEach(TypeFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            List(shown, id: \.identityPath) { wallpaper in
                row(wallpaper)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Text("\(selection.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All Shown") {
                    selection.formUnion(shown.filter { skipReason($0) == nil }.map(\.identityPath))
                }
                Button("Select None") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func row(_ wallpaper: WEWallpaper) -> some View {
        let reason = skipReason(wallpaper)
        Toggle(isOn: Binding(get: { selection.contains(wallpaper.identityPath) }, set: { on in
            if on { selection.insert(wallpaper.identityPath) } else { selection.remove(wallpaper.identityPath) }
        })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: wallpaper.project.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: reason ?? LocalizedLabels.wallpaperType(wallpaper.project.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .disabled(reason != nil)
        .help(Text(verbatim: reason ?? wallpaper.project.displayTitle))
    }
}
