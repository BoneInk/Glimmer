import SwiftUI

struct AuthorWallpaperSettingsSection: View {
    let store: VideoLibraryStore
    let item: WallpaperItem
    let playback: DesktopPlaybackController
    var floatingPanelMaxHeight: CGFloat? = nil
    @GlassState private var project: AuthorPropertyProject?
    @GlassState private var projectError: String?
    @GlassState private var scenePropertyUsage: SceneAuthorPropertyUsage = .unavailable
    private var hasReadyHost: Bool {
        item.isSceneWallpaper
            ? !AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).isEmpty
            : !AuthorPropertyServices.shared.readyHosts(itemID: item.id).isEmpty
    }

    var body: some View {
        // Keep the loader/observation mounted even while the floating card is absent.
        VStack(alignment: .leading, spacing: 0) {
            if let floatingPanelMaxHeight {
                if let project, capabilities(for: project).hasEditableOptions(in: project) {
                    WallpaperDetailFloatingPanel(maxHeight: floatingPanelMaxHeight) {
                        propertyContent(project, editableOnly: true)
                    }
                    .accessibilityIdentifier("wallpaper-details-floating-settings")
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let project, !project.properties.isEmpty {
                        propertyContent(project, editableOnly: false)
                    } else if let projectError {
                        Label("无法读取作者设置：\(projectError)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .task(id: item.filePath) {
            scenePropertyUsage = .unavailable
            do {
                let loaded = try AuthorPropertyServices.project(for: item)
                project = loaded
                projectError = nil
                guard let loaded, item.isSceneWallpaper else { return }
                let usage = await Task.detached(priority: .utility) {
                    SceneAuthorPropertyUsageAnalyzer.analyze(project: loaded)
                }.value
                guard !Task.isCancelled, project?.sourceData == loaded.sourceData else { return }
                scenePropertyUsage = usage
            } catch {
                project = nil; projectError = error.localizedDescription
            }
        }
    }
    private func capabilities(for project: AuthorPropertyProject) -> AuthorPropertyEditingCapabilities {
        let keys = item.isProjectWallpaper ? AuthorPropertyServices.shared.editableKeys(project: project, itemID: item.id) : []
        return .init(editableKeys: keys,
            runtimeLabel: item.isSceneWallpaper ? "Scene 壁纸" : item.isWebWallpaper ? "Web 壁纸" : "视频壁纸",
            unsupportedReason: item.isSceneWallpaper
                ? "预览就绪后可修改支持的作者选项。"
                : item.isWebWallpaper ? (!keys.isEmpty ? "" : (hasReadyHost ? "此网页不支持修改作者设置。" : "预览就绪后可修改作者设置。"))
                : "视频壁纸不支持作者设置。")
    }

    private func propertyContent(_ project: AuthorPropertyProject, editableOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthorPropertySettingsView(project: project,
                overrideStore: AuthorPropertyServices.shared.store(storage: store.storage), itemID: item.id,
                capabilities: capabilities(for: project),
                resourceActions: item.isWebWallpaper ? AuthorPropertyResourceActions { request in
                    try await AuthorPropertyServices.shared.performResource(request, storage: store.storage)
                } : nil,
                showsOnlyEditableProperties: editableOnly,
                sceneUnreferencedScalarKeys: item.isSceneWallpaper && scenePropertyUsage.isConclusive
                    ? scenePropertyUsage.unreferencedScalarKeys : [],
                onValuesChanged: { _ in
                    guard item.isProjectWallpaper else { return }
                    try await AuthorPropertyServices.shared.applySavedSettings(project: project, itemID: item.id, storage: store.storage)
                })
                .id(item.id)
            if let error = AuthorPropertyServices.shared.resourceErrors[item.id] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

}
