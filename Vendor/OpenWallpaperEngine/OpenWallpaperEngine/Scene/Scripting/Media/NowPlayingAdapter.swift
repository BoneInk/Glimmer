import Foundation

/// The system's now-playing session on macOS 15.4 and later, where MediaRemote answers only
/// Apple's own processes: `nowPlayingAdapter.pl` reads it inside `/usr/bin/perl` and streams each
/// change as a line (see the script for why and how). To `MacMediaSessionSource` it looks like
/// MediaRemote: registering starts the script, unregistering stops it, and each session it reports
/// is cached and announced through `notificationNames`.
///
/// It is unavailable (`isAvailable == false`, so wallpapers see media integration disabled and get
/// no events) until the script has reported, and after it failed; the failure is logged once. A
/// failed script is not restarted until the last listener has left and a new one registers.
final class NowPlayingAdapter: NowPlayingFramework {
    /// One line of the script's output.
    enum Line: Equatable {
        /// `S <base64 binary plist>`: MediaRemote's keys (`MediaRemote.Key`) and `isPlaying`.
        case session(info: NSDictionary, isPlaying: Bool)
        /// `E <reason>`: the script failed and exits.
        case failure(String)
    }

    let notificationNames: [Notification.Name]
    private let makeProcess: () -> NowPlayingAdapterProcess

    /// Owns every var below: output and exits arrive on the process's threads, the rest on the
    /// media source's queue.
    private let lock = NSLock()
    private var process: NowPlayingAdapterProcess?
    /// Which start the output belongs to; output of an earlier start is ignored.
    private var run = 0
    private var pending = Data()
    private var info: [String: Any] = [:]
    private var playing = false
    private var available = false
    private var loggedFailure = false

    init(makeProcess: @escaping () -> NowPlayingAdapterProcess) {
        self.makeProcess = makeProcess
        notificationNames = [Notification.Name("OpenWallpaperEngine.NowPlayingAdapter.\(UUID().uuidString)")]
    }

    deinit {
        process?.stop()
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func register(on queue: DispatchQueue) {
        lock.lock()
        guard process == nil else {
            lock.unlock()
            return
        }
        run += 1
        let run = self.run
        let process = makeProcess()
        self.process = process
        lock.unlock()
        do {
            try process.start(output: { [weak self] data in self?.received(data, run: run) },
                              exit: { [weak self] status in self?.exited(status, run: run) })
        } catch {
            fail(run: run, "could not start /usr/bin/perl: \(error)")
        }
    }

    func unregister() {
        lock.lock()
        let process = self.process
        self.process = nil
        run += 1
        reset()
        lock.unlock()
        process?.stop()
    }

    func nowPlayingInfo(on queue: DispatchQueue, _ handler: @escaping ([String: Any]) -> Void) {
        lock.lock()
        let info = self.info
        lock.unlock()
        queue.async { handler(info) }
    }

    func isPlaying(on queue: DispatchQueue, _ handler: @escaping (Bool) -> Void) {
        lock.lock()
        let playing = self.playing
        lock.unlock()
        queue.async { handler(playing) }
    }

    // MARK: - The stream

    private func received(_ data: Data, run: Int) {
        lock.lock()
        guard run == self.run else {
            lock.unlock()
            return
        }
        pending.append(data)
        let lines = Self.takeLines(from: &pending)
        var changed = false
        var failure: String?
        for text in lines {
            switch Self.parse(text) {
            case .session(let info, let isPlaying):
                self.info = (info as? [String: Any]) ?? [:]
                playing = isPlaying
                available = true
                changed = true
            case .failure(let reason):
                failure = reason
            case nil:
                OWELog.debug(.script, "Ignoring a malformed Now Playing adapter line (\(text.utf8.count) bytes)")
            }
        }
        lock.unlock()
        if let failure {
            fail(run: run, failure)
        } else if changed {
            announce()
        }
    }

    private func exited(_ status: Int32, run: Int) {
        fail(run: run, "/usr/bin/perl exited with status \(status)")
    }

    /// Marks the adapter unavailable for this start, logging the first failure of the app's run.
    private func fail(run: Int, _ reason: String) {
        lock.lock()
        guard run == self.run, process != nil else {
            lock.unlock()
            return
        }
        let wasAvailable = available
        let log = !loggedFailure
        loggedFailure = true
        reset()
        let process = self.process
        self.process = nil
        // Later output and the exit of this start are ignored; the next registration starts anew.
        self.run += 1
        lock.unlock()
        process?.stop()
        if log {
            OWELog.error(.script, "The Now Playing adapter is unavailable (\(reason)); wallpapers get no media events")
        }
        if wasAvailable { announce() }
    }

    /// Clears the session. Called with `lock` held.
    private func reset() {
        pending.removeAll()
        info = [:]
        playing = false
        available = false
    }

    private func announce() {
        for name in notificationNames { NotificationCenter.default.post(name: name, object: nil) }
    }

    // MARK: - Parsing

    /// Removes the complete lines from `buffer` and returns them; a partial last line stays.
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// One output line, or nil when it is malformed.
    static func parse(_ line: String) -> Line? {
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if text.hasPrefix("E ") { return .failure(String(text.dropFirst(2))) }
        guard text.hasPrefix("S "), let data = Data(base64Encoded: String(text.dropFirst(2))) else { return nil }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            return nil
        }
        guard let dictionary = plist as? [String: Any] else { return nil }
        var info = dictionary
        let isPlaying = (info.removeValue(forKey: "isPlaying") as? NSNumber)?.boolValue ?? false
        return .session(info: info as NSDictionary, isPlaying: isPlaying)
    }
}
