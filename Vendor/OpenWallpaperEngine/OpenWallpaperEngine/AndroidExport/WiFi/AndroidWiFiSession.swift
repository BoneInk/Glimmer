import AppKit
import Foundation

/// One "Send over Wi-Fi" of some packages (`update(files:)` changes them while it serves): a
/// random token, the server on the chosen local-network address, its `.local` name
/// (`AndroidWiFiLocalName`), and each file's downloads as the server reports them. It ends when it
/// expires (15 minutes after the last page or download request), when `stop()` is called (the
/// window closed), or when the app quits; the token dies with it. Changing the address restarts
/// the server with the same token and expiry.
@MainActor
final class AndroidWiFiSession: ObservableObject {
    nonisolated static let lifetime: TimeInterval = 15 * 60

    enum State: Equatable {
        case starting
        case serving
        /// No Wi-Fi or local-network address.
        case noNetwork
        case failed(String)
        case stopped(AndroidWiFiServer.StopReason)
    }

    /// One file's downloads.
    struct Progress: Equatable {
        /// How far the furthest download got, 0…size.
        var position: Int64 = 0
        var isDownloading = false
        /// The devices that downloaded the whole file.
        var completedBy: [String] = []
    }

    @Published private(set) var files: [AndroidWiFiFile]
    /// A new one each time the session starts.
    private(set) var token = ""
    @Published private(set) var expiry: Date
    @Published private(set) var addresses: [AndroidLANAddress] = []
    @Published private(set) var address: AndroidLANAddress?
    @Published private(set) var port: UInt16?
    /// The share's multicast-DNS name (`owe-fileshare.local`) while it's advertised.
    @Published private(set) var hostName: String?
    @Published private(set) var state = State.starting
    @Published private(set) var progress: [Int: Progress] = [:]
    /// The devices that asked for a file.
    @Published private(set) var devices: [String] = []
    /// Why "Save to Folder…" couldn't copy a file.
    @Published private(set) var saveError: String?

    private let lifetime: TimeInterval
    private let limits: AndroidWiFiServer.Limits
    private let findAddresses: () -> [AndroidLANAddress]
    private let localName: AndroidWiFiLocalName
    private var server: AndroidWiFiServer?
    private var generation = 0

    /// `addresses` lists the Mac's local-network addresses (tests pass loopback); `localName`
    /// advertises the share's name (DNS-SD by default).
    init(files: [AndroidWiFiFile], lifetime: TimeInterval = AndroidWiFiSession.lifetime,
         limits: AndroidWiFiServer.Limits = .init(),
         addresses: @escaping () -> [AndroidLANAddress] = AndroidLANAddress.current,
         localName: AndroidWiFiLocalName? = nil) {
        self.files = files
        self.lifetime = lifetime
        self.limits = limits
        findAddresses = addresses
        self.localName = localName ?? AndroidWiFiLocalName()
        expiry = Date().addingTimeInterval(lifetime)
    }

    convenience init(batch: AndroidExportBatch) {
        self.init(files: AndroidWiFiFile.files(of: batch))
    }

    /// The page's address: `http://owe-fileshare.local:<port>/<token>/` while the name is
    /// advertised, else `ipURL`.
    var url: URL? { localURL ?? ipURL }

    /// `http://<hostName>:<port>/<token>/`.
    var localURL: URL? {
        guard let hostName, let port, state == .serving else { return nil }
        return Self.link(host: hostName, port: port, token: token)
    }

    /// `http://<IPv4>:<port>/<token>/`, for devices that can't resolve `.local` names.
    var ipURL: URL? {
        guard let address, let port, state == .serving else { return nil }
        return Self.link(host: address.host, port: port, token: token)
    }

    /// The QR code's address: `url`, or `ipURL` when the user asks for the IP address.
    func qrURL(usesIPAddress: Bool) -> URL? { usesIPAddress ? ipURL : url }

    nonisolated static func link(host: String, port: UInt16, token: String) -> URL? {
        URL(string: "http://\(host):\(port)/\(token)/")
    }

    var isActive: Bool { state == .starting || state == .serving }

    /// Finds the addresses and starts serving on the primary one (or `preferred`), with a new
    /// token. The 15 minutes start now.
    func start(preferred: String? = nil) async {
        stop()
        progress = [:]
        devices = []
        do {
            token = try AndroidWiFiRouter.makeToken()
        } catch {
            OWELog.error(.app, "Send over Wi-Fi: no random token: \(error)")
            state = .failed(error.localizedDescription)
            return
        }
        expiry = Date().addingTimeInterval(lifetime)
        addresses = findAddresses()
        guard let chosen = addresses.first(where: { $0.host == preferred }) ?? addresses.first else {
            state = .noNetwork
            return
        }
        await serve(on: chosen)
    }

    /// Serves on another of the Mac's addresses; the token and expiry stay.
    func choose(_ address: AndroidLANAddress) async {
        guard address != self.address, isActive else { return }
        await serve(on: address)
    }

    func stop() {
        generation += 1
        server?.stop(.closed)
        server = nil
        withdrawName()
        if isActive { state = .stopped(.closed) }
    }

    private func serve(on address: AndroidLANAddress) async {
        generation += 1
        let current = generation
        server?.stop(.closed)
        withdrawName()
        state = .starting
        self.address = address
        port = nil
        let router = AndroidWiFiRouter(token: token, files: files, expiry: expiry)
        let server = AndroidWiFiServer(router: router, address: address, lifetime: lifetime, limits: limits) { [weak self] event in
            Task { @MainActor in self?.handle(event, generation: current) }
        }
        self.server = server
        do {
            let port = try await server.start()
            guard current == generation else { return }
            self.port = port
            await advertise(address: address, port: port, generation: current)
            guard current == generation else { return }
            state = .serving
            OWELog.info(.app, "Send over Wi-Fi: serving \(files.count) packages on \(address.host):\(port) (\(address.interface)) until \(expiry)")
        } catch {
            guard current == generation else { return }
            OWELog.error(.app, "Send over Wi-Fi: listening on \(address.host) failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: AndroidWiFiServer.Event, generation current: Int) {
        guard current == generation else { return }
        switch event {
        case .expiry(let date):
            expiry = date
        case .stopped(let reason):
            server = nil
            withdrawName()
            state = .stopped(reason)
        case .transfer(let transfer):
            if !devices.contains(transfer.device) { devices.append(transfer.device) }
            var entry = progress[transfer.index] ?? Progress()
            entry.position = max(entry.position, min(transfer.position, transfer.size))
            entry.isDownloading = transfer.state == .running
            if transfer.state == .completed, !entry.completedBy.contains(transfer.device) {
                entry.completedBy.append(transfer.device)
            }
            progress[transfer.index] = entry
        }
    }

    /// Serves `files` from now on (the page reloads its list); the token and expiry stay.
    func update(files: [AndroidWiFiFile]) {
        guard files != self.files else { return }
        self.files = files
        server?.update(files: files)
    }

    // MARK: Name

    /// Advertises the share's `.local` name; when another device takes it later, the next free
    /// name replaces it (the IP address meanwhile).
    private func advertise(address: AndroidLANAddress, port: UInt16, generation current: Int) async {
        let name = await localName.advertise(address: address, port: port) { [weak self] in
            guard let self, current == self.generation else { return }
            self.hostName = nil
            Task { await self.advertise(address: address, port: port, generation: current) }
        }
        guard current == generation else { return }
        hostName = name
        // No answer yet (macOS may be asking whether the app may use the local network): try
        // again later, and switch to the name once it's granted.
        if name == nil, localName.timedOut {
            Task { [weak self] in
                try? await Task.sleep(for: self?.localName.retryDelay ?? .seconds(5))
                guard let self, current == self.generation, self.hostName == nil else { return }
                await self.advertise(address: address, port: port, generation: current)
            }
        }
    }

    private func withdrawName() {
        localName.withdraw()
        hostName = nil
    }

    // MARK: Save to folder

    /// Copies the batch's files into a folder the user chooses (when there's no network to send
    /// them over), then shows them in the Finder.
    func saveToFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let names = AndroidExportNaming.uniqueNames(files.map(\.title), taken: AndroidExportNaming.existingNames(in: folder))
        var copied: [URL] = []
        saveError = nil
        for (file, name) in zip(files, names) {
            let target = folder.appending(path: name, directoryHint: .notDirectory)
            do {
                try FileManager.default.copyItem(at: file.url, to: target)
                copied.append(target)
            } catch {
                OWELog.error(.app, "Send over Wi-Fi: copying \(file.url.lastPathComponent) to \(folder.path(percentEncoded: false)) failed: \(error)")
                saveError = error.localizedDescription
            }
        }
        if !copied.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copied) }
    }
}
