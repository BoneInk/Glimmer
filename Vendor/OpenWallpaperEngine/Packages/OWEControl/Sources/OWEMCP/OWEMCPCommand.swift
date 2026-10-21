import Foundation
import OWEControlProtocol

/// `owe-mcp`, the Model Context Protocol server an MCP client starts: MCP over stdio, one
/// JSON-RPC message per line on stdin and stdout, diagnostics on stderr (`docs/mcp.md`).
public enum OWEMCPCommand {
    static let usage = """
    Usage: owe-mcp [--socket <path>] [--no-launch] [--launch-timeout <seconds>]

    The Model Context Protocol server of Open Wallpaper Engine. An MCP client starts it and talks
    to it over stdin and stdout. Tool calls go to the running app, whose MCP Server plugin must
    be installed (Settings › Plugins); the app is started when it isn't running.

      --socket <path>             the app's control socket (default: the isolated copy's named by
                                  OWE_ISOLATED_STATE, else the app's that installed this copy)
      --no-launch                 never start the app
      --launch-timeout <seconds>  how long to wait for a started app (default 30)
      --version                   print the version
    """

    struct Options: Equatable {
        var socketURL: URL?
        var launches = true
        var launchTimeout: TimeInterval = 30
    }

    enum ParseOutcome: Equatable {
        case run(Options)
        case exit(message: String, status: Int32)
    }

    static func parse(_ arguments: [String], version: String) -> ParseOutcome {
        var options = Options()
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--help", "-h": return .exit(message: usage, status: 0)
            case "--version": return .exit(message: version, status: 0)
            case "--no-launch": options.launches = false
            case "--socket":
                guard let path = remaining.popFirst() else { return .exit(message: "--socket needs a path\n\n" + usage, status: 64) }
                options.socketURL = URL(fileURLWithPath: path)
            case "--launch-timeout":
                guard let value = remaining.popFirst().flatMap(TimeInterval.init), value > 0 else {
                    return .exit(message: "--launch-timeout needs a number of seconds\n\n" + usage, status: 64)
                }
                options.launchTimeout = value
            default:
                return .exit(message: "Unknown option \(argument)\n\n" + usage, status: 64)
            }
        }
        return .run(options)
    }

    /// This executable, symbolic links resolved.
    public static var executableURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The app's control socket: `--socket`, else the isolated copy's that `OWE_ISOLATED_STATE`
    /// names, else the one beside the support folder an installed plugin sits in, else the app's.
    static func socketURL(option: URL?, executable: URL, environment: [String: String]) -> URL {
        if let option { return option }
        if let tag = environment[ControlSocketLocation.isolationEnvironmentKey].flatMap(ControlSocketLocation.sanitizedTag) {
            return ControlSocketLocation.socketURL(supportDirectory: ControlSocketLocation.supportDirectory(isolationTag: tag),
                                                   isolationTag: tag)
        }
        if let support = MCPPluginLayout.supportDirectory(ofInstalledExecutable: executable) {
            // An isolated copy's plugin: its manifest names the copy's tag.
            return ControlSocketLocation.socketURL(supportDirectory: support,
                                                   isolationTag: MCPPluginLayout.manifest(supportDirectory: support)?.isolationTag)
        }
        return ControlSocketLocation.socketURL(supportDirectory: ControlSocketLocation.supportDirectory(isolationTag: nil))
    }

    /// The app's version when `owe-mcp` is inside it or was installed by it, else "dev".
    static func version(launcher: OWEAppLauncher) -> String {
        guard let app = launcher.appURL, let bundle = Bundle(url: app), // No app found: a development build.
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "dev" }
        return version
    }

    /// Serves MCP on stdin and stdout until stdin closes; returns the exit status.
    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        let launcher = OWEAppLauncher.forCurrentProcess()
        let version = version(launcher: launcher)
        let options: Options
        switch parse(arguments, version: version) {
        case .exit(let message, let status):
            FileHandle(fileDescriptor: status == 0 ? STDOUT_FILENO : STDERR_FILENO).write(Data((message + "\n").utf8))
            return status
        case .run(let parsed):
            options = parsed
        }
        let socket = socketURL(option: options.socketURL, executable: executableURL,
                               environment: ProcessInfo.processInfo.environment)
        let channel = SocketControlChannel(socketURL: socket,
                                           launcher: options.launches ? launcher : nil,
                                           launchTimeout: options.launchTimeout)
        let server = MCPServer(channel: channel, version: version)
        let output = FileHandle.standardOutput
        // A long call's progress goes out while its answer is awaited; each line is one write.
        server.sendNotification = { line in try? output.write(contentsOf: line + Data([0x0A])) }
        // A client that goes away mid-answer ends the loop with an error, not a signal.
        signal(SIGPIPE, SIG_IGN)
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let response = await server.handle(line: Data(line.utf8)) else { continue }
                try output.write(contentsOf: response + Data([0x0A]))
            }
        } catch {
            FileHandle.standardError.write(Data("owe-mcp: \(error)\n".utf8))
            return 1
        }
        return 0
    }
}
