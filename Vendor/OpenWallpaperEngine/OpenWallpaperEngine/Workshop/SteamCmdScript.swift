import Foundation

/// Commands for steamcmd's console, written to its stdin instead of passed as `+command`
/// arguments, so the account name, password and Steam Guard code never appear in `ps` output.
///
/// steamcmd's console splits a line at `;` and whitespace unless the argument is quoted, and has no
/// escape for a `"` inside quotes, so every argument is quoted and one containing `"` or a line
/// break is rejected.
struct SteamCmdScript {
    enum Failure: LocalizedError {
        case unquotableArgument(command: String)

        var errorDescription: String? {
            switch self {
            case .unquotableArgument(let command):
                return String(localized: "steamcmd can't accept a double quote or line break in the \(command) command.",
                              comment: "Login error; steamcmd is a program name, %@ one of its commands")
            }
        }
    }

    private(set) var lines: [String] = []

    /// Fails the login instead of prompting for a password; the prompt would consume the next line.
    static func withoutPasswordPrompt() -> SteamCmdScript {
        var script = SteamCmdScript()
        script.lines.append("@NoPromptForPassword 1")
        return script
    }

    mutating func append(_ command: String, _ arguments: [String] = []) throws {
        var line = command
        for argument in arguments {
            guard !argument.contains("\""), !argument.contains(where: \.isNewline) else {
                throw Failure.unquotableArgument(command: command)
            }
            line += " \"\(argument)\""
        }
        lines.append(line)
    }

    /// This script's commands, then `other`'s.
    func followed(by other: SteamCmdScript) -> SteamCmdScript {
        var script = self
        script.lines += other.lines
        return script
    }

    /// The script with a final `quit`, as steamcmd reads it from stdin.
    var standardInput: Data {
        Data((lines + ["quit"]).map { $0 + "\n" }.joined().utf8)
    }
}
