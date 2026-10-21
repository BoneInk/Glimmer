import Foundation

/// One command of Wallpaper Engine's command line (`wallpaper64.exe -control <verb> …`,
/// help.wallpaperengine.io/en/functionality/cli.html), as the app's executable takes it:
/// `Open Wallpaper Engine --control <verb> [options]` sends it to the running app.
///
/// Both spellings work: WE's (`-control openWallpaper -file … -playInWindow …`) and this app's
/// launch-argument style (`--control open-wallpaper --file … --play-in-window …`). Verbs and option
/// names ignore case, dashes and underscores.
struct CommandLineControlRequest: Codable, Equatable {
    /// WE's verbs, by WE's names.
    enum Verb: String, Codable, CaseIterable {
        case pause, stop, play, mute, unmute
        case openWallpaper, nextWallpaper, closeWallpaper, openPlaylist, openProfile
        case applyProperties, hideIcons, showIcons, getWallpaper

        /// `open-wallpaper`, `openWallpaper`, `OPENWALLPAPER` and `open_wallpaper` alike.
        init?(spelling: String) {
            let wanted = CommandLineControlRequest.normalized(spelling)
            guard let verb = Verb.allCases.first(where: { CommandLineControlRequest.normalized($0.rawValue) == wanted }) else {
                return nil
            }
            self = verb
        }

        /// The options it reads, normalized.
        var options: Set<String> {
            switch self {
            case .pause, .stop, .play, .mute, .unmute, .hideIcons, .showIcons: return []
            case .openWallpaper:
                return ["file", "location", "monitor", "preset", "playinwindow", "width", "height", "x", "y"]
            case .nextWallpaper, .closeWallpaper, .getWallpaper: return ["location", "monitor"]
            case .openPlaylist: return ["playlist", "location", "monitor"]
            case .openProfile: return ["profile"]
            case .applyProperties: return ["properties", "location", "monitor"]
            }
        }

        /// The switches it reads, which take no value.
        var flags: Set<String> {
            self == .openWallpaper ? ["borderless", "activate"] : []
        }

        /// The option it can't do without.
        var required: String? {
            switch self {
            case .openWallpaper: return "file"
            case .openPlaylist: return "playlist"
            case .openProfile: return "profile"
            case .applyProperties: return "properties"
            default: return nil
            }
        }
    }

    /// The arguments that start a control command.
    static let controlArguments: Set<String> = ["-control", "--control"]

    var verb: Verb
    /// Option values by normalized name (`playinwindow`, `file`…).
    var options: [String: String] = [:]
    /// Switches given (`borderless`, `activate`).
    var flags: Set<String> = []

    func option(_ name: String) -> String? { options[name] }

    func int(_ name: String) -> Int? { options[name].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// Lowercased, without dashes, underscores or spaces.
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { !"-_ ".contains($0) }
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case missingVerb
        case unknownVerb(String)
        case unknownOption(String, Verb)
        case missingValue(String)
        case missingOption(String, Verb)
        case notANumber(String)

        var errorDescription: String? {
            switch self {
            case .missingVerb:
                return "--control needs a command: \(Verb.allCases.map(\.rawValue).joined(separator: ", "))."
            case let .unknownVerb(verb):
                return "Unknown command \"\(verb)\". Commands: \(Verb.allCases.map(\.rawValue).joined(separator: ", "))."
            case let .unknownOption(option, verb):
                return "\(verb.rawValue) doesn't take \(option)."
            case let .missingValue(option):
                return "\(option) needs a value."
            case let .missingOption(option, verb):
                return "\(verb.rawValue) needs --\(option)."
            case let .notANumber(option):
                return "\(option) needs a whole number."
            }
        }
    }

    /// The command in `arguments` (the executable first), or nil when they hold none. Arguments
    /// before `-control` (an isolation tag, `-AppleLanguages`) are not the command's.
    static func parse(_ arguments: [String]) -> Result<CommandLineControlRequest, ParseError>? {
        guard let start = arguments.firstIndex(where: { controlArguments.contains($0) }) else { return nil }
        var remaining = arguments[(start + 1)...]
        guard let spelling = remaining.popFirst() else { return .failure(.missingVerb) }
        guard let verb = Verb(spelling: spelling) else { return .failure(.unknownVerb(spelling)) }
        var request = CommandLineControlRequest(verb: verb)
        while let argument = remaining.popFirst() {
            let name = normalized(argument)
            // This app's own launch arguments may follow (`-OWEIsolatedState <tag>`).
            if argument == AppStorageLocation.argumentKey {
                _ = remaining.popFirst()
                continue
            }
            if verb.flags.contains(name) {
                request.flags.insert(name)
            } else if verb.options.contains(name), argument.hasPrefix("-") {
                guard let value = remaining.popFirst() else { return .failure(.missingValue(argument)) }
                request.options[name] = name == "properties" ? unwrapRaw(value) : value
            } else {
                return .failure(.unknownOption(argument, verb))
            }
        }
        for name in ["monitor", "width", "height", "x", "y"] where request.options[name] != nil && request.int(name) == nil {
            return .failure(.notANumber(name))
        }
        if let required = verb.required, request.options[required] == nil {
            return .failure(.missingOption(required, verb))
        }
        return .success(request)
    }

    /// WE wraps `-properties`' JSON as `RAW~(` … `)~END` so the shell leaves it alone; plain
    /// JSON is taken too.
    static func unwrapRaw(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("RAW~("), trimmed.hasSuffix(")~END") else { return trimmed }
        return String(trimmed.dropFirst(5).dropLast(5))
    }
}
