import AppKit
import OWEControlProtocol
import SwiftUI

/// Settings › Plugins › MCP Server: install or remove the plugin (`MCPServerPlugin`), and what an
/// MCP client needs to start it.
struct MCPServerPluginSection: View {
    @ObservedObject var plugin: MCPServerPlugin
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MCP Server")
                Spacer()
                if plugin.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
            Text("Lets MCP clients, such as AI assistants and automation tools, control Open Wallpaper Engine on this Mac with the Model Context Protocol: list and set wallpapers, pause and resume, change the volume and user properties, play playlists, import wallpapers and open the editors.",
                 comment: "Settings › Plugins › MCP Server: what the plugin does")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Installing puts the owe-mcp command in Application Support and lets MCP clients connect while the app runs, through a local connection only your user account can open. Removing it deletes the command and stops accepting them.",
                 comment: "Settings › Plugins › MCP Server: what installing and removing do")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if plugin.isInstalled {
                setup
            }
            buttons
            if let message = failure ?? plugin.serverError.map(Self.connectionFailure) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paste the configuration into your MCP client’s settings, or add it from Terminal:",
                 comment: "Settings › Plugins › MCP Server: how to add the server to an MCP client")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: plugin.addCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if plugin.isInstalled {
                copyMenu
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([plugin.layout.executable])
                }
                Button("Remove", role: .destructive) { run(plugin.remove) }
                    .help(Text("Deletes the owe-mcp command, stops accepting MCP clients and closes their connections.",
                               comment: "Settings › Plugins › MCP Server: Remove button help"))
            } else {
                Button("Install") { run(plugin.install) }
                    .disabled(!plugin.canInstall)
                    .help(Text("Installs the owe-mcp command that ships with the app and starts accepting MCP clients.",
                               comment: "Settings › Plugins › MCP Server: Install button help"))
            }
            Spacer()
        }
    }

    /// Copy Configuration For › each client: its snippet, with the installed path.
    private var copyMenu: some View {
        Menu {
            ForEach(MCPClientConfiguration.allCases) { client in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plugin.configuration(for: client), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    if let name = client.clientName {
                        Text(verbatim: name)
                    } else {
                        Text("Generic stdio client", comment: "Settings › Plugins › MCP Server › Copy Configuration For: any other MCP client")
                    }
                }
                .help(Text(verbatim: client.location))
            }
        } label: {
            if copied {
                Text("Copied")
            } else {
                Text("Copy Configuration For", comment: "Settings › Plugins › MCP Server: menu of MCP clients; copies the chosen client's configuration")
            }
        }
        .fixedSize()
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch {
            OWELog.error(.app, "MCP Server plugin: \(error)")
            failure = error.localizedDescription
        }
    }

    private static func connectionFailure(_ reason: String) -> String {
        String(localized: "MCP clients can’t connect: \(reason)",
               comment: "Settings › Plugins › MCP Server: the control socket couldn't be opened; %@ is the reason")
    }
}
