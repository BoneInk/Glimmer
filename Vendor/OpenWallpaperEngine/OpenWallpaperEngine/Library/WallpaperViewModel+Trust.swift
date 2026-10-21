import Foundation

/// A wallpaper waiting on the trust prompt; each request is its own, even for the same wallpaper.
struct WallpaperTrustRequest: Equatable {
    let id = UUID()
    var wallpaper: WEWallpaper
    /// The displays selected when it was applied: Proceed sets it there.
    var screenIds: Set<String>
    /// It was trusted before, and its folder's content changed since.
    var contentChanged: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Applying a wallpaper chosen by hand, and the trust a wallpaper that runs code needs first.
extension WallpaperViewModel {
    /// A web or application wallpaper, which runs its own code; whatever the case of the
    /// project's type, as the library reads it ("Web" is common).
    static func runsCode(_ wallpaper: WEWallpaper) -> Bool {
        ["web", "application"].contains(wallpaper.project.type.lowercased())
    }

    /// A wallpaper that runs code and isn't on the trust list: applying it certainly asks first.
    /// Doesn't read the folder, so a listed one whose content changed since passes here and asks
    /// when applied.
    static func needsTrust(_ wallpaper: WEWallpaper, store: WallpaperTrustStore = WallpaperTrustStore()) -> Bool {
        runsCode(wallpaper) && !store.isListed(wallpaper)
    }

    /// Whether the wallpaper may run now without asking: it runs no code, or it is trusted and its
    /// folder holds what was trusted. Reads the folder; for one-off applies that can't ask (the
    /// control channel, application rules).
    static func mayRunWithoutAsking(_ wallpaper: WEWallpaper, store: WallpaperTrustStore = WallpaperTrustStore()) -> Bool {
        !runsCode(wallpaper) || (store.isListed(wallpaper) && store.verdict(for: wallpaper) == .trusted)
    }

    /// Applies a wallpaper the user chose on the selected displays, after safe restart's check.
    /// One that runs code applies once the user trusted it and its folder still holds what was
    /// trusted (read off the main thread); otherwise it waits in `trustRequest` for the prompt,
    /// and nothing else changes until the user answers.
    func apply(_ wallpaper: WEWallpaper) {
        apply(wallpaper, on: selectedScreenIds)
    }

    /// `apply(_:)` on `screenIds` instead of the selected displays: a wallpaper hotkey's display.
    func apply(_ wallpaper: WEWallpaper, on screenIds: Set<String>) {
        trustCheck?.cancel()
        trustCheck = nil
        guard confirmApply?(wallpaper) ?? true else { return }
        guard Self.runsCode(wallpaper) else {
            setWallpaper(wallpaper, for: screenIds, transition: .manual)
            return
        }
        guard trustStore.isListed(wallpaper) else {
            requestTrust(for: wallpaper, on: screenIds, contentChanged: false, fingerprint: nil)
            return
        }
        let fingerprint = Self.fingerprintTask(of: wallpaper)
        trustCheck = Task { [weak self] in
            let current = await fingerprint.value
            guard let self, !Task.isCancelled else { return }
            self.trustCheck = nil
            switch self.trustStore.verdict(for: wallpaper, fingerprint: current) {
            case .trusted:
                self.setWallpaper(wallpaper, for: screenIds, transition: .manual)
                // Points out a wallpaper that needs Chromium while it isn't installed.
                ChromiumFeatureAdvisor.shared.wallpaperApplied(wallpaper)
            case .changed, .untrusted:
                OWELog.info(.library, "\(wallpaper.wallpaperDirectory.lastPathComponent) changed since it was trusted")
                self.requestTrust(for: wallpaper, on: screenIds, contentChanged: true, fingerprint: current)
            }
        }
    }

    /// The prompt's Proceed: applies the waiting wallpaper as an apply that needs no prompt does
    /// (on the displays selected when it was applied, with Settings' transition) and, with
    /// `remember`, trusts its folder as it was when the prompt asked. Returns the task that records the trust, for tests to wait on.
    @discardableResult
    func proceedWithTrustRequest(remember: Bool) -> Task<Void, Never>? {
        guard let request = trustRequest else { return nil }
        let fingerprint = trustRequestFingerprint
        endTrustRequest()
        setWallpaper(request.wallpaper, for: request.screenIds, transition: .manual)
        ChromiumFeatureAdvisor.shared.wallpaperApplied(request.wallpaper)
        guard remember, let fingerprint else { return nil }
        return Task { [trustStore] in
            trustStore.trust(request.wallpaper, fingerprint: await fingerprint.value)
        }
    }

    /// The prompt's Cancel, or the prompt closed: the waiting wallpaper is dropped.
    func endTrustRequest() {
        trustRequest = nil
        trustRequestFingerprint = nil
    }

    private func requestTrust(for wallpaper: WEWallpaper, on screenIds: Set<String>, contentChanged: Bool, fingerprint: String?) {
        trustRequest = WallpaperTrustRequest(wallpaper: wallpaper, screenIds: screenIds, contentChanged: contentChanged)
        // Read while the prompt counts down, so Proceed trusts the content the user was asked about.
        trustRequestFingerprint = fingerprint.map { known in Task { known } } ?? Self.fingerprintTask(of: wallpaper)
        askToTrust(wallpaper)
    }

    private static func fingerprintTask(of wallpaper: WEWallpaper) -> Task<String, Never> {
        let directory = wallpaper.wallpaperDirectory
        let type = wallpaper.project.type
        let entry = wallpaper.project.file
        return Task.detached(priority: .userInitiated) {
            WallpaperTrustStore.fingerprint(directory: directory, type: type, entry: entry)
        }
    }
}
