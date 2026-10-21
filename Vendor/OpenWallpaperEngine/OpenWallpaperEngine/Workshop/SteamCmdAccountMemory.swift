import Foundation

/// Where the account name of the last login is kept (the Keychain in the app); tests keep it in
/// memory.
struct SteamCmdAccountMemory {
    let load: () -> String?
    let save: (String) throws -> Void

    static var keychain: SteamCmdAccountMemory {
        let secret = SteamCredentials.steamCmdAccount()
        return SteamCmdAccountMemory(load: { secret.load() }, save: { try secret.save($0) })
    }
}
