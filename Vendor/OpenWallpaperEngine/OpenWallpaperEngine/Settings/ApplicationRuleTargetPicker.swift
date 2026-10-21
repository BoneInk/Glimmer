import SwiftUI

/// What application rules' load actions pick from: the library's wallpapers, the playlists and
/// the saved display profiles. Set by the app delegate on the settings window; empty in previews
/// and tests.
struct ApplicationRuleLibrary {
    var wallpapers: @MainActor () -> [WEWallpaper] = { [] }
    var playlists: @MainActor () -> [WallpaperPlaylist] = { [] }
    var profiles: @MainActor () -> any DisplayProfileLoading = { UnavailableDisplayProfiles() }
}

extension EnvironmentValues {
    @Entry var applicationRuleLibrary = ApplicationRuleLibrary()
}

/// The wallpaper, playlist or profile a rule's load action loads (WE's rule `file`), picked from
/// the library as WE's rule editor does.
struct ApplicationRuleTargetPicker: View {
    @Binding var rule: ApplicationRule
    @Environment(\.applicationRuleLibrary) private var library
    @State private var isChoosingWallpaper = false

    var body: some View {
        switch rule.action.loadKind {
        case .wallpaper: wallpaperButton
        case .playlist: playlistMenu
        case .profile: profileMenu
        case nil: EmptyView()
        }
    }

    /// The chosen item's name, or what to do while there is none.
    private var chosenLabel: Text {
        if let name = rule.fileName, rule.file != nil { return Text(verbatim: name) }
        switch rule.action.loadKind {
        case .wallpaper: return Text("Choose Wallpaper…")
        case .playlist: return Text("Choose Playlist")
        default: return Text("Choose Profile")
        }
    }

    private func choose(file: String, name: String) {
        rule.file = file
        rule.fileName = name
    }

    private var wallpaperButton: some View {
        Button {
            isChoosingWallpaper = true
        } label: {
            Label { chosenLabel } icon: { Image(systemName: "photo") }
        }
        .glassButtonStyle()
        .popover(isPresented: $isChoosingWallpaper, arrowEdge: .bottom) {
            ApplicationRuleWallpaperList(wallpapers: library.wallpapers(), chosen: rule.file) { wallpaper in
                choose(file: wallpaper.identityPath, name: wallpaper.project.title)
                isChoosingWallpaper = false
            }
        }
    }

    private var playlistMenu: some View {
        let playlists = library.playlists()
        return Menu {
            if playlists.isEmpty {
                Text("No Playlists")
            }
            ForEach(playlists) { playlist in
                Button {
                    choose(file: playlist.id.uuidString, name: playlist.name)
                } label: {
                    Text(verbatim: playlist.name)
                }
            }
        } label: {
            Label { chosenLabel } icon: { Image(systemName: "list.bullet.rectangle") }
        }
        .fixedSize()
    }

    private var profileMenu: some View {
        let names = library.profiles().profileNames
        return HStack {
            Menu {
                if names.isEmpty {
                    Text("No Saved Profiles")
                }
                ForEach(names, id: \.self) { name in
                    Button {
                        choose(file: name, name: name)
                    } label: {
                        Text(verbatim: name)
                    }
                }
            } label: {
                Label { chosenLabel } icon: { Image(systemName: "rectangle.3.group") }
            }
            .fixedSize()
            // A profile deleted since the rule chose it: the rule skips it.
            if let file = rule.file, !file.isEmpty, !names.contains(file) {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The library's wallpapers to pick from, with a search field, as WE's rule editor lists its
/// wallpaper cache.
private struct ApplicationRuleWallpaperList: View {
    let wallpapers: [WEWallpaper]
    let chosen: String?
    let choose: (WEWallpaper) -> Void
    @State private var query = ""

    private var matches: [WEWallpaper] {
        let sorted = wallpapers.sorted { $0.project.title.localizedStandardCompare($1.project.title) == .orderedAscending }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.project.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            List(matches, id: \.identityPath) { wallpaper in
                Button {
                    choose(wallpaper)
                } label: {
                    HStack {
                        Text(verbatim: wallpaper.project.title)
                            .lineLimit(1)
                        Spacer()
                        if wallpaper.identityPath == chosen {
                            Image(systemName: "checkmark")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if matches.isEmpty {
                    Text("No Wallpapers")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 360)
    }
}
