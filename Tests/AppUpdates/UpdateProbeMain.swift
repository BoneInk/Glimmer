import AppKit
import Foundation
import Sparkle

/// Real Sparkle host used only in temporary .apps with distinct bundle IDs.
@main
@MainActor
enum UpdateProbeMain {
    static func main() {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            ProbeDelegate.record("relaunched", extra: ["build": "2"])
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let updater: GWAppUpdater = {
        if Bundle.main.object(forInfoDictionaryKey: "GWUpdateProbeMode") as? String == "native" {
            return GWAppUpdater()
        }
        return GWAppUpdater(userDriver: ProbeUserDriver())
    }()
    var timer: Timer?
    var isFinishing = false
    var postponedTermination = false
    var startedAt = Date()

    static func record(_ phase: String, extra: [String: String] = [:]) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "GWUpdateProbeLog") as? String else { return }
        let entry = ["phase": phase].merging(extra) { _, new in new }
        var timed = entry
        timed["time"] = String(Date().timeIntervalSince1970)
        let data = try! JSONSerialization.data(withJSONObject: timed, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! file.seekToEnd()
        try! file.write(contentsOf: data)
        try! file.close()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // These preferences belong only to this test's random bundle ID.
        // Confirm our toggles survive creating a second updater instance.
        updater.start()
        Self.record("started", extra: ["checks": String(updater.automaticallyChecksForUpdates),
                                       "downloads": String(updater.automaticallyDownloadsUpdates)])
        if Bundle.main.object(forInfoDictionaryKey: "GWUpdateProbeMode") as? String == "toggle-off" {
            updater.setAutomaticallyChecksForUpdates(true)
            updater.setAutomaticallyChecksForUpdates(false)
            Self.record("reminders-disabled", extra: ["checks": String(updater.automaticallyChecksForUpdates)])
            NSApp.terminate(nil)
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "GWUpdateProbeMode") as? String == "manual-disabled" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                Self.record("manual-check", extra: ["checks": String(updater.automaticallyChecksForUpdates)])
                updater.checkForUpdates()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        guard !isFinishing else { return }
        if updater.hasError {
            Self.record("error", extra: ["message": updater.statusMessage])
            isFinishing = true
            NSApp.terminate(nil)
        } else if updater.statusMessage == "没有适用于当前系统的新版本" {
            Self.record("no-update")
            isFinishing = true
            NSApp.terminate(nil)
        } else if Date().timeIntervalSince(startedAt) > 100 {
            Self.record("timeout", extra: ["message": updater.statusMessage])
            isFinishing = true
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !postponedTermination else { return .terminateNow }
        postponedTermination = true
        Self.record("draining")
        let completion = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                Self.record("drained")
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(completion, forMode: .common)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.record("terminated")
        timer?.invalidate()
    }
}

/// Models the user's explicit choice, after leaving the prompt unanswered long
/// enough for the HTTP log to prove there was no automatic archive download.
@MainActor
private final class ProbeUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ProbeDelegate.record("offered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let decline = Bundle.main.object(forInfoDictionaryKey: "GWUpdateProbeMode") as? String == "decline"
            ProbeDelegate.record(decline ? "dismissed" : "confirmed")
            reply(decline ? .dismiss : .install)
            if decline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { ProbeDelegate.record("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { ProbeDelegate.record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ProbeDelegate.record("ready")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}
