import AppKit
import SwiftUI
import Observation

/// Isolated experiment: selecting a folder never imports or assigns its wallpaper.
@MainActor
struct SceneInspectionView: View {
    let onClose: () -> Void
    @GlassState private var model = SceneInspectionModel()

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    var body: some View {
        GlassStyleReader { style in
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Label("Scene 静态预览", systemImage: "square.3.layers.3d")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("完成") { model.close(); onClose() }
                        .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 12) {
                    Button { model.chooseFolder() } label: { Label("选择项目文件夹…", systemImage: "folder") }
                        .buttonStyle(.glassProminent)
                        .disabled(model.isChoosing)
                        .accessibilityIdentifier("scene-inspection-choose-folder")
                    if model.isLoading { ProgressView().controlSize(.small) }
                    if let name = model.folderName { Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                }
                if let context = model.context {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            preview(context, style: style)
                            HStack {
                                Text("\(Int(context.inspection.canvasSize.x)) × \(Int(context.inspection.canvasSize.y))")
                                Spacer()
                                if context.isUpdating { ProgressView().controlSize(.small) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            AuthorPropertySettingsView(project: context.project,
                                overrideStore: context.overrideStore, itemID: context.itemID,
                                capabilities: .init(editableKeys: context.editableKeys,
                                    runtimeLabel: "Scene 静态预览",
                                    unsupportedReason: "当前预览仅支持部分作者选项。")) { values in
                                    try await context.apply(values)
                                }
                                .padding(16)
                        }
                        .frame(width: 330)
                        .background(style.groupedBackground(cornerRadius: 18))
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "square.3.layers.3d").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text(model.isLoading ? "正在读取真实场景与图像…" : "选择包含 project.json 的 Scene 项目文件夹")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style.groupedBackground(cornerRadius: 18))
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("scene-inspection-error")
                }
            }
            .padding(24)
            .frame(minWidth: 860, idealWidth: 1040, minHeight: 620, idealHeight: 720)
        }
        .background { PopupSurfaceBackground() }
        .onDisappear { model.close() }
        .accessibilityIdentifier("scene-inspection")
    }
    @ViewBuilder
    private func preview(_ context: SceneInspectionContext, style: GlassStyle) -> some View {
        if context.inspection.scriptProgram != nil {
            ContentUnavailableView {
                Label("此项目需要运行脚本", systemImage: "play.rectangle")
            } description: {
                Text("请导入素材库后，在「详情与设置」中预览。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(style.groupedBackground(cornerRadius: 18))
            .accessibilityIdentifier("scene-inspection-requires-runtime")
        } else if context.inspection.isRenderableSubset {
            SceneInspectionCanvas(inspection: context.inspection)
                .id(context.renderRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .accessibilityLabel("真实 Scene 静态图像预览")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("此场景超出当前静态预览范围", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("未显示部分图层，以免呈现不完整的效果。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(style.groupedBackground(cornerRadius: 18))
            .accessibilityIdentifier("scene-inspection-diagnostics")
        }
    }
}

private struct SceneInspectionCanvas: NSViewRepresentable {
    let inspection: SceneWallpaperInspection
    func makeNSView(context: Context) -> SceneWallpaperCanvasView {
        let view = SceneWallpaperCanvasView(frame: .zero)
        try? view.setInspection(inspection)
        return view
    }
    func updateNSView(_ view: SceneWallpaperCanvasView, context: Context) {}
}

/// Worker closures and the author-settings callback retain this lease. Cancellation
/// does not release folder access or temporary overrides before actual work exits.
final class SceneInspectionLease: @unchecked Sendable {
    let folder: URL
    let temporaryDirectory: URL
    private let accessing: Bool
    init(folder: URL) throws {
        self.folder = folder
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Glimmer-ScenePreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        temporaryDirectory = temporary
        accessing = folder.startAccessingSecurityScopedResource()
    }
    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        if accessing { folder.stopAccessingSecurityScopedResource() }
    }
}

@MainActor @Observable
final class SceneInspectionContext {
    let project: AuthorPropertyProject
    let itemID = UUID()
    let overrideStore: AuthorPropertyOverrideStore
    let lease: SceneInspectionLease
    private(set) var inspection: SceneWallpaperInspection
    private(set) var renderRevision = UUID()
    private(set) var isUpdating = false
    private var generation = 0
    private var closed = false
    private var work: Task<SceneWallpaperInspection, Error>?

    var editableKeys: Set<String> {
        guard inspection.isRenderableSubset, inspection.scriptProgram == nil else { return [] }
        let bindings = inspection.layers.flatMap(\.bindings)
        return Set(project.properties.filter { definition in
            let targets = bindings.filter { $0.propertyKey == definition.key }.map(\.target)
            guard !targets.isEmpty else { return false }
            switch definition.kind {
            case .bool: return targets.allSatisfy { $0 == "visible" }
            case .slider: return targets.allSatisfy { $0 == "alpha" }
            case .color: return targets.allSatisfy { $0 == "color" }
            default: return false
            }
        }.map(\.key))
    }
    init(project: AuthorPropertyProject, inspection: SceneWallpaperInspection, lease: SceneInspectionLease) {
        self.project = project; self.inspection = inspection; self.lease = lease
        overrideStore = AuthorPropertyOverrideStore(directory: lease.temporaryDirectory.appendingPathComponent("Overrides", isDirectory: true))
    }
    func apply(_ values: [String: GWJSONValue]) async throws {
        guard !closed else { throw SceneWallpaperFailure(message: "Scene 预览已关闭。") }
        guard inspection.scriptProgram == nil else { throw SceneWallpaperFailure(message: "此项目需要运行脚本，请导入素材库后在详情中修改作者设置。") }
        guard Set(values.keys).isSubset(of: editableKeys) else { throw SceneWallpaperFailure(message: "此 Scene 选项尚未接通静态图像预览。") }
        for (key,value) in values {
            guard let definition = project.definition(for:key) else { throw SceneWallpaperFailure(message:"找不到此 Scene 作者选项。") }
            try definition.validate(value)
        }
        let payload = try JSONEncoder().encode(GWJSONValue.object(values))
        generation += 1
        let ticket = generation, project = project, lease = lease
        work?.cancel(); isUpdating = true
        let task = Task.detached(priority: .userInitiated) { [lease] in
            try Task.checkCancellation()
            let source = lease.folder.appendingPathComponent("project.json")
            let before = try AuthorPropertyProject.load(projectURL: source, allowedRoot: lease.folder)
            guard before.sourceData == project.sourceData else { throw SceneWallpaperFailure(message: "源项目已改变，请重新选择项目文件夹。") }
            let result = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: source, propertiesJSON: payload)
            guard result.scriptProgram == nil else { throw SceneWallpaperFailure(message: "此项目需要运行脚本，请导入素材库后在详情中修改作者设置。") }
            _ = try SceneWallpaperRenderer.render(inspection: result, pixelSize: CGSize(width: 960, height: 640))
            let after = try AuthorPropertyProject.load(projectURL: source, allowedRoot: lease.folder)
            guard after.sourceData == project.sourceData else { throw SceneWallpaperFailure(message: "源项目已改变，请重新选择项目文件夹。") }
            try Task.checkCancellation()
            return result
        }
        work = task
        defer { if generation == ticket { isUpdating = false; work = nil } }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !closed, generation == ticket, !Task.isCancelled else { throw CancellationError() }
        inspection = result; renderRevision = UUID()
    }
    func close() { closed = true; generation += 1; work?.cancel(); work = nil; isUpdating = false }
    isolated deinit { work?.cancel() }
}

@MainActor @Observable
final class SceneInspectionModel {
    private(set) var context: SceneInspectionContext?
    private(set) var error: String?
    private(set) var folderName: String?
    private(set) var isLoading = false
    private(set) var isChoosing = false
    private var chooser: NSOpenPanel?
    private var chooserTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var generation = 0
    private var closed = false

    func chooseFolder() {
        guard !closed, chooser == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Scene 项目文件夹"
        panel.message = "请选择包含 project.json 的文件夹。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        chooser = panel; isChoosing = true
        chooserTask = Task { [weak self] in
            let response = await panel.begin()
            guard let self, self.chooser === panel else { return }
            self.chooser = nil; self.chooserTask = nil; self.isChoosing = false
            guard !self.closed, !Task.isCancelled, response == .OK, let folder = panel.url else { return }
            self.select(folder: folder)
        }
    }
    func select(folder: URL) {
        guard !closed else { return }
        generation += 1
        let ticket = generation
        selectionTask?.cancel(); context?.close(); context = nil
        error = nil; isLoading = true; folderName = folder.lastPathComponent
        selectionTask = Task { [weak self] in
            do {
                let lease = try SceneInspectionLease(folder: folder)
                let work = Task.detached(priority: .userInitiated) { [lease] in
                    try Task.checkCancellation()
                    let source = lease.folder.appendingPathComponent("project.json")
                    let project = try AuthorPropertyProject.load(projectURL: source, allowedRoot: lease.folder)
                    let inspection = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: source)
                    if inspection.isRenderableSubset, inspection.scriptProgram == nil { _ = try SceneWallpaperRenderer.render(inspection: inspection, pixelSize: CGSize(width: 960, height: 640)) }
                    let after = try AuthorPropertyProject.load(projectURL: source, allowedRoot: lease.folder)
                    guard after.sourceData == project.sourceData else { throw SceneWallpaperFailure(message: "源项目已改变，请重新选择项目文件夹。") }
                    try Task.checkCancellation()
                    return (project, inspection)
                }
                let (project, inspection) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, !self.closed, self.generation == ticket, !Task.isCancelled else { return }
                self.context = SceneInspectionContext(project: project, inspection: inspection, lease: lease)
                self.isLoading = false; self.selectionTask = nil
            } catch is CancellationError { }
            catch {
                guard let self, !self.closed, self.generation == ticket else { return }
                self.error = error.localizedDescription; self.isLoading = false; self.selectionTask = nil
            }
        }
    }
    func close() {
        guard !closed else { return }
        closed = true; generation += 1
        chooser?.cancel(nil); chooser = nil; chooserTask?.cancel(); chooserTask = nil
        selectionTask?.cancel(); selectionTask = nil
        context?.close(); context = nil; isLoading = false; isChoosing = false
    }
    isolated deinit { chooser?.cancel(nil); chooserTask?.cancel(); selectionTask?.cancel(); context?.close() }
}
