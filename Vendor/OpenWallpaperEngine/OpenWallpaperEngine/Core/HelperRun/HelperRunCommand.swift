import AppKit
import Darwin

/// The app's helper runs, handled in `AppMain` before any app lifecycle starts:
/// - `--shader-compile-helper` translates shaders for the app that started it
///   (`ShaderCompileHelperServer`) until that app closes its stdin;
/// - `--print-shader-cache-key` prints this build's `ShaderCacheKey` as one line of JSON;
/// - `--prepare-wallpapers <folders>` prepares arrived scenes the same way, and writes their
///   loading snapshots (`SceneLoadingSnapshotStore`);
/// - `--prewarm-shaders` compiles the shown and recent wallpapers into the shader caches
///   (`ShaderPrewarm`) with no UI, no Dock icon, no wallpaper windows, status item, audio capture
///   or asset installs, at background priority.
///
/// Both run in the isolated state the caller passes (`OWE_ISOLATED_STATE`), with read-only
/// defaults (`AppStorageLocation`), and exit when done.
enum HelperRunCommand {
    static let printKeyArgument = "--print-shader-cache-key"
    static let prewarmArgument = "--prewarm-shaders"
    static let prepareArgument = "--prepare-wallpapers"

    /// `--render-live-photo <job.json>` renders a Live Photo (`LivePhotoJob`, `LivePhotoRenderer`),
    /// writing its progress to standard output.
    static let livePhotoArgument = "--render-live-photo"

    /// `--render-android-video <job.json>` renders an Android export's pre-rendered video
    /// (`AndroidVideoJob`, `AndroidVideoRenderer`), writing its progress to standard output.
    static let androidVideoArgument = "--render-android-video"

    /// `--render-editor-previews <job.json>` renders the Wallpaper Editor's previews of effects
    /// and particle systems (`EditorPreviewJob`, `EditorPreviewRenderer`), writing a line to
    /// standard output as each is done; `--render-editor-previews -` reads them from standard
    /// input until it closes (the background pre-warm, `EditorPreviewPrewarm`).
    static let editorPreviewArgument = "--render-editor-previews"

    static func isHelperRun(arguments: [String]) -> Bool {
        arguments.contains(printKeyArgument) || arguments.contains(prewarmArgument)
            || arguments.contains(ShaderCompileHelperServer.argument)
            || arguments.contains(prepareArgument)
            || arguments.contains(livePhotoArgument) || arguments.contains(editorPreviewArgument)
            || arguments.contains(androidVideoArgument)
    }

    /// `<width>x<height>` as numbers, nil otherwise.
    static func size(_ text: String) -> SIMD2<Int>? {
        let parts = text.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return SIMD2(parts[0], parts[1])
    }

    /// Runs the helper `arguments` ask for and returns its exit status, or nil for a normal launch.
    @MainActor
    static func run(arguments: [String]) -> Int32? {
        if arguments.contains(ShaderCompileHelperServer.argument) {
            defer { AppStorageLocation.current.discardReadOnlyScratch() }
            return ShaderCompileHelperServer.run()
        }
        if arguments.contains(printKeyArgument) {
            defer { AppStorageLocation.current.discardReadOnlyScratch() }
            do {
                FileHandle.standardOutput.write(try ShaderCacheKey.current.encoded() + Data("\n".utf8))
                return 0
            } catch {
                OWELog.error(.app, "Can't encode the shader cache key: \(error)")
                return 1
            }
        }
        if let index = arguments.firstIndex(of: androidVideoArgument) {
            defer { AppStorageLocation.current.discardReadOnlyScratch() }
            // The user waits for it: user-initiated, not background, priority.
            NSApplication.shared.setActivationPolicy(.prohibited)
            exitWithParent()
            guard index + 1 < arguments.count else {
                OWELog.error(.app, "Android export: no video job file")
                return 2
            }
            do {
                let data = try Data(contentsOf: URL(filePath: arguments[index + 1], directoryHint: .notDirectory))
                return AndroidVideoRenderer.run(try JSONDecoder().decode(AndroidVideoJob.self, from: data))
            } catch {
                OWELog.error(.app, "Android export: unreadable video job: \(error)")
                return 2
            }
        }
        if let index = arguments.firstIndex(of: livePhotoArgument) {
            defer { AppStorageLocation.current.discardReadOnlyScratch() }
            // The user waits for it: user-initiated, not background, priority.
            NSApplication.shared.setActivationPolicy(.prohibited)
            exitWithParent()
            guard index + 1 < arguments.count,
                  let data = try? Data(contentsOf: URL(filePath: arguments[index + 1], directoryHint: .notDirectory)),
                  let job = try? JSONDecoder().decode(LivePhotoJob.self, from: data) else {
                OWELog.error(.app, "Live Photo: unreadable job")
                return 2
            }
            return LivePhotoRenderer.run(job)
        }
        if let index = arguments.firstIndex(of: editorPreviewArgument) {
            defer { AppStorageLocation.current.discardReadOnlyScratch() }
            NSApplication.shared.setActivationPolicy(.prohibited)
            exitWithParent()
            guard index + 1 < arguments.count else {
                OWELog.error(.app, "Editor previews: no job file")
                return 2
            }
            if arguments[index + 1] == EditorPreviewJob.streamArgument {
                // The background pre-warm's lane: in the background state but for a browser's tiles.
                return EditorPreviewRenderer.runStream()
            }
            let jobFile = URL(filePath: arguments[index + 1], directoryHint: .notDirectory)
            do {
                let job = try JSONDecoder().decode(EditorPreviewJob.self, from: Data(contentsOf: jobFile))
                return EditorPreviewRenderer.run(job)
            } catch {
                OWELog.error(.app, "Editor previews: unreadable job \(jobFile.path): \(error)")
                return 2
            }
        }
        let prepareIndex = arguments.firstIndex(of: prepareArgument)
        guard arguments.contains(prewarmArgument) || prepareIndex != nil else { return nil }
        defer { AppStorageLocation.current.discardReadOnlyScratch() }
        // Background priority for the CPU work (shader translation); Metal compiles in its own
        // service. No Dock icon or menu bar: an app that is never activated.
        setpriority(PRIO_PROCESS, 0, 10)
        NSApplication.shared.setActivationPolicy(.prohibited)
        exitWithParent()
        OWELog.info(.app, "Shader prewarm started (pid \(ProcessInfo.processInfo.processIdentifier))")
        let report: ShaderPrewarm.Report
        if let prepareIndex {
            let (displays, main) = ShaderPrewarmTargets.connectedDisplays()
            let display = main.flatMap { displays[$0] } ?? displays.values.first
                ?? ShaderPrewarmTargets.Display(drawableSize: SIMD2(1920, 1080), pointSize: SIMD2(1920, 1080))
            let targets = arguments[(prepareIndex + 1)...]
                .compactMap { InstalledLibrary.wallpaper(at: URL(filePath: $0, directoryHint: .isDirectory), hiding: []) }
                .filter { $0.project.type.caseInsensitiveCompare("scene") == .orderedSame }
                .map { ShaderPrewarmTargets.Target(wallpaper: $0, display: display) }
            var prepare = ShaderPrewarm(defaults: .app)
            // The picture shown while the wallpaper loads, at each display's size.
            prepare.loadingSnapshots = .current
            prepare.snapshotDisplays = displays.values.sorted { $0.drawableSize.x * $0.drawableSize.y > $1.drawableSize.x * $1.drawableSize.y }
            report = prepare.run(targets)
            // The texture blobs the loads scheduled.
            var idle = false
            PreparationPool.shared.whenIdle { idle = true }
            while !idle { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        } else {
            report = ShaderPrewarm(defaults: .app).run()
        }
        return report.wallpapers > 0 && report.failed == report.wallpapers ? 1 : 0
    }

    /// A helper run exists only for the app that started it: when that app quits or dies, the
    /// helper stops too instead of running on alone.
    private static var parentWatch: DispatchSourceProcess?

    private static func exitWithParent() {
        let parent = getppid()
        guard parent > 1 else { exit(0) } // Already orphaned.
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { exit(0) }
        source.resume()
        parentWatch = source
    }
}
