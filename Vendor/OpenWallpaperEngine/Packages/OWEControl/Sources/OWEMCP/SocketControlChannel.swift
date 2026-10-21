import Foundation
import OWEControlProtocol

/// Why the app couldn't be reached, worded for the person or model using the tools.
public struct AppConnectionError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    static let controlOff = AppConnectionError(message: """
        Open Wallpaper Engine is running but doesn't accept MCP clients: its MCP Server plugin isn't installed. \
        Install it in the app's Settings › Plugins, then try again.
        """)
}

/// The control channel to the running app through its socket (`ControlSocketLocation`). The first
/// call connects; when no app answers, it starts the app (`AppLaunching`) and waits for its socket
/// up to `launchTimeout`. A connection the app closed is opened again on the next call.
public final class SocketControlChannel: ControlChannel {
    private let client: ControlSocketClient
    private let launcher: AppLaunching?
    private let launchTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let responseTimeout: TimeInterval
    /// How long a long-running call (an export, a recording) may take to answer.
    private let longCallTimeout: TimeInterval
    private var nextID = 1

    public init(socketURL: URL, launcher: AppLaunching?, launchTimeout: TimeInterval = 30,
                responseTimeout: TimeInterval = 120, longCallTimeout: TimeInterval = 900, pollInterval: TimeInterval = 0.25) {
        client = ControlSocketClient(url: socketURL, timeout: responseTimeout)
        self.responseTimeout = responseTimeout
        self.longCallTimeout = longCallTimeout
        self.launcher = launcher
        self.launchTimeout = launchTimeout
        self.pollInterval = pollInterval
    }

    public func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        try await call(method, params: params, longRunning: false)
    }

    public func call(_ method: String, params: [String: JSONValue], longRunning: Bool) async throws -> JSONValue {
        try await connect()
        client.timeout = longRunning ? longCallTimeout : responseTimeout
        let request = ControlRequest(id: nextID, method: method, params: params)
        nextID += 1
        let response: ControlResponse
        do {
            response = try client.send(request)
        } catch ControlConnectionError.closed {
            throw AppConnectionError(message: "Open Wallpaper Engine closed the connection (it quit, or its MCP Server plugin was removed). Try again.")
        } catch ControlConnectionError.timedOut {
            throw AppConnectionError(message: "Open Wallpaper Engine didn't answer in time.")
        }
        if let error = response.error { throw error }
        return response.result ?? .null
    }

    private func connect() async throws {
        guard !client.isConnected else { return }
        if (try? client.connect()) != nil { return } // Not reachable yet is handled below.
        guard let launcher else {
            throw AppConnectionError(message: "Open Wallpaper Engine isn't reachable at \(client.url.path(percentEncoded: false)). Start it and install its MCP Server plugin (Settings › Plugins).")
        }
        let wasRunning = launcher.isRunning()
        if !wasRunning {
            do {
                try launcher.launch()
            } catch {
                throw AppConnectionError(message: "Open Wallpaper Engine couldn't be started: \(error)")
            }
        }
        // A running app may still be starting up; a launched one needs a moment to open its socket.
        let deadline = Date().addingTimeInterval(wasRunning ? min(3, launchTimeout) : launchTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if (try? client.connect()) != nil { return } // Keep waiting until the deadline.
        }
        if wasRunning || launcher.isRunning() { throw AppConnectionError.controlOff }
        throw AppConnectionError(message: "Open Wallpaper Engine didn't start within \(Int(launchTimeout)) seconds.")
    }
}
