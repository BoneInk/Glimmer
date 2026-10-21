import Foundation

/// The command a user runs in Terminal to log in to SteamCMD themselves, so the password and
/// Steam Guard code are typed into SteamCMD directly. The app then reuses SteamCMD's saved login.
enum SteamCmdTerminalLogin {
    /// Valve's SteamCMD documentation.
    static let documentationURL = URL(string: "https://developer.valvesoftware.com/wiki/SteamCMD")!

    /// `'<steamcmd>' +login '<account>' +quit`, quoted for zsh and bash.
    static func command(steamCmdPath: String, account: String) -> String {
        "\(shellQuoted(steamCmdPath)) +login \(shellQuoted(account)) +quit"
    }

    /// `value` in single quotes; a single quote inside becomes `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Writes an executable `.command` file that runs `command` in Terminal when opened. It holds
    /// only the steamcmd path and account name.
    static func writeCommandFile(_ command: String, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let file = directory.appending(path: "OWE Steam Login.command")
        try Data("#!/bin/zsh\n\(command)\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
