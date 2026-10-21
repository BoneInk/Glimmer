import AppKit
import SwiftUI

/// Settings › General › Screenshots: the size WE's "Take screenshot" renders at and the folder it
/// saves into (`WallpaperScreenshotService`).
struct ScreenshotSection: View {
    @ObservedObject var viewModel: GlobalSettingsViewModel

    private var folder: URL { WallpaperScreenshotWriter.folder(setting: viewModel.settings.screenshotFolder) }

    var body: some View {
        Section {
            Picker("Size", selection: $viewModel.settings.screenshotResolution) {
                Text("Display").tag(GSScreenshotResolution.display)
                Text(verbatim: "4K").tag(GSScreenshotResolution.uhd4K)
                Text(verbatim: "8K").tag(GSScreenshotResolution.uhd8K)
            }
            .changedFromDefault(viewModel.isChanged(\.screenshotResolution))
            .help("Display saves the wallpaper at the display's own pixels. 4K and 8K render it again at that size along the display's long side, at the display's shape.")
            LabeledContent {
                HStack(spacing: 6) {
                    Button("Choose…") { chooseFolder() }
                    Button("Show in Finder") { showFolder() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                    Text(verbatim: folder.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .changedFromDefault(viewModel.isChanged(\.screenshotFolder))
            HStack {
                Spacer()
                Button("Take Screenshot") { AppDelegate.shared.takeScreenshot() }
                    .help("Saves the wallpaper on the display under the pointer, without desktop icons or windows.")
            }
        } header: {
            Label("Screenshots", systemImage: "camera")
        } footer: {
            Text("Take Screenshot is also in the menu bar menu, and can have a hotkey. Each screenshot is a PNG of the wallpaper alone.")
        }
        .settingsAnchor(SettingsAnchor.screenshots)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.settings.screenshotFolder = url.path(percentEncoded: false)
    }

    private func showFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            OWELog.error(.settings, "Can't create the screenshot folder \(folder.path): \(error)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
