import Foundation
import OWESceneEditing
import QuartzCore
import os

/// Severity-gated logging plus near-zero-cost signposts and per-frame counters.
/// Signposts are always emitted: `os_signpost` compiles to a no-op unless Instruments is recording.
enum OWELog {
    enum Severity: Int, Comparable {
        case debug = 0, info = 1, error = 2, silent = 3
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Category: String {
        case scene = "SceneVM"
        case script = "SceneScript"
        case audio = "AudioCapture"
        case shader = "ShaderTranslator"
        case importer = "Import"
        case workshop = "Workshop"
        case texture = "TEXParser"
        case perf = "Perf"
        case app = "App"
        case library = "Library"
        case web = "Web"
        case settings = "Settings"
        case ui = "UI"
    }

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: [
        Category.scene, .script, .audio, .shader, .importer, .workshop, .texture, .perf,
        .app, .library, .web, .settings, .ui
    ].map { ($0, Logger(subsystem: "app.openwallpaperengine", category: $0.rawValue)) })

    /// Before the Log Level is applied, debug builds log lifecycle diagnostics (`.info`) too.
    nonisolated(unsafe) static var minimumSeverity: Severity = {
        #if DEBUG
        return .info
        #else
        return .error
        #endif
    }()

    /// The lowest severity a log level lets through: None logs nothing, Errors Only only errors,
    /// Verbose everything. The system's own faults still reach the unified log.
    static func threshold(for logLevel: GSLogLevel) -> Severity {
        switch logLevel {
        case .none: return .silent
        case .error: return .error
        case .verbose: return .debug
        }
    }

    /// Whether a message of `severity` is logged at `logLevel`.
    static func logs(_ severity: Severity, at logLevel: GSLogLevel) -> Bool {
        severity != .silent && severity >= threshold(for: logLevel)
    }

    /// Applies the user's Log Level. Until it is applied (early launch), debug builds log from
    /// `.info` and release builds errors.
    static func apply(logLevel: GSLogLevel) {
        minimumSeverity = threshold(for: logLevel)
        EditorLog.isEnabled = logs(.error, at: logLevel)
        OWEFrameMetrics.isReportingEnabled = (logLevel == .verbose) || OWEFrameMetrics.defaultsEnabled
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        emit(.debug, category, message)
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        emit(.info, category, message)
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        emit(.error, category, message)
    }

    private static func emit(_ severity: Severity,
                             _ category: Category,
                             _ message: () -> String) {
        if severity == .error, let context = SceneBackendRuntimeContext.current { context.recordError(message()) }
        var researchText: String?
        if SceneBackendRuntimeContext.isActive, severity != .silent {
            let value = message()
            researchText = value
            FileHandle.standardError.write(Data("[OWE][\(severity)][\(category.rawValue)] \(value)\n".utf8))
        }
        guard severity != .silent, severity >= minimumSeverity, let logger = loggers[category] else { return }
        // Public: these messages carry paths and effect names, which the unified log would
        // otherwise redact to <private> and make useless for diagnosing a wallpaper.
        let text = researchText ?? message()
        switch severity {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .silent: break
        }
    }
}
