// swift-tools-version:5.9
// Control of Open Wallpaper Engine by other processes (docs/mcp.md), kept out of the app target:
// - OWEControlProtocol: the control channel, Foundation only. Its wire format (newline-delimited
//   JSON requests and responses with a version) and its Unix domain socket, owner-only, which the
//   app serves (MCP/) while the MCP Server plugin is installed (Settings › Plugins); the plugin's
//   layout (`MCPPluginLayout`).
// - OWEMCP: the Model Context Protocol server the `owe-mcp` executable runs over stdio: JSON-RPC,
//   the tools and their schemas, each tool call one request on the control channel. It never
//   touches the app's state itself.
import PackageDescription

let package = Package(
    name: "OWEControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OWEControlProtocol", targets: ["OWEControlProtocol"]),
        .library(name: "OWEMCP", targets: ["OWEMCP"]),
    ],
    targets: [
        .target(name: "OWEControlProtocol"),
        .target(name: "OWEMCP", dependencies: ["OWEControlProtocol"]),
        .testTarget(name: "OWEControlProtocolTests", dependencies: ["OWEControlProtocol"]),
        .testTarget(name: "OWEMCPTests", dependencies: ["OWEMCP"]),
    ]
)
