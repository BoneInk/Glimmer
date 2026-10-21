//
//  SafeRestart.swift
//  Open Wallpaper Engine
//

import Cocoa
import Combine

/// Keeps a wallpaper that crashed, hung or bogged down the Mac from coming back on its own.
///
/// - A sentinel (`SafeRestartLedger`) always names the wallpapers showing now and is cleared on
///   a clean quit. If it is still there at launch, those wallpapers are not restored, the
///   playlist stays paused, and a notice offers to retry them.
/// - A wallpaper behind two unclean exits in a row is flagged: the library marks it and applying
///   it asks first; playlist auto-advance skips it.
/// - `RenderWatchdog` unloads the showing wallpapers when the app stays badly degraded.
///
/// This is independent of any sentinel the shader compiler keeps for its own work.
@MainActor
final class SafeRestart: ObservableObject {
    enum Reason {
        case uncleanExit
        case unresponsive(RenderWatchdog.Trip)
    }

    /// `SafeRestartLedger.key(for:)` of every flagged wallpaper, for the library.
    @Published private(set) var flaggedKeys: Set<String> = []

    let watchdog: RenderWatchdog
    private let store: SafeRestartStore
    private var ledger: SafeRestartLedger
    private weak var viewModel: WallpaperViewModel?
    private var sessionCancellable: AnyCancellable?
    private var pending: (suspects: [SafeRestartLedger.Suspect], reason: Reason)?
    private var notice: SafeRestartNotice?
    private var terminationSignal: DispatchSourceSignal?

    init(store: SafeRestartStore = SafeRestartStore(), watchdog: RenderWatchdog = RenderWatchdog()) {
        self.store = store
        self.watchdog = watchdog
        self.ledger = store.load()
        self.flaggedKeys = ledger.flaggedKeys
    }

    // MARK: - Lifecycle hooks

    /// Call at launch, before the wallpaper windows are built.
    func attach(to viewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        let suspects = ledger.beginLaunch()
        store.save(ledger)
        flaggedKeys = ledger.flaggedKeys
        if !suspects.isEmpty {
            let names = suspects.map(\.wallpaper.project.title).joined(separator: ", ")
            OWELog.info(.app, "Previous run ended uncleanly; not restoring \(names)")
            unload(suspects, in: viewModel)
            pending = (suspects, .uncleanExit)
        }

        viewModel.renderWatchdog = watchdog
        viewModel.confirmApply = { [weak self] wallpaper in self?.confirmApplying(wallpaper) ?? true }
        viewModel.isFlaggedBySafeRestart = { [weak self] wallpaper in self?.ledger.isFlagged(wallpaper) ?? false }
        // What the displays show: a clone member shows its main clone display's wallpaper.
        sessionCancellable = viewModel.$wallpapers
            .combineLatest(viewModel.$layoutResolution, viewModel.$enabledScreens)
            .sink { [weak self] wallpapers, resolution, enabledScreens in
                self?.recordSession(wallpapers: resolution.shown(wallpapers), enabledScreens: enabledScreens)
            }
        watchdog.start { [weak self] trip in self?.watchdogTripped(trip) }
        // A sudden-terminated app never hears `applicationWillTerminate`, which would leave the
        // sentinel set after a normal logout.
        ProcessInfo.processInfo.disableSuddenTermination()
        // SIGTERM (`kill`, launchd) asks the app to quit, not a crash: quit through AppKit so the
        // sentinel is cleared, instead of dying and having the wallpapers held back next launch.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { AppTermination.shared.quit() }
        source.resume()
        terminationSignal = source
    }

    /// Call once the app has finished launching.
    func showPendingNotice() {
        guard let pending else { return }
        showNotice(for: pending.suspects, reason: pending.reason)
    }

    /// Call from `applicationWillTerminate`.
    func applicationWillTerminate() {
        watchdog.disarm()
        ledger.cleanExit()
        store.save(ledger)
    }

    // MARK: - Session tracking

    private func recordSession(wallpapers: [String: WEWallpaper], enabledScreens: Set<String>) {
        // A split display's regions are on their display.
        let showing = wallpapers.filter {
            enabledScreens.contains(DisplayLayoutResolution.screen(of: $0.key)) && $0.value.project != .invalid
        }
        let previous = ledger.activeSession ?? [:]
        let unchanged = showing.count == previous.count && showing.allSatisfy { screenId, wallpaper in
            previous[screenId].map(SafeRestartLedger.key(for:)) == SafeRestartLedger.key(for: wallpaper)
        }
        guard !unchanged else { return }
        ledger.sessionChanged(to: showing)
        store.save(ledger)
        if showing.isEmpty {
            watchdog.disarm()
        } else {
            watchdog.arm()
        }
    }

    private func unload(_ suspects: [SafeRestartLedger.Suspect], in viewModel: WallpaperViewModel) {
        let keys = Set(suspects.map { SafeRestartLedger.key(for: $0.wallpaper) })
        for (screenId, wallpaper) in viewModel.wallpapers where keys.contains(SafeRestartLedger.key(for: wallpaper)) {
            viewModel.wallpapers[screenId] = WallpaperViewModel.defaultWallpaper
        }
        viewModel.isPlaylistSuspended = true
    }

    // MARK: - Watchdog

    private func watchdogTripped(_ trip: RenderWatchdog.Trip) {
        guard let viewModel, let session = ledger.activeSession, !session.isEmpty else { return }
        let suspects = SafeRestartLedger.suspects(in: session, flagged: ledger)
        let names = suspects.map(\.wallpaper.project.title).joined(separator: ", ")
        OWELog.error(.app, "Unloading \(names): the app stayed unresponsive (\(trip))")
        unload(suspects, in: viewModel)
        showNotice(for: suspects, reason: .unresponsive(trip))
    }

    // MARK: - Flagged wallpapers

    private func confirmApplying(_ wallpaper: WEWallpaper) -> Bool {
        guard ledger.isFlagged(wallpaper) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Apply “\(wallpaper.project.title)”?")
        alert.informativeText = String(localized: """
        This wallpaper was showing when Open Wallpaper Engine crashed, hung or was force-quit twice \
        in a row. It may do so again.
        """)
        alert.addButton(withTitle: String(localized: "Apply Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Notice

    private func showNotice(for suspects: [SafeRestartLedger.Suspect], reason: Reason) {
        let names = suspects.map { "“\($0.wallpaper.project.title)”" }.joined(separator: ", ")
        var message: String
        switch reason {
        case .uncleanExit:
            message = String(localized: "\(names) was stopped because Open Wallpaper Engine didn't quit cleanly last time.")
        case .unresponsive:
            message = String(localized: "\(names) was stopped because it made Open Wallpaper Engine unresponsive.")
        }
        if suspects.contains(where: \.isFlagged) {
            message += " " + String(localized: "It has now done this twice in a row and is flagged in the library.")
        }
        notice?.close()
        notice = SafeRestartNotice(message: message,
                                   onRetry: { [weak self] in self?.retry(suspects) },
                                   onDismiss: { [weak self] in self?.dismissNotice() })
        notice?.show()
    }

    private func retry(_ suspects: [SafeRestartLedger.Suspect]) {
        dismissNotice()
        guard let viewModel else { return }
        for suspect in suspects {
            for screenId in suspect.screenIds {
                viewModel.setWallpaper(suspect.wallpaper, for: screenId)
            }
        }
        viewModel.isPlaylistSuspended = false
    }

    private func dismissNotice() {
        pending = nil
        notice?.close()
        notice = nil
    }
}
