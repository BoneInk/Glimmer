import Foundation

/// `.state.json`: which install is active and which one came before it.
struct VersionedInstallState: Codable, Equatable {
    var active: String?
    var previous: String?

    static let fileName = ".state.json"

    /// The state in `root`; empty when there is none yet (no install) or it can't be read or
    /// decoded (logged: an install whose state is lost looks uninstalled).
    static func read(in root: URL) -> VersionedInstallState {
        let url = root.appending(path: fileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return VersionedInstallState()
        } catch {
            OWELog.error(.app, "Can't read \(url.path): \(error)")
            return VersionedInstallState()
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            OWELog.error(.app, "\(url.path) is corrupt, read as no install: \(error)")
            return VersionedInstallState()
        }
    }

    func write(in root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appending(path: Self.fileName), options: .atomic)
    }
}
