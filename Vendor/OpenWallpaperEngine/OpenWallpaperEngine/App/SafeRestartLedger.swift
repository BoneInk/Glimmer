//
//  SafeRestartLedger.swift
//  Open Wallpaper Engine
//

import Foundation

/// The crash-sentinel state machine behind safe restart. It is plain data, so it can be tested
/// without the app; `SafeRestartStore` persists it and `SafeRestart` drives it.
///
/// - While wallpapers are showing, `activeSession` names them (screen id → wallpaper).
/// - A clean exit clears the session and forgives the wallpapers in it.
/// - At launch, a session still on record means the last run ended uncleanly (crash, force quit,
///   hang, kernel panic, power loss). Its wallpapers are the suspects: they are not restored, and
///   each one's run of consecutive unclean exits grows by one. Two in a row flags the wallpaper.
struct SafeRestartLedger: Codable {
    /// Consecutive unclean exits that flag a wallpaper.
    static let flagThreshold = 2

    /// The wallpapers showing right now, keyed by screen id. `nil` when nothing is showing.
    private(set) var activeSession: [String: WEWallpaper]?
    /// Consecutive unclean exits per wallpaper, keyed by `SafeRestartLedger.key(for:)`.
    private(set) var uncleanExitCounts: [String: Int] = [:]

    /// A wallpaper the previous run was showing when it ended uncleanly.
    struct Suspect {
        var wallpaper: WEWallpaper
        var screenIds: [String]
        var isFlagged: Bool
    }

    static func key(for wallpaper: WEWallpaper) -> String {
        wallpaper.wallpaperDirectory.standardizedFileURL.path
    }

    /// Call once at launch, before anything is shown. Returns the wallpapers that were showing
    /// when the previous run ended uncleanly; empty after a clean exit.
    mutating func beginLaunch() -> [Suspect] {
        guard let session = activeSession, !session.isEmpty else {
            activeSession = nil
            return []
        }
        activeSession = nil
        for key in Set(session.values.map(Self.key(for:))) {
            uncleanExitCounts[key, default: 0] += 1
        }
        return Self.suspects(in: session, flagged: self)
    }

    /// Groups a session's screens by wallpaper, in a stable order.
    static func suspects(in session: [String: WEWallpaper], flagged ledger: SafeRestartLedger) -> [Suspect] {
        var byKey: [String: Suspect] = [:]
        for (screenId, wallpaper) in session.sorted(by: { $0.key < $1.key }) {
            byKey[key(for: wallpaper), default: Suspect(wallpaper: wallpaper, screenIds: [],
                                                        isFlagged: ledger.isFlagged(wallpaper))]
                .screenIds.append(screenId)
        }
        return byKey.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Records what is showing now. Pass an empty map when nothing is.
    mutating func sessionChanged(to wallpapers: [String: WEWallpaper]) {
        activeSession = wallpapers.isEmpty ? nil : wallpapers
    }

    /// The app is quitting normally: the wallpapers showing did no harm this time.
    mutating func cleanExit() {
        for wallpaper in (activeSession ?? [:]).values {
            uncleanExitCounts[Self.key(for: wallpaper)] = nil
        }
        activeSession = nil
    }

    func isFlagged(_ wallpaper: WEWallpaper) -> Bool {
        uncleanExitCounts[Self.key(for: wallpaper), default: 0] >= Self.flagThreshold
    }

    var flaggedKeys: Set<String> {
        Set(uncleanExitCounts.filter { $0.value >= Self.flagThreshold }.keys)
    }
}
