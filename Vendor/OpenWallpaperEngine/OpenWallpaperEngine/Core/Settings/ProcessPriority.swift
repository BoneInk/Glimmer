import Darwin
import Foundation

/// Settings › Process Priority, WE's "Process priority" for the wallpaper process, mapped to macOS:
/// the scheduling priority (`nice`) of the whole process and the quality of service of its render
/// and preparation threads.
///
/// - **Normal:** nice 0; render threads user-interactive, so frames are never starved; the
///   wallpaper being set prepares at user-initiated.
/// - **Below Normal:** nice 5, so the app yields the CPU to other apps; render threads drop to
///   user-initiated (still well above background, so a scene keeps its frame rate on an idle Mac)
///   and the wallpaper being set prepares at utility.
///
/// Library preparation stays at background and the current wallpaper's preparation at utility
/// either way. Helper processes set their own priority (background, nice 10) and are left alone.
struct ProcessPriority: Equatable, Sendable {
    /// The process's nice value.
    let nice: Int32
    /// The QoS of the scene render threads (`SceneRenderThread`).
    let renderQoS: DispatchQoS.QoSClass
    /// The QoS of the preparation workers for the wallpaper being set.
    let settingWallpaperQoS: DispatchQoS.QoSClass
    /// The QoS of the preparation workers for the displays' current wallpapers.
    let currentWallpaperQoS: DispatchQoS.QoSClass
    /// The QoS of the library's background preparation.
    let libraryQoS: DispatchQoS.QoSClass

    init(_ setting: GSProcessPiority) {
        switch setting {
        case .normal:
            nice = 0
            renderQoS = .userInteractive
            settingWallpaperQoS = .userInitiated
        case .belowNormal:
            nice = 5
            renderQoS = .userInitiated
            settingWallpaperQoS = .utility
        }
        currentWallpaperQoS = .utility
        libraryQoS = .background
    }

    func preparationQoS(_ priority: PreparationPool.Priority) -> DispatchQoS.QoSClass {
        switch priority {
        case .settingWallpaper: settingWallpaperQoS
        case .currentWallpaper: currentWallpaperQoS
        case .library: libraryQoS
        }
    }

    /// `renderQoS` for `Thread.qualityOfService`.
    var renderThreadQoS: QualityOfService { Self.threadQoS(renderQoS) }

    static func threadQoS(_ qos: DispatchQoS.QoSClass) -> QualityOfService {
        switch qos {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        default: .default
        }
    }

    // MARK: - The process's priority

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = ProcessPriority(.normal)

    /// The priority in effect; read by the render threads and the preparation pool when they
    /// start work.
    static var current: ProcessPriority {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    /// Applies `setting`: at launch, and again whenever the setting changes.
    ///
    /// Raising the nice value always works; lowering it again needs root on macOS, so going back
    /// to Normal restores the threads' QoS at once and the process's nice value at the next launch.
    static func apply(_ setting: GSProcessPiority) {
        let priority = ProcessPriority(setting)
        lock.lock()
        let changed = _current != priority
        _current = priority
        lock.unlock()
        if setpriority(PRIO_PROCESS, 0, priority.nice) != 0 {
            let reason = String(cString: strerror(errno))
            OWELog.info(.app, "Process nice stays at \(getpriority(PRIO_PROCESS, 0)) until the next launch (\(reason))")
        }
        if changed { SceneRenderThread.applyQoS(priority.renderQoS) }
    }
}
