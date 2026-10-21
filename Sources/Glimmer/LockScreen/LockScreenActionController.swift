import Foundation
import Observation

/// One explicit user action owns preparation and the native transaction across
/// page/window changes. Construction and status reads never apply anything.
@MainActor @Observable final class LockScreenActionController {
    enum Phase { case idle, preparing, applying, restoring }
    enum Completion { case none, cancelled, submitted, restored, failed }
    let coordinator: ExperimentalLockScreenCoordinator
    private(set) var phase: Phase = .idle
    private(set) var completion: Completion = .none
    private(set) var itemID: UUID?
    private(set) var itemTitle: String?
    private(set) var feedback: String?
    @ObservationIgnored private var operation: Task<Void,Never>?
    private var generation = UUID()
    @ObservationIgnored private let beforePreparation: (@MainActor () async -> Void)?
    @ObservationIgnored private let beforeCommit: (@MainActor () async -> Void)?

    init(coordinator: ExperimentalLockScreenCoordinator,
         beforePreparation: (@MainActor () async -> Void)? = nil,
         beforeCommit: (@MainActor () async -> Void)? = nil) {
        self.coordinator=coordinator;self.beforePreparation=beforePreparation;self.beforeCommit=beforeCommit
        if coordinator.state != .restored {
            itemID=coordinator.preparedAsset?.itemID;itemTitle=coordinator.preparedAsset?.title
        }
    }
    var isBusy: Bool { phase != .idle || coordinator.isBusy }
    var canCancelPreparation: Bool { phase == .preparing }
    var isCommitting: Bool { phase == .applying || phase == .restoring }
    var showsStatus: Bool { isBusy || feedback != nil || coordinator.state != .idle }
    var statusText: String {
        if isBusy {
            switch phase {
            case .preparing: return coordinator.preparationDetail ?? "正在准备锁屏素材"
            case .applying: return "正在应用锁屏…"
            case .restoring: return "正在恢复此前锁屏…"
            case .idle: break
            }
        }
        if let feedback {return feedback}
        switch coordinator.state {
        case .applied: return submittedText
        case .restored: return restoredText
        case .prepared: return "锁屏素材已准备"
        case .registered: return "锁屏准备待完成"
        default: return coordinator.statusText
        }
    }
    private var submittedText: String { "锁屏配置已更新。" + (coordinator.lastError.map {" " + $0} ?? "") }
    private var restoredText: String { "此前锁屏配置已恢复。" + (coordinator.lastError.map {" " + $0} ?? "") }
    @discardableResult func startApply(item: WallpaperItem) -> String? {
        guard !isBusy else { return "正在处理「\(itemTitle ?? "锁屏配置")」，请等待完成或取消准备。" }
        guard item.isVideoWallpaper || item.isWebWallpaper || item.isSceneWallpaper else {
            return "动态锁屏目前支持视频、Web 动画和 Scene。"
        }
        let ticket=UUID();generation=ticket;itemID=item.id;itemTitle=item.displayTitle
        phase = .preparing;completion = .none;feedback=nil
        operation=Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket {self.phase = .idle;self.operation=nil} }
            await self.beforePreparation?()
            guard !Task.isCancelled, self.generation == ticket else { self.finishCancelled();return }
            await self.coordinator.prepare(item:item)
            guard !Task.isCancelled, self.generation == ticket else { self.finishCancelled();return }
            guard self.coordinator.state == .prepared, self.coordinator.preparedAsset?.itemID == item.id else {
                self.completion = .failed;self.feedback=self.coordinator.lastError ?? "本次素材准备未完成，未提交新的锁屏配置。";return
            }
            // From here on the transaction cannot be cancelled, including quit.
            self.phase = .applying
            await self.beforeCommit?()
            guard self.generation == ticket, self.coordinator.state == .prepared,
                  self.coordinator.preparedAsset?.itemID == item.id else {
                self.completion = .failed;self.feedback="准备素材已改变，未提交新的锁屏配置。";return
            }
            await self.coordinator.applyPrepared()
            self.completion=self.coordinator.state == .applied ? .submitted:.failed
            self.feedback=self.completion == .submitted ? self.submittedText:self.coordinator.statusText
        }
        return nil
    }
    @discardableResult func cancelPreparation() -> Bool {
        guard canCancelPreparation else {return false}
        coordinator.cancelPreparation();operation?.cancel();return true
    }
    private func finishCancelled() {
        completion = .cancelled;feedback="本次锁屏准备已取消，未提交新配置。"
    }
    @discardableResult func restorePrevious() -> String? {
        guard !isBusy else {return "锁屏正在处理，请等待完成。"}
        guard coordinator.canRestorePrevious else {return "没有可恢复的此前配置。"}
        let ticket=UUID();generation=ticket;phase = .restoring;completion = .none;feedback=nil
        itemID=nil;itemTitle=nil
        operation=Task { [weak self] in
            guard let self else{return}
            defer {if self.generation == ticket {self.phase = .idle;self.operation=nil}}
            await self.coordinator.restorePrevious()
            self.completion=self.coordinator.state == .restored ? .restored:.failed
            self.feedback=self.completion == .restored ? self.restoredText:self.coordinator.statusText
        }
        return nil
    }
    func waitUntilIdle() async { if let operation { await operation.value } }
}
