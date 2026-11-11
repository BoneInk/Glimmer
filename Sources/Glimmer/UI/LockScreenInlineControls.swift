import SwiftUI

private struct LockScreenActionsKey: EnvironmentKey {
    static let defaultValue: LockScreenActionController? = nil
}
extension EnvironmentValues {
    var lockScreenActions: LockScreenActionController? {
        get {self[LockScreenActionsKey.self]}
        set {self[LockScreenActionsKey.self]=newValue}
    }
}
struct LockScreenOperationStatus: View {
    let actions: LockScreenActionController
    var showsProgress = true
    var body: some View {
        if actions.showsStatus && ((showsProgress && actions.isBusy) || actions.canCancelPreparation || actions.completion == .failed || actions.coordinator.lastError != nil) {
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.top,spacing:7) {
                    if showsProgress && actions.isBusy {ProgressView().controlSize(.small)}
                    if actions.completion == .failed || actions.coordinator.lastError != nil {
                        Text(actions.statusText).font(.caption)
                            .id(actions.statusText)
                            .accessibilityIdentifier("lock-screen-status-message")
                            .foregroundStyle(.orange)
                    }
                }
                if actions.canCancelPreparation {
                    Button("取消") {actions.cancelPreparation()}.buttonStyle(.glass).controlSize(.small)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lock-screen-inline-status")
        }
    }
}
struct LockScreenApplyControls: View {
    let item: WallpaperItem
    var displayIDs: [String]? = nil
    var hasDisplays = true
    var onFeedback: (TransientToast) -> Void = { _ in }
    @Environment(\.lockScreenActions) private var actions
    var body: some View {
        if let actions {
            VStack(alignment:.leading,spacing:8) {
                Button {
                    if let message = actions.startApply(item:item, displayIDs: displayIDs) {
                        onFeedback(TransientToast(message, tone: .error))
                    }
                } label: {
                    WallpaperActionLabel(title: "锁屏", symbol: "lock.rectangle", busy: actions.isBusy && actions.itemID == item.id,
                        busyTitle: actions.canCancelPreparation ? "准备中" : "设置中")
                }
                .buttonStyle(.glass)
                .disabled(actions.isBusy || !hasDisplays || !(item.isVideoWallpaper || item.isWebWallpaper || item.isSceneWallpaper) || !item.fileExists)
                .accessibilityIdentifier("apply-lock-screen-inline")
                .help(lockScreenHelp)
                .overlay(alignment: .trailing) {
                    if actions.canCancelPreparation && actions.itemID == item.id {
                        Button { actions.cancelPreparation() } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .help("取消准备")
                        .accessibilityLabel("取消锁屏准备")
                        .accessibilityIdentifier("cancel-lock-screen-preparation")
                    }
                }
            }
            .onChange(of: actions.feedback) { _, message in
                guard actions.itemID == item.id, let message, !message.isEmpty else { return }
                let tone: TransientToast.Tone = actions.completion == .failed ? .error
                    : actions.completion == .cancelled ? .info : .success
                onFeedback(TransientToast(message, tone: tone))
            }
        }
    }

    private var lockScreenHelp: String {
        let target = displayIDs == nil ? "应用到全部显示器。" : "仅应用到所选显示器。"
        if item.isSceneWallpaper {
            return target + "使用 Scene 实时渲染，保留时间与脚本更新"
        }
        if item.isWebWallpaper {
            return target + "使用网页实时渲染；天气联网需开启该作品的 HTTPS 访问"
        }
        return target + "设为动态锁屏，同时更新系统桌面底图"
    }
}
struct LockScreenMaintenanceSection: View {
    @Environment(\.lockScreenActions) private var actions
    @GlassState private var error: String?
    var body: some View {
        if let actions {
            VStack(alignment:.leading,spacing:10) {
                Label("动态锁屏（实验性）",systemImage:"lock.rectangle").font(.callout.weight(.medium))
                Button("恢复此前锁屏配置") {error=actions.restorePrevious()}
                    .buttonStyle(.glass).disabled(actions.isBusy || !actions.coordinator.canRestorePrevious)
                LockScreenOperationStatus(actions:actions)
                if let error {Text(error).font(.caption).foregroundStyle(.orange)}
            }
        }
    }
}
