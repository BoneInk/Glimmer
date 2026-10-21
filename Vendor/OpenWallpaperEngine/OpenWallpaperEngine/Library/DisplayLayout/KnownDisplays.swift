import Foundation

/// The displays that have been connected before, by screen id. A display connected for the first
/// time gets wallpapers turned on; one seen before keeps what the user chose, so a display turned
/// off stays off when it wakes, changes resolution or moves in the arrangement.
struct KnownDisplays: Equatable {
    private(set) var screenIds: Set<String>

    init(_ screenIds: Set<String> = []) {
        self.screenIds = screenIds
    }

    /// Remembers `connected` and returns the displays among them never seen before.
    mutating func recordConnected(_ connected: Set<String>) -> Set<String> {
        let new = connected.subtracting(screenIds)
        screenIds.formUnion(new)
        return new
    }
}

extension KnownDisplays {
    private static let defaultsKey = "KnownDisplays"

    /// The saved set in `defaults` (`UserDefaults.app`, isolated per `AppStorageLocation`); nil
    /// before it was ever saved.
    static func load(from defaults: UserDefaults) -> KnownDisplays? {
        guard let object = defaults.object(forKey: defaultsKey) else { return nil }
        guard let ids = object as? [String] else {
            OWELog.error(.library, "The known displays can't be read (\(type(of: object))); starting a new list")
            return nil
        }
        return KnownDisplays(Set(ids))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(screenIds.sorted(), forKey: Self.defaultsKey)
    }
}
