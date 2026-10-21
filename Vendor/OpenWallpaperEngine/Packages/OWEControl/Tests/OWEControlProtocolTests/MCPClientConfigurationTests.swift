import XCTest
@testable import OWEControlProtocol

/// Each client's snippet parses in its own format and starts the installed `owe-mcp` by its
/// absolute path, spaces and quotes included.
final class MCPClientConfigurationTests: XCTestCase {
    private let paths = [
        "/Users/someone/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp",
        #"/Users/o'brien "x"/Library/Application Support/Open Wallpaper Engine (isolated a\b)/Plugins/MCP/owe-mcp"#,
    ]

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func server(_ text: String, under key: String) throws -> [String: Any] {
        let servers = try XCTUnwrap(try json(text)[key] as? [String: Any], key)
        XCTAssertEqual(Array(servers.keys), ["open-wallpaper-engine"])
        return try XCTUnwrap(servers["open-wallpaper-engine"] as? [String: Any])
    }

    func testJSONClients() throws {
        for path in paths {
            for client in [MCPClientConfiguration.claudeDesktop, .cursor, .windsurf, .geminiCLI, .kiro, .cline] {
                let entry = try server(client.snippet(executablePath: path), under: "mcpServers")
                XCTAssertEqual(entry["command"] as? String, path, "\(client)")
                XCTAssertEqual((entry["args"] as? [String]) ?? [], [], "\(client)")
            }
            XCTAssertEqual(try server(MCPClientConfiguration.cline.snippet(executablePath: path), under: "mcpServers")["disabled"] as? Bool, false)
            let vsCode = try server(MCPClientConfiguration.vsCode.snippet(executablePath: path), under: "servers")
            XCTAssertEqual(vsCode["type"] as? String, "stdio")
            XCTAssertEqual(vsCode["command"] as? String, path)
            let zed = try server(MCPClientConfiguration.zed.snippet(executablePath: path), under: "context_servers")
            XCTAssertEqual(zed["command"] as? String, path)
            XCTAssertEqual(zed["args"] as? [String], [])
            let generic = try json(MCPClientConfiguration.generic.snippet(executablePath: path))
            XCTAssertEqual(generic["command"] as? String, path)
            XCTAssertEqual(generic["type"] as? String, "stdio")
        }
    }

    func testClaudeCodeCommandIsOneShellWord() throws {
        for path in paths {
            let line = MCPClientConfiguration.claudeCode.snippet(executablePath: path)
            XCTAssertTrue(line.hasPrefix("claude mcp add open-wallpaper-engine -- '"))
            // What the shell passes: run it through /bin/sh's own word splitting.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let quoted = String(line.dropFirst("claude mcp add open-wallpaper-engine -- ".count))
            process.arguments = ["-c", "printf %s \(quoted)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
        }
    }

    func testCodexTOML() throws {
        for path in paths {
            let toml = MCPClientConfiguration.codex.snippet(executablePath: path)
            let lines = toml.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, "[mcp_servers.open-wallpaper-engine]")
            let command = try XCTUnwrap(lines.first { $0.hasPrefix("command = ") })
            XCTAssertEqual(try Self.tomlBasicString(String(command.dropFirst("command = ".count))), path)
        }
    }

    func testContinueYAML() throws {
        for path in paths {
            let yaml = MCPClientConfiguration.continueDev.snippet(executablePath: path)
            for field in ["name: Open Wallpaper Engine", "version: 0.0.1", "schema: v1", "mcpServers:", "  - name: open-wallpaper-engine", "    type: stdio"] {
                XCTAssertTrue(yaml.contains(field + "\n"), field)
            }
            let command = try XCTUnwrap(yaml.split(separator: "\n").first { $0.hasPrefix("    command: ") })
            // A double-quoted YAML scalar with JSON escapes.
            let scalar = Data(command.dropFirst("    command: ".count).utf8)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: scalar, options: .fragmentsAllowed) as? String, path)
        }
    }

    func testEveryClientIsCoveredOnce() {
        XCTAssertEqual(MCPClientConfiguration.allCases.count, 12)
        XCTAssertEqual(MCPClientConfiguration.allCases.filter { $0.clientName == nil }, [.generic])
        XCTAssertTrue(MCPClientConfiguration.allCases.allSatisfy { !$0.location.isEmpty })
    }

    /// A TOML basic string's value (the escapes `tomlString` writes).
    private static func tomlBasicString(_ literal: String) throws -> String {
        XCTAssertTrue(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        var out = ""
        var iterator = literal.dropFirst().dropLast().makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { out.append(character); continue }
            switch iterator.next() {
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: throw CocoaError(.coderReadCorrupt)
            }
        }
        return out
    }
}
