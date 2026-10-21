import AppKit
import SwiftUI

/// 所有本地壁纸入口共用的详情：按 UUID 重新读取素材，重命名和设置立即更新。
struct WallpaperDetailsWindowContent: View {
    let store: VideoLibraryStore
    let selection: WallpaperDetailsSelection
    let displays: DisplayRegistry
    let playback: DesktopPlaybackController
    let onClose: () -> Void
    var policy: GWPolicyController? = nil
    var onOpenDynamicLockScreen: ((WallpaperItem) -> Void)? = nil
    var onItemRemoved: ((UUID) -> Void)? = nil
    var immersive = false
    var wallpaperFPS = 30
    @GlassState private var errorMessage: String?
    @GlassState private var errorToast: TransientToast?
    @GlassState private var applyState = DetailWallpaperApplyState()
    @GlassState private var pendingDeletion: WallpaperItem?
    @GlassState private var isDeleting = false
    @Environment(\.wallpaperDetailChromeTopInset) private var chromeTopInset
    @Environment(\.wallpaperDeletionAction) private var deletionAction

    var body: some View {
        GlassStyleReader { style in
            ZStack(alignment: .top) {
                if let item = store.item(withID: selection.itemID) {
                    DetailInspectorView(
                        store: store, item: item, displays: displays.displays,
                        playback: playback, style: style,
                        onApplyAll: { item in await playback.applyAndWait(item: item, to: nil) },
                        onClearAll: { playback.clear() },
                        onToggleFavorite: { store.toggleFavorite(id: item.id) },
                        onRemove: {
                            guard deletionAction != nil else { errorMessage = "删除当前不可用"; return }
                            pendingDeletion = item
                        },
                        onRelink: { item in Task { await relink(item) } },
                        canDelete: deletionAction != nil,
                        policyReasonText: policy?.isPolicyBlockingPlayback == true ? policy?.status.reasonListText : nil,
                        onOpenDynamicLockScreen: onOpenDynamicLockScreen,
                        sharedApplyState: applyState,
                        immersive: immersive,
                        topContentInset: 0,
                        wallpaperFPS: wallpaperFPS
                    )
                    .id(item.id)
                } else {
                    ContentUnavailableView("壁纸已从素材库移除", systemImage: "rectangle.stack.badge.minus")
                        .wallpaperCoverDestination()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if immersive {
                    WallpaperDetailBackButton(onBack: onClose)
                        .padding(.leading, 24).padding(.top, max(20, chromeTopInset + 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(true)
                        .zIndex(2)
                }
            }

        }
        .frame(minWidth: 440, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if !immersive { PopupSurfaceBackground() } }
        .accessibilityIdentifier("wallpaper-details-settings")
        .onChange(of: errorMessage) { _, message in
            if let message { errorToast = TransientToast(SceneWallpaperPresentation.errorSummary(message), tone: .error) }
        }
        .transientToast($errorToast)
        .onChange(of: selection.itemID) { _, _ in errorMessage = nil; errorToast = nil; applyState.cancel() }
        .onDisappear { applyState.cancel() }
        .onExitCommand { applyState.cancel(); onClose() }
        .confirmationDialog("删除这张壁纸？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion) { item in
            Button("移到废纸篓", role: .destructive) { delete(item) }
                .disabled(isDeleting)
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(WallpaperDeletionAction.confirmationMessage(for: item))
        }
    }

    private func delete(_ item: WallpaperItem) {
        guard let deletionAction, !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            let error = await deletionAction.perform(item)
            isDeleting = false
            if let error { errorMessage = "未能删除：\(error)"; return }
            onItemRemoved?(item.id)
            onClose()
        }
    }

    @MainActor private func relink(_ item: WallpaperItem) async {
        guard item.isVideoWallpaper else { errorMessage = "请重新导入完整壁纸项目。"; return }
        let panel = NSOpenPanel()
        panel.title = "重新定位视频文件"
        panel.message = "为「\(item.displayTitle)」选择新的文件位置"
        panel.prompt = "使用此文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = VideoFileSupport.allowedContentTypes
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let probe = try await VideoProbe.probe(url: url)
            store.relink(id: item.id, to: url, probe: probe)
            errorMessage = nil
        } catch { errorMessage = "重新定位失败：\(error.localizedDescription)" }
    }
}
