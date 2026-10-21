import Foundation

/// `nowPlayingAdapter.pl` in `/usr/bin/perl`, the system's own perl: MediaRemote answers it on
/// macOS 15.4 and later because its bundle id is Apple's (see the script).
///
/// The script's input is a pipe that stays open while it runs: when the app quits or crashes the
/// pipe closes and the script exits, so it never outlives the app. Its errors go to the log at
/// `.debug`; the `E` line on its output carries the reason it failed.
final class PerlNowPlayingAdapterProcess: NowPlayingAdapterProcess {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    private let script: URL
    /// Owns `process` and `input`: `start` and `stop` come from the media source's queue, the
    /// termination handler from Foundation's.
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?

    init(script: URL) {
        self.script = script
    }

    deinit {
        stop()
    }

    func start(output: @escaping (Data) -> Void, exit: @escaping (Int32) -> Void) throws {
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [script.path]
        // Only what perl needs, so a user's PERL5LIB or PERL5OPT can't change what runs.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let input = Pipe(), standardOutput = Pipe(), standardError = Pipe()
        process.standardInput = input
        process.standardOutput = standardOutput
        process.standardError = standardError
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            OWELog.debug(.script, "Now Playing adapter: \(String(decoding: data, as: UTF8.self))")
        }
        process.terminationHandler = { [weak self] ended in
            // Whatever is still buffered arrives before the exit.
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            let rest = standardOutput.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { output(rest) }
            self?.ended(ended)
            exit(ended.terminationStatus)
        }
        try process.run()
        lock.lock()
        self.process = process
        self.input = input
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let process = self.process, input = self.input
        self.process = nil
        self.input = nil
        lock.unlock()
        // Closing its input is how the script is told to exit; terminate covers a script that is
        // stuck in MediaRemote.
        do {
            try input?.fileHandleForWriting.close()
        } catch {
            OWELog.debug(.script, "Now Playing adapter's input was already closed: \(error)")
        }
        if let process, process.isRunning { process.terminate() }
    }

    private func ended(_ ended: Process) {
        lock.lock()
        if process === ended {
            process = nil
            input = nil
        }
        lock.unlock()
    }
}
