import AppKit
import SwiftUI

/// The iPhone & iPad Export mode's "Export More with These Settings…": pick wallpapers from the
/// library and where the Live Photos go (a folder, the Photos album), then export them with the
/// mode's device, quality and clip (`LivePhotoExportModel.batchPlan`), with the batch's and each
/// Live Photo's progress; "AirDrop All" sends every finished one, and each has its own AirDrop.
struct LivePhotoBatchExportSheet: View {
    /// The folder batches last went to, kept across launches.
    static let folderKey = "LivePhotoBatchFolder"

    @ObservedObject var model: LivePhotoExportModel
    var library: @MainActor () -> [WEWallpaper] = { AppDelegate.shared.contentViewModel.library.allWallpapers }
    @State private var wallpapers: [WEWallpaper] = []
    @State private var selection: Set<String> = []
    @State private var savesToFolder = true
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export More with These Settings")
                    .font(.title2.bold())
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let queue = model.batch {
                LivePhotoBatchProgress(queue: queue, model: model)
                if let notice = model.batchPhotosNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ExportLibraryPicker(wallpapers: wallpapers, skipReason: LivePhotoBatchQueue.skipReason, selection: $selection)
                destination
            }
            footer
        }
        .padding(20)
        .frame(width: 560, height: 660)
        .onAppear {
            wallpapers = ExportLibraryPicker.library(library(), with: model.wallpaper)
            selection = [model.wallpaper.identityPath]
            folder = model.defaults.string(forKey: Self.folderKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        }
    }

    private var summary: String {
        let length = model.clip.length.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(model.device.name) · \(model.quality.title) · \(length) s. Only “\(model.wallpaper.project.displayTitle)” keeps its crop and edits; the others are centred and export as authored.")
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Save to Folder", isOn: $savesToFolder)
                Spacer()
                if savesToFolder {
                    Text(verbatim: folder?.lastPathComponent ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Toggle("Also Save to Photos Album", isOn: Binding(get: { model.savesToPhotos }, set: { model.setSavesToPhotos($0) }))
                .help("Appears on your iPhone and iPad when iCloud Photos is on in Photos settings.")
            if model.photosAccessDenied {
                Text("Open Wallpaper Engine isn't allowed to add to your Photos library. Allow it in Privacy & Security, then turn this on again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @discardableResult
    private func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for the Live Photos’ photos and movies.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        folder = url
        model.defaults.set(url.path(percentEncoded: false), forKey: Self.folderKey)
        return true
    }

    private func start() {
        if savesToFolder, folder.map({ !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) ?? true {
            guard chooseFolder() else { return }
        }
        model.exportMore(ExportLibraryPicker.picked(wallpapers, selection: selection, edited: model.wallpaper),
                         folder: savesToFolder ? folder : nil)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let queue = model.batch {
                LivePhotoBatchFooter(queue: queue, model: model, folder: savesToFolder ? folder : nil)
            } else {
                Spacer()
                Button("Cancel", role: .cancel) { model.closeBatch() }
                    .glassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    Text("Export \(selection.count)")
                }
                .glassButtonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
    }
}

private struct LivePhotoBatchProgress: View {
    @ObservedObject var queue: LivePhotoBatchQueue
    let model: LivePhotoExportModel

    var body: some View {
        ExportBatchProgressView(
            progress: queue.progress, isRunning: queue.isRunning,
            rows: queue.entries.map { ExportBatchRow(id: $0.id, title: $0.item.wallpaper.project.displayTitle, status: $0.status, progress: $0.progress) },
            skipped: queue.skipped.map { (title: $0.title, reason: $0.reason) },
            accessory: { row in
                if let files = queue.entries.first(where: { $0.id == row.id && $0.status == .done })?.files {
                    Button {
                        model.airDrop(files)
                    } label: {
                        Label("AirDrop", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Send this Live Photo with AirDrop")
                }
            })
    }
}

private struct LivePhotoBatchFooter: View {
    @ObservedObject var queue: LivePhotoBatchQueue
    let model: LivePhotoExportModel
    let folder: URL?

    var body: some View {
        if queue.isRunning {
            Spacer()
            Button("Cancel", role: .cancel) { model.cancelBatch() }
                .glassButtonStyle()
        } else {
            if let folder {
                Button("Show in Finder") { model.showBatchInFinder(folder: folder) }
                    .glassButtonStyle()
            }
            Spacer()
            Button {
                model.airDropAll()
            } label: {
                Label("AirDrop All", systemImage: "square.and.arrow.up.on.square")
            }
            .glassButtonStyle()
            .disabled(queue.exported.isEmpty)
            .help("Send every exported Live Photo with one AirDrop share")
            Button("Done") { model.closeBatch() }
                .glassButtonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
