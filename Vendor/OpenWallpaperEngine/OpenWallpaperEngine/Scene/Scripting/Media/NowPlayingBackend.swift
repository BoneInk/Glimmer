import Foundation

/// How the app reads the system's now-playing session on this macOS.
///
/// - Before 15.4, MediaRemote answers any process, so the app calls it directly (`MediaRemote`).
/// - From 15.4 it answers only Apple's own processes, so the app streams the session from
///   `/usr/bin/perl` (`NowPlayingAdapter`), which ships with macOS: nothing extra to install. A
///   helper inside the app can't do it, since it would need Apple's private MediaRemote entitlement.
enum NowPlayingBackend: Equatable {
    case mediaRemote
    case adapter

    static let script = (name: "nowPlayingAdapter", extension: "pl")

    static func forSystem(_ version: OperatingSystemVersion) -> NowPlayingBackend {
        (version.majorVersion, version.minorVersion) >= (15, 4) ? .adapter : .mediaRemote
    }

    /// The framework for this system, or nil (logged once) when it can't work.
    static func load(version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                     bundle: Bundle = AppBundleLayout.framework) -> NowPlayingFramework? {
        switch forSystem(version) {
        case .mediaRemote:
            return MediaRemote.load()
        case .adapter:
            guard let script = bundle.url(forResource: script.name, withExtension: script.extension) else {
                OWELog.error(.script, "\(script.name).\(script.extension) is missing from the app; wallpapers get no media events")
                return nil
            }
            guard FileManager.default.isExecutableFile(atPath: PerlNowPlayingAdapterProcess.perl.path) else {
                OWELog.error(.script, "\(PerlNowPlayingAdapterProcess.perl.path) is missing; wallpapers get no media events")
                return nil
            }
            return NowPlayingAdapter { PerlNowPlayingAdapterProcess(script: script) }
        }
    }
}
