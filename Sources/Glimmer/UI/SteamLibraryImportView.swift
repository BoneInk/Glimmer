import AppKit
import SwiftUI
import Observation

/// Inventory is read-only. Only the explicit import action copies chosen items.
struct SteamLibraryImportView: View {
    let onClose: () -> Void
    let onOpenDetails: (WallpaperItem) -> Void
    @GlassState private var model: SteamLibraryImportModel

    init(store: VideoLibraryStore, importer: ImportService, onClose: @escaping () -> Void,
         onImported: @escaping (WallpaperItem) -> Void, onOpenDetails: @escaping (WallpaperItem) -> Void) {
        self.onClose = onClose
        self.onOpenDetails = onOpenDetails
        _model = GlassState(wrappedValue: SteamLibraryImportModel(store: store, importer: importer, onImported: onImported))
    }

    var body: some View {
        GlassStyleReader { style in
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("从 Steam 本地库导入").font(.title2.weight(.semibold))
                    Spacer()
                    Button("完成", action: onClose).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                }
                HStack {
                    Button { Task { await model.chooseFolders() } } label: { Label("选择 Steam 库…", systemImage: "externaldrive") }
                        .buttonStyle(.glass).disabled(model.isBusy)
                    Button("选择可导入项") { model.selection = Set(model.items.filter(\.isImportCandidate).map(\.id)) }
                        .buttonStyle(.glass).disabled(model.items.isEmpty || model.isBusy)
                    Spacer()
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Button("停止", action: model.cancel).buttonStyle(.glass)
                    }
                    Button("导入所选 · \(model.selection.count)", action: model.importSelection)
                        .buttonStyle(.glassProminent).disabled(model.selection.isEmpty || model.isBusy)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.items.isEmpty && !model.isBusy {
                            ContentUnavailableView("选择 Steam 库", systemImage: "externaldrive")
                                .frame(maxWidth: .infinity, minHeight: 250)
                        }
                        ForEach(model.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Toggle("选择\(item.title)", isOn: Binding(get: { model.selection.contains(item.id) }, set: { selected in
                                    if selected { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                                }))
                                .labelsHidden().toggleStyle(.checkbox)
                                .disabled(!item.isImportCandidate || model.isBusy)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.title).font(.headline).lineLimit(2)
                                        Spacer()
                                        Text(item.kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    }
                                    if let result = model.results[item.id] { Text(result).font(.caption).foregroundStyle(.secondary) }
                                    else if let diagnostic = item.diagnostics.first { Text(diagnostic.message).font(.caption).foregroundStyle(.orange) }
                                    else if !item.isImportCandidate { Text("此类型尚不能导入播放").font(.caption).foregroundStyle(.secondary) }
                                    if let id = model.importedIDs[item.id], let stored = model.store.item(withID: id) {
                                        Button("详情与设置") { onOpenDetails(stored) }.buttonStyle(.glass).controlSize(.small)
                                    }
                                }
                            }
                            .padding(16).background(style.groupedBackground(cornerRadius: 18))
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 740, idealWidth: 860, minHeight: 560, idealHeight: 660)
        .background { PopupSurfaceBackground() }
        .onDisappear { model.close() }
        .accessibilityIdentifier("steam-library-import")
    }
}

@MainActor @Observable
private final class SteamLibraryImportModel {
    let store: VideoLibraryStore
    private let importer: ImportService
    private let onImported: (WallpaperItem) -> Void
    private let scanner = SteamLibraryScanner()
    var selection: Set<String> = []
    private(set) var items: [SteamLibraryScannedItem] = []
    private(set) var diagnostics: [String] = []
    private(set) var results: [String: String] = [:]
    private(set) var importedIDs: [String: UUID] = [:]
    private(set) var message: String?
    private(set) var isBusy = false
    private var task: Task<Void, Never>?
    private var panel: NSOpenPanel?
    private var roots: [URL] = []
    private var scopes: [URL] = []
    private var closed = false

    init(store: VideoLibraryStore, importer: ImportService, onImported: @escaping (WallpaperItem) -> Void) {
        self.store = store; self.importer = importer; self.onImported = onImported
    }

    func chooseFolders() async {
        guard !isBusy, panel == nil, !closed else { return }
        let panel = NSOpenPanel()
        self.panel = panel
        panel.title = "选择 Steam 库文件夹"
        panel.message = "选择 Steam 库根目录或 workshop/content/431960；不会登录或修改 Steam 文件。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        let response = await panel.begin()
        self.panel = nil
        guard response == .OK, !closed else { return }
        let chosen = panel.urls.filter { url in !roots.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) }
        guard !chosen.isEmpty else { return }
        for url in chosen {
            roots.append(url)
            if url.startAccessingSecurityScopedResource() { scopes.append(url) }
        }
        isBusy = true
        task = Task {
            defer { self.finishTask() }
            for root in chosen {
                do {
                    let report = try await self.scanner.scan(selectedRoot: root)
                    try Task.checkCancellation()
                    guard !self.closed else { return }
                    let known = Set(self.items.map(\.id))
                    self.items += report.items.filter { !known.contains($0.id) }
                    self.diagnostics += report.diagnostics.map(\.message)
                    self.message = "已找到 \(self.items.count) 个作品；导入前将再次验证所选内容。"
                } catch is CancellationError { return }
                catch { if !self.closed { self.diagnostics.append(error.localizedDescription) } }
            }
        }
    }

    func importSelection() {
        guard !isBusy, !closed else { return }
        let chosen = items.filter { selection.contains($0.id) && $0.isImportCandidate }
        guard !chosen.isEmpty else { return }
        isBusy = true
        task = Task {
            defer { self.finishTask() }
            for candidate in chosen {
                guard !Task.isCancelled, !self.closed else { return }
                let metadata = ImportWorkshopMetadata(publishedFileID: candidate.workshopID, title: candidate.title,
                    pageURLString: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(candidate.workshopID)",
                    previewImageURLString: nil, authorSteamID: nil, fileByteSize: nil)
                let outcome: ImportWorkshopOutcome
                if candidate.kind == .scene {
                    outcome = await self.importer.importWorkshopScene(candidate.projectURL, metadata: metadata)
                } else if candidate.kind == .web {
                    outcome = await self.importer.importWorkshopWeb(candidate.projectURL, metadata: metadata)
                } else if let entry = candidate.entryURL {
                    outcome = await self.importer.importWorkshopVideo(entry, metadata: metadata, copyIntoLibrary: true)
                } else { continue }
                guard !self.closed else { return }
                switch outcome {
                case .imported(let id), .duplicated(let id, _):
                    self.importedIDs[candidate.id] = id
                    self.results[candidate.id] = "已导入素材库"
                    self.selection.remove(candidate.id)
                    if let item = self.store.item(withID: id) { self.onImported(item) }
                case .failed(let error): self.results[candidate.id] = error
                }
            }
        }
    }

    func cancel() { task?.cancel() }
    func close() {
        closed = true; panel?.cancel(nil); panel = nil; task?.cancel()
        if !isBusy { releaseScopes() }
    }
    private func finishTask() {
        task = nil; isBusy = false
        if closed { releaseScopes() }
    }
    private func releaseScopes() { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes.removeAll() }
    isolated deinit { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
}
