import CryptoKit
import Foundation
import IOKit

/// The machine part of a user shortcut's stored value (`UserShortcutBinding.systemHash`). WE takes
/// the first six characters of a SHA-256 of a Windows machine id (wallpaper64.exe hashes a
/// registry value and compares six characters before it opens a shortcut, else logs "User
/// shortcut blocked."), so a config copied to another computer never opens what it names. Here
/// the id is the Mac's hardware UUID (`IOPlatformUUID`), which no other Mac shares.
enum UserShortcutSystemHash {
    /// This Mac's hash.
    static func current() -> String {
        hash(machineID: platformUUID() ?? "")
    }

    /// The first `UserShortcutBinding.systemHashLength` lower-case hex digits of SHA-256(`machineID`).
    static func hash(machineID: String) -> String {
        let digest = SHA256.hash(data: Data(machineID.utf8))
        let hex = Digest.hex(digest)
        return String(hex.prefix(UserShortcutBinding.systemHashLength))
    }

    /// `IOPlatformUUID` of the platform expert; nil (logged) when IOKit doesn't have it.
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            OWELog.error(.script, "User shortcuts: no IOPlatformExpertDevice, so no machine id")
            return nil
        }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let uuid = property?.takeRetainedValue() as? String else {
            OWELog.error(.script, "User shortcuts: IOPlatformExpertDevice has no IOPlatformUUID")
            return nil
        }
        return uuid
    }
}
