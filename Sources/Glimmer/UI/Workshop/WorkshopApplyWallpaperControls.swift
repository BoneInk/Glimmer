import SwiftUI

/// 选择目标后明确点击应用；查看详情、播放预览均不会改变桌面。
struct WorkshopApplyWallpaperControls: View {
    @Bindable var coordinator: WorkshopCoordinator
    let itemID: String
    @Environment(\.lockScreenActions) private var lockScreenActions
    @GlassState private var target: WorkshopWallpaperTarget = .currentDisplay
    @GlassState private var feedback: WorkshopWallpaperApplyResult?
    @GlassState private var applyTask: Task<Void, Never>?
    @GlassState private var lockScreenTask: Task<Void, Never>?
    @GlassState private var lockScreenMessage: String?

    private var available: Bool { coordinator.hasLocalWallpaper(itemID: itemID) }
    private var supportsLockScreen: Bool { coordinator.localPreview(for: itemID) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Picker("设为壁纸的目标", selection: $target) {
                    ForEach(WorkshopWallpaperTarget.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .help("当前显示器指管理窗口所在的显示器")
                .disabled(coordinator.isApplyingWallpaper || applyTask != nil)
                Button {
                    feedback = nil
                    let requestedTarget = target
                    applyTask = Task { @MainActor in
                        let result = await coordinator.applyWallpaper(itemID: itemID, target: requestedTarget)
                        if !Task.isCancelled { feedback = result }
                        applyTask = nil
                    }
                } label: {
                    WallpaperActionLabel(title: "设为壁纸", symbol: "display", busy: coordinator.isApplyingWallpaper)
                }
                .buttonStyle(.glassProminent)
                .disabled(!available || coordinator.isApplyingWallpaper || applyTask != nil)
                .accessibilityIdentifier("workshop-apply-wallpaper")
                Button {
                    lockScreenMessage = nil
                    lockScreenTask = Task { @MainActor in
                        let error = await coordinator.requestDynamicLockScreen(itemID: itemID)
                        if !Task.isCancelled { lockScreenMessage = error }
                        lockScreenTask = nil
                    }
                } label: {
                    WallpaperActionLabel(title: "锁屏", symbol: "lock.rectangle", busy: coordinator.isPreparingDynamicLockScreen || lockScreenActions?.isBusy == true)
                }
                .buttonStyle(.glass)
                .disabled(!supportsLockScreen || lockScreenActions == nil || lockScreenActions?.isBusy == true || coordinator.isPreparingDynamicLockScreen || lockScreenTask != nil)
                .accessibilityIdentifier("workshop-dynamic-lock-screen")
                .help(supportsLockScreen ? "设为动态锁屏，同时更新系统桌面底图" : "动态锁屏仅支持视频壁纸")
                WallpaperInformationButton(itemID: itemID)
                Spacer(minLength: 0)
            }
            .controlSize(.regular)
            if let lockScreenMessage {
                Text(lockScreenMessage).font(.caption).foregroundStyle(.orange)
            }
            if let lockScreenActions {LockScreenOperationStatus(actions:lockScreenActions, showsProgress: false)}
            if let feedback, !feedback.succeeded {
                Label(feedback.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("workshop-apply-feedback")
            }
        }
        .onDisappear { applyTask?.cancel(); applyTask = nil; lockScreenTask?.cancel(); lockScreenTask = nil }
    }
}
