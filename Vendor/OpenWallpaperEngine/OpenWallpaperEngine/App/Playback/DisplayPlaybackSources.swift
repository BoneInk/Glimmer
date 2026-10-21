import AppKit
import IOKit.ps

/// What `DisplayPlaybackMonitor` reads from the system, injectable so tests don't depend on the
/// real desktop.
///
/// `displays`, `frontmostPID` and `showsWebWallpaper` are read on the main thread; `windows`,
/// `otherApplicationPlayingAudio` and `onBattery` are the expensive ones (the window server,
/// Core Audio, IOKit) and are read on the monitor's scan queue.
struct DisplayPlaybackSources: @unchecked Sendable {
    /// Applications' windows, front to back.
    var windows: () -> [DesktopWindow]
    var displays: () -> [DesktopDisplay]
    /// The active application, nil when it is the desktop (Finder) or this app.
    var frontmostPID: () -> pid_t?
    /// This app's process, whose windows never count as another application's.
    var ownPID: pid_t
    /// Whether a web wallpaper is on screen (its sound then comes from WebKit's helpers).
    var showsWebWallpaper: () -> Bool = { false }
    /// Another application plays sound; the argument leaves WebKit's helper processes out.
    var otherApplicationPlayingAudio: (_ ignoringWebKit: Bool) -> Bool
    var onBattery: () -> Bool
    /// The running applications' bundle identifiers by process (Application Rules). Main thread.
    var applications: () -> [pid_t: String] = { [:] }
    /// The bundle identifiers of the processes playing sound now, this app's left out
    /// (Application Rules' "is playing audio"). Any thread.
    var audioProcesses: () -> Set<String> = { [] }
    /// Starts following which processes play sound; `changed` is called on any thread when that
    /// changes. The returned closure stops following.
    var observeAudioProcesses: (_ changed: @escaping @Sendable () -> Void) -> (() -> Void) = { _ in {} }
    /// Whether the screen is locked and whether this user's session is the one in front, read
    /// when the monitor starts and when the session becomes active again. Main thread.
    var session: () -> DesktopSessionState = { DesktopSessionState() }
    /// Where the workspace's notifications arrive (`NSWorkspace`'s center in the app).
    var workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    /// Where the system's distributed notifications arrive: the screen's lock and unlock.
    var distributedNotifications: NotificationCenter = DistributedNotificationCenter.default()
}

/// The login session's state, as the window server reports it (`CGSessionCopyCurrentDictionary`).
struct DesktopSessionState: Equatable {
    /// The screen is locked: `screenLockedNotification` until `screenUnlockedNotification`.
    var screenLocked = false
    /// This user's session is the one on the console (not switched away from).
    var active = true

    /// The distributed notifications loginwindow posts when the screen locks and unlocks.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// The window server's answer now; a session it can't describe counts as unlocked and active.
    static func current() -> DesktopSessionState {
        // Optional: nil only without a window server session (then nothing is shown anyway).
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return DesktopSessionState() }
        return DesktopSessionState(screenLocked: (info["CGSSessionScreenIsLocked"] as? Bool) ?? false,
                                   active: (info[kCGSessionOnConsoleKey as String] as? Bool) ?? true)
    }
}

extension DisplayPlaybackSources {
    /// The real desktop. `showsWebWallpaper` tells whether a web wallpaper is on screen: its sound
    /// comes from WebKit's shared helper processes, which then can't count as another application.
    @MainActor
    static func system(showsWebWallpaper: @escaping @MainActor () -> Bool) -> DisplayPlaybackSources {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let audio = OtherApplicationAudio(ownPID: ownPID)
        let audioProcesses = ProcessAudioOutputWatch(ownPID: ownPID)
        return DisplayPlaybackSources(
            windows: { DesktopWindowList.onScreen() },
            displays: { DesktopWindowList.displays() },
            frontmostPID: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.processIdentifier != ownPID,
                      // Clicking the desktop activates Finder: WE's desktop isn't another application.
                      app.bundleIdentifier != "com.apple.finder" else { return nil }
                return app.processIdentifier
            },
            ownPID: ownPID,
            showsWebWallpaper: { MainActor.assumeIsolated { showsWebWallpaper() } },
            otherApplicationPlayingAudio: { audio.isPlaying(ignoringWebKit: $0) },
            onBattery: { PowerSource.isOnBattery() },
            applications: {
                var applications: [pid_t: String] = [:]
                for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
                    // Optional: a process without a bundle can't be named by a rule.
                    if let bundleIdentifier = app.bundleIdentifier { applications[app.processIdentifier] = bundleIdentifier }
                }
                return applications
            },
            audioProcesses: { audioProcesses.playingBundleIdentifiers },
            observeAudioProcesses: { changed in
                audioProcesses.start(changed: changed)
                return { audioProcesses.stop() }
            },
            session: { DesktopSessionState.current() })
    }
}

/// The window server's view of the desktop.
enum DesktopWindowList {
    /// Windows on screen in the current Spaces, front to back. Needs no permission: only the
    /// owner, level, alpha and bounds are read, not window titles. Safe on any thread.
    static func onScreen() -> [DesktopWindow] {
        // Optional: nil only when the window server can't be reached (no session).
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var applications: [pid_t: Bool] = [:]
        func isApplication(_ pid: pid_t) -> Bool {
            if let known = applications[pid] { return known }
            let regular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            applications[pid] = regular
            return regular
        }
        return list.compactMap { info -> DesktopWindow? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            return DesktopWindow(ownerPID: pid, bounds: bounds, layer: layer,
                                 alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                 isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true,
                                 // Only normal-level windows can count; their owners are looked up once.
                                 ownerIsApplication: layer == 0 && isApplication(pid))
        }
    }

    /// The displays, main display first, in window-server coordinates (origin at the main
    /// display's top left, y down).
    @MainActor
    static func displays() -> [DesktopDisplay] {
        let screens = NSScreen.screens
        guard let mainHeight = screens.first?.frame.maxY else { return [] }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.map {
            DesktopDisplay(id: WallpaperViewModel.screenId(for: $0), frame: flipped($0.frame),
                           visibleFrame: flipped($0.visibleFrame))
        }
    }
}

/// Whether the Mac draws from its battery.
enum PowerSource {
    static func isOnBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        // Optional: a Mac without a battery has no providing source type.
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPMBatteryPowerKey
    }
}
