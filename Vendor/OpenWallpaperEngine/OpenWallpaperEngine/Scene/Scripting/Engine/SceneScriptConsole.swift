import Foundation

/// Where `console.log` and `console.error` go (lib.sceneScript.d.ts `IConsole`). WE writes them to
/// the editor's log or `log.txt` as `Log: …` / `Error: …` (scenescript64.dll); here they go to
/// `OWELog`, `.debug` for `log` and `.error` for `error`, naming the wallpaper instance and the
/// script. A script can log every frame, so at most `linesPerSecond` lines are written per second
/// of scene time; the rest are counted and reported once when the next second starts.
/// Confined to the runtime's thread.
final class SceneScriptConsole {
    enum Level {
        case log, error
    }

    typealias Sink = (Level, String) -> Void

    static let linesPerSecond = 20

    private let prefix: String
    private let wallpaperID: String
    private let sink: Sink
    private var windowStart = 0.0
    private var written = 0
    private var suppressed = 0

    init(identity: SceneScriptIdentity, sink: @escaping Sink = SceneScriptConsole.log) {
        prefix = "[\(identity.wallpaperID) \(identity.screenID)]"
        wallpaperID = identity.wallpaperID
        self.sink = sink
    }

    /// One `console.log`/`console.error` call at scene time `time` (seconds), by `scriptID`.
    func write(_ level: Level, message: String, scriptID: String, time: Double) {
        if time - windowStart >= 1 || time < windowStart {
            if suppressed > 0 {
                sink(.log, "\(prefix) \(suppressed) console lines suppressed (more than \(Self.linesPerSecond) per second)")
            }
            windowStart = time
            written = 0
            suppressed = 0
        }
        guard written < Self.linesPerSecond else {
            suppressed += 1
            return
        }
        written += 1
        let label = level == .error ? "Error: " : "Log: "
        let source = scriptID.isEmpty ? "" : " \(scriptID)"
        sink(level, "\(prefix)\(source) \(label)\(message)")
        // The Wallpaper Editor's console, when one is open for this wallpaper.
        SceneScriptConsoleTap.post(.init(wallpaperID: wallpaperID, scriptID: scriptID, isError: level == .error,
                                         message: message, line: nil))
    }

    static func log(_ level: Level, _ line: String) {
        switch level {
        case .log: OWELog.debug(.script, line)
        case .error: OWELog.error(.script, line)
        }
    }
}
