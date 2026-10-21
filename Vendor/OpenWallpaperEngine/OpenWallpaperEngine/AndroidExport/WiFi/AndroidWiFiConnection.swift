import Foundation
import Network

/// One phone's connection to `AndroidWiFiServer`: reads a request's headers (within the time and
/// size limits), sends the server's response, a file in chunks as the connection takes them with
/// its progress reported, then closes. Runs on the server's queue, which owns its state.
final class AndroidWiFiConnection: @unchecked Sendable {
    let device: UInt32
    private let connection: NWConnection
    private weak var server: AndroidWiFiServer?
    private var received = Data()
    private var answered = false
    private var file: FileHandle?
    private var lastReport = Date.distantPast

    init(connection: NWConnection, device: UInt32, server: AndroidWiFiServer) {
        self.connection = connection
        self.device = device
        self.server = server
    }

    private var deviceName: String { AndroidLANAddress.dotted(device) }

    func start() {
        guard let server else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: server.queue)
        server.queue.asyncAfter(deadline: .now() + server.limits.headerTimeout) { [weak self] in
            guard let self, !self.answered else { return }
            self.cancel()
        }
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private func finish() {
        closeFile()
        server?.remove(self)
    }

    private func closeFile() {
        do {
            try file?.close()
        } catch {
            OWELog.error(.app, "Send over Wi-Fi: closing a package failed: \(error)")
        }
        file = nil
    }

    // MARK: Request

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.answered else { return }
            if let data { self.received.append(data) }
            switch AndroidWiFiHTTP.parse(self.received) {
            case .request(let request):
                self.answered = true
                guard let server = self.server else { return self.cancel() }
                self.send(server.respond(to: request, from: self.device))
            case .invalid:
                self.answered = true
                self.send(.text(400))
            case .incomplete:
                if isComplete || error != nil { self.cancel() } else { self.receive() }
            }
        }
    }

    // MARK: Response

    private func send(_ response: AndroidWiFiHTTP.Response) {
        switch response.body {
        case .none:
            sendFinal(response.head)
        case .data(let body):
            sendFinal(response.head + body)
        case .picture(let url):
            do {
                sendFinal(response.head + (try Data(contentsOf: url, options: .mappedIfSafe)))
            } catch {
                OWELog.error(.app, "Send over Wi-Fi: the preview \(url.lastPathComponent) can't be read: \(error)")
                sendFinal(AndroidWiFiHTTP.Response.text(404).head)
            }
        case .file(let url, let index, let range):
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: UInt64(range.lowerBound))
                file = handle
            } catch {
                OWELog.error(.app, "Send over Wi-Fi: \(url.lastPathComponent) can't be read: \(error)")
                sendFinal(AndroidWiFiHTTP.Response.text(404).head)
                return
            }
            let size = AndroidWiFiRouter.size(of: url) ?? range.upperBound + 1
            OWELog.info(.app, "Send over Wi-Fi: \(deviceName) downloads #\(index) (\(range.lowerBound)-\(range.upperBound) of \(size))")
            connection.send(content: response.head, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { return self.interrupted(index: index, at: range.lowerBound, size: size, error) }
                self.sendChunk(index: index, from: range.lowerBound, through: range.upperBound, size: size)
            })
        }
    }

    private func sendFinal(_ data: Data) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    /// Sends the file from `position` through `last`, one chunk at a time.
    private func sendChunk(index: Int, from position: Int64, through last: Int64, size: Int64) {
        guard let file, let server else { return cancel() }
        let count = Int(min(Int64(server.limits.chunk), last - position + 1))
        let chunk: Data
        do {
            chunk = try file.read(upToCount: count) ?? Data()
        } catch {
            return interrupted(index: index, at: position, size: size, error)
        }
        guard chunk.count == count else {
            return interrupted(index: index, at: position, size: size, CocoaError(.fileReadCorruptFile))
        }
        let next = position + Int64(count)
        let isLast = next > last
        connection.send(content: chunk, contentContext: isLast ? .finalMessage : .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { return self.interrupted(index: index, at: position, size: size, error) }
            if isLast {
                self.closeFile()
                // A download is complete once the file's last byte went out.
                let completed = last == size - 1
                self.server?.report(.init(index: index, device: self.deviceName, position: next, size: size,
                                          state: completed ? .completed : .running))
                if completed { OWELog.info(.app, "Send over Wi-Fi: \(self.deviceName) finished #\(index)") }
                self.cancel()
            } else {
                let time = Date()
                if time.timeIntervalSince(self.lastReport) >= 0.25 {
                    self.lastReport = time
                    self.server?.report(.init(index: index, device: self.deviceName, position: next, size: size, state: .running))
                }
                self.sendChunk(index: index, from: next, through: last, size: size)
            }
        })
    }

    private func interrupted(index: Int, at position: Int64, size: Int64, _ error: Error) {
        OWELog.info(.app, "Send over Wi-Fi: \(deviceName)'s download of #\(index) stopped at \(position): \(error)")
        server?.report(.init(index: index, device: deviceName, position: position, size: size, state: .interrupted))
        cancel()
    }
}
