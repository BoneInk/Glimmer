import Foundation

/// What each MCP client's configuration needs to start the installed `owe-mcp` over stdio, in the
/// client's own format and file (`docs/mcp.md` › Client setup cites each client's documentation).
/// Every snippet names the server `open-wallpaper-engine` and gives `owe-mcp`'s absolute path,
/// with no arguments: the installed copy finds its app by itself.
public enum MCPClientConfiguration: String, CaseIterable, Identifiable, Sendable {
    case claudeDesktop
    case claudeCode
    case vsCode
    case cursor
    case kiro
    case windsurf
    case zed
    case codex
    case geminiCLI
    case cline
    case continueDev
    case generic

    public static let serverName = "open-wallpaper-engine"

    public var id: String { rawValue }

    /// The client's own name, as it calls itself (not localized); nil for `generic`, which the
    /// app names in the user's language.
    public var clientName: String? {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .vsCode: return "VS Code / GitHub Copilot"
        case .cursor: return "Cursor"
        case .kiro: return "Kiro"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .codex: return "OpenAI Codex CLI"
        case .geminiCLI: return "Gemini CLI"
        case .cline: return "Cline"
        case .continueDev: return "Continue"
        case .generic: return nil
        }
    }

    /// Where the snippet goes, as the client's documentation names it.
    public var location: String {
        switch self {
        case .claudeDesktop: return "~/Library/Application Support/Claude/claude_desktop_config.json"
        case .claudeCode: return "Terminal"
        case .vsCode: return ".vscode/mcp.json, or MCP: Open User Configuration"
        case .cursor: return "~/.cursor/mcp.json, or .cursor/mcp.json in a project"
        case .kiro: return "~/.kiro/settings/mcp.json, or .kiro/settings/mcp.json in a workspace"
        case .windsurf: return "~/.codeium/windsurf/mcp_config.json (Devin Desktop: ~/.config/devin/mcp_config.json)"
        case .zed: return "Zed's settings.json"
        case .codex: return "~/.codex/config.toml"
        case .geminiCLI: return "~/.gemini/settings.json, or .gemini/settings.json in a project"
        case .cline: return "cline_mcp_settings.json (Cline › MCP Servers › Configure)"
        case .continueDev: return ".continue/mcpServers/open-wallpaper-engine.yaml"
        case .generic: return "your MCP client's stdio server settings"
        }
    }

    /// The snippet for `owe-mcp` at `executablePath`.
    public func snippet(executablePath path: String) -> String {
        let command = JSONValue.string(path)
        switch self {
        case .claudeDesktop, .cursor, .windsurf, .geminiCLI:
            return Self.json(["mcpServers": [Self.serverName: ["command": command]]])
        case .kiro:
            return Self.json(["mcpServers": [Self.serverName: ["command": command, "args": [], "disabled": false]]])
        case .cline:
            return Self.json(["mcpServers": [Self.serverName: ["command": command, "args": [], "disabled": false, "autoApprove": []]]])
        case .vsCode:
            return Self.json(["servers": [Self.serverName: ["type": "stdio", "command": command]]])
        case .zed:
            return Self.json(["context_servers": [Self.serverName: ["command": command, "args": [], "env": [:]]]])
        case .generic:
            return Self.json(["type": "stdio", "command": command, "args": []])
        case .claudeCode:
            return "claude mcp add \(Self.serverName) -- \(Self.shellQuoted(path))"
        case .codex:
            return "[mcp_servers.\(Self.serverName)]\ncommand = \(Self.tomlString(path))\n"
        case .continueDev:
            // JSON strings are YAML strings: the path needs no other quoting.
            return """
            name: Open Wallpaper Engine
            version: 0.0.1
            schema: v1
            mcpServers:
              - name: \(Self.serverName)
                type: stdio
                command: \(Self.jsonString(path))

            """
        }
    }

    // MARK: - Encoding

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // A value of strings, booleans and arrays always encodes.
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // A string always encodes.
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// One shell word: single-quoted, a single quote inside closed, escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
