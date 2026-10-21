import SwiftUI

/// The Downloads tab: Workshop downloads grouped as Safari and the App Store list theirs, the
/// running one first, then the queue, the failed ones and the finished ones.
struct DownloadsView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var selection: Set<String> = []

    private var sections: DownloadSections {
        DownloadSections(progress: steamCmd.downloadProgress, activeId: steamCmd.activeDownloadId,
                         queuedIds: steamCmd.queuedDownloadIds, startedAt: steamCmd.downloadStartedAt)
    }

    var body: some View {
        let sections = sections
        VStack(spacing: 0) {
            if let problem = steamCmdProblem {
                DownloadsProblemBanner(message: problem)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Workshop downloads and failed retries appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(sections)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy) { steamCmd.retryFailedDownloads(sections.failed) }
                } label: {
                    Label("Retry All Failed", systemImage: "arrow.clockwise")
                }
                .help("Starts every failed download again")
                .disabled(sections.failed.isEmpty || !canDownload)
                Button {
                    withAnimation(.snappy) { steamCmd.clearCompletedDownloads() }
                } label: {
                    Label("Clear Completed", systemImage: "checkmark.circle.badge.xmark")
                }
                .help("Removes the finished downloads from this list. They stay in your library.")
                .disabled(sections.completed.isEmpty)
            }
        }
        #if DEBUG
        .task { steamCmd.loadScreenshotFixtureIfRequested() }
        #endif
    }

    private func list(_ sections: DownloadSections) -> some View {
        List(selection: $selection) {
            ForEach(DownloadSections.Kind.allCases, id: \.self) { kind in
                let ids = sections.ids(kind)
                if !ids.isEmpty {
                    Section {
                        ForEach(ids, id: \.self) { workshopId in
                            DownloadRow(workshopId: workshopId, kind: kind, steamCmd: steamCmd,
                                        canDownload: canDownload, actions: actions)
                                .tag(workshopId)
                        }
                    } header: {
                        DownloadSectionHeader(kind: kind, count: ids.count)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            DownloadMenu(ids: ids, sections: sections, canDownload: canDownload, actions: actions)
        } primaryAction: { ids in
            // Return or a double-click: what the row's main button does.
            for id in ids { actions.primary(id, sections) }
        }
        .animation(.snappy, value: sections)
    }

    private var canDownload: Bool { steamCmd.isInstalled && steamCmd.isLoggedIn }

    /// Why downloads can't start now, in steamcmd's or the login's words.
    private var steamCmdProblem: String? {
        if !steamCmd.isInstalled {
            return String(localized: "Set up SteamCMD in the Workshop tab first.")
        }
        if !steamCmd.isLoggedIn {
            return steamCmd.loginError
                ?? String(localized: "Log in to Steam to download. You can do it in the Workshop tab or the setup assistant.")
        }
        return nil
    }

    private var actions: DownloadActions {
        DownloadActions(steamCmd: steamCmd, wallpaperViewModel: wallpaperViewModel)
    }
}

/// What a row, its menu and the keyboard can do with a download.
@MainActor
struct DownloadActions {
    let steamCmd: SteamCmdService
    let wallpaperViewModel: WallpaperViewModel

    func retry(_ id: String) { steamCmd.retryDownload(id) }

    func folder(_ id: String) -> URL? { steamCmd.downloadFolders[id] }

    func showInFinder(_ id: String) {
        guard let folder = folder(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func setAsWallpaper(_ id: String) {
        guard let folder = folder(id) else { return }
        guard let wallpaper = InstalledLibrary.wallpaper(at: folder, hiding: []) else {
            OWELog.error(.workshop, "Workshop item \(id) downloaded, but \(folder.lastPathComponent) holds no wallpaper to set")
            return
        }
        wallpaperViewModel.inspectAndApply(wallpaper)
    }

    /// Return or a double-click on a row: Retry a failed one, set a finished one.
    func primary(_ id: String, _ sections: DownloadSections) {
        if sections.failed.contains(id) {
            retry(id)
        } else if sections.completed.contains(id) {
            setAsWallpaper(id)
        }
    }
}

private struct DownloadSectionHeader: View {
    let kind: DownloadSections.Kind
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .inProgress: return "In Progress"
        case .queued: return "Queued"
        case .failed: return "Failed"
        case .completed: return "Completed"
        }
    }
}

/// The right-click menu of the selected downloads.
private struct DownloadMenu: View {
    let ids: Set<String>
    let sections: DownloadSections
    let canDownload: Bool
    let actions: DownloadActions

    var body: some View {
        let failed = ids.filter(sections.failed.contains)
        let completed = ids.filter { sections.completed.contains($0) && actions.folder($0) != nil }
        if !failed.isEmpty {
            Button("Retry download") { failed.forEach(actions.retry) }
                .disabled(!canDownload)
        }
        if completed.count == 1, let id = completed.first {
            Button("Set as Wallpaper") { actions.setAsWallpaper(id) }
        }
        if !completed.isEmpty {
            Button("Show in Finder") { completed.forEach(actions.showInFinder) }
        }
    }
}

/// steamcmd isn't there or isn't logged in: why downloads won't start.
private struct DownloadsProblemBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .padding(12)
        .glassBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous)) { content in
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}
