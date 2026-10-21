import AppKit

/// The command line's side of `--control` (`CommandLineControlRequest`): the app's executable,
/// started with `--control <verb> …` while the app runs, hands the command to the running app
/// and exits with its answer, as `wallpaper64.exe -control` does. It never starts a second app:
/// WE's commands need the app running, and so do these.
///
/// The command and its answer travel as the login session's distributed notifications, named
/// for this process's isolation (`CommandLineControlChannel`), so an isolated copy's command
/// line reaches only that copy.
enum CommandLineControlCommand {
    /// How long the running app has to answer.
    static let timeout: TimeInterval = 10

    /// Runs the command in `arguments` when they hold one and returns the exit status; nil when
    /// they hold none, and the app launches as usual.
    @MainActor
    static func run(arguments: [String]) -> Int32? {
        guard let parsed = CommandLineControlRequest.parse(arguments) else { return nil }
        let request: CommandLineControlRequest
        switch parsed {
        case let .success(value): request = value
        case let .failure(error):
            write(error.localizedDescription + "\n\n" + usage, to: FileHandle.standardError)
            return 64 // EX_USAGE
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppStorageLocation.realBundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else {
            write("Open Wallpaper Engine isn't running. Start it, then run the command again.", to: FileHandle.standardError)
            return 69 // EX_UNAVAILABLE
        }
        let channel = CommandLineControlChannel.current
        guard let reply = channel.send(request, timeout: timeout) else {
            write("Open Wallpaper Engine didn't answer.", to: FileHandle.standardError)
            return 69
        }
        if !reply.output.isEmpty {
            write(reply.output, to: reply.succeeded ? FileHandle.standardOutput : FileHandle.standardError)
        }
        return reply.succeeded ? 0 : 1
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }

    static let usage = """
    Usage: Open Wallpaper Engine --control <command> [options]
    Sends a command to the running Open Wallpaper Engine, like Wallpaper Engine's -control.
    WE's spellings work too: -control openWallpaper -file <path> -playInWindow <name>.

      pause | stop | play | mute | unmute
      open-wallpaper --file <project.json or folder> [--monitor <n> | --location <display>]
                     [--preset <name>] [--play-in-window <name> [--width <px>] [--height <px>]
                     [--x <px>] [--y <px>] [--borderless] [--activate]]
      next-wallpaper [--monitor <n> | --location <display>]
      close-wallpaper [--monitor <n> | --location <display or window name>]
      open-playlist --playlist <name> [--monitor <n> | --location <display>]
      open-profile --profile <name>
      apply-properties --properties '<JSON>' [--monitor <n> | --location <display or window name>]
      hide-icons | show-icons
      get-wallpaper [--monitor <n> | --location <display or window name>]
    """
}

/// The answer to a `CommandLineControlRequest`.
struct CommandLineControlReply: Codable, Equatable {
    var succeeded: Bool
    /// What the command prints: `getWallpaper`'s path, or why the command failed.
    var output: String = ""
}

/// The distributed notifications a control command and its answer travel as, named for the
/// app's isolation as the editor's messages are (`AppProcessChannel`).
struct CommandLineControlChannel {
    let prefix: String

    static var current: CommandLineControlChannel {
        CommandLineControlChannel(prefix: AppProcessChannel.current.prefix)
    }

    var requestName: Notification.Name { Notification.Name("\(prefix).cli.control") }
    var replyName: Notification.Name { Notification.Name("\(prefix).cli.reply") }

    static let requestKey = "request"
    static let replyKey = "reply"
    static let idKey = "id"

    /// Posts `request` and waits up to `timeout` for its answer, running the run loop meanwhile.
    @MainActor
    func send(_ request: CommandLineControlRequest, timeout: TimeInterval) -> CommandLineControlReply? {
        let center = DistributedNotificationCenter.default()
        let id = UUID().uuidString
        let box = ReplyBox()
        let token = center.addObserver(forName: replyName, object: nil, queue: .main) { notification in
            guard let info = notification.userInfo as? [String: String], info[Self.idKey] == id,
                  let data = info[Self.replyKey]?.data(using: .utf8) else { return }
            do {
                box.reply = try JSONDecoder().decode(CommandLineControlReply.self, from: data)
            } catch {
                box.reply = CommandLineControlReply(succeeded: false, output: "The app's answer couldn't be read: \(error)")
            }
        }
        defer { center.removeObserver(token) }
        guard let data = try? JSONEncoder().encode(request), let json = String(data: data, encoding: .utf8) else { // A request always encodes.
            return CommandLineControlReply(succeeded: false, output: "The command couldn't be encoded.")
        }
        center.postNotificationName(requestName, object: nil, userInfo: [Self.idKey: id, Self.requestKey: json],
                                    deliverImmediately: true)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while box.reply == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.1)))
        }
        return box.reply
    }

    /// The answer, set by the observer: it runs on the main queue, in the run loop `send` turns
    /// on the main thread, so the two never touch it at once.
    private final class ReplyBox: @unchecked Sendable {
        var reply: CommandLineControlReply?
    }
}
