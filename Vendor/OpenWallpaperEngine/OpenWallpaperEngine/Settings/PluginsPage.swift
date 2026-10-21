//
//  PluginsPage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

/// Settings › Plugins: optional features. Screen Saver; the Chromium engine and Depth Map
/// Generation, which are downloaded on demand; and the MCP Server, installed from the app's own
/// copy. Animated library previews are built in (`ThumbnailAnimation`).
struct PluginsPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @ObservedObject private var chromium = AppDelegate.shared.chromiumEngine
    @ObservedObject private var broker = AppDelegate.shared.screenSaverBroker

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        SettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Screen Saver", isOn: $viewModel.settings.screenSaver)
                        .changedFromDefault(viewModel.isChanged(\.screenSaver))
                        .help("Installs a screen saver that draws the current wallpaper live while it runs; a video wallpaper plays its own file.")
                    Text("Installs a screen saver that draws your wallpaper live while it runs, so clocks, dates and audio-reactive parts move as they do on the desktop; a video wallpaper plays its own file. Choose Open Wallpaper Engine in Screen Saver settings to use it. Turning it off removes the screen saver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.settings.screenSaver {
                        Button("Open Screen Saver Settings…") {
                            ScreenSaverInstaller.current.openSettings()
                        }
                        brokerNote
                        if chromium.installedVersion == nil {
                            // The screen saver draws web pages and WebM videos through Chromium only
                            // (`ScreenSaverLiveWeb`).
                            Text("Web wallpapers and WebM videos move in the screen saver only with the Chromium engine. Without it, the screen saver shows their picture.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Install the Chromium Engine") { chromium.install() }
                                .disabled(chromium.isBusy || chromium.pin == nil)
                        }
                    }
                }
                ChromiumEngineSection(installer: chromium)
                    .settingsAnchor(SettingsAnchor.chromium)
                DepthMapPluginSection()
                    .settingsAnchor(SettingsAnchor.depthMaps)
                MCPServerPluginSection(plugin: AppDelegate.shared.mcpServerPlugin)
                    .settingsAnchor(SettingsAnchor.mcpServer)
            } header: {
                Label("Plugins", systemImage: "puzzlepiece.extension.fill")
            } footer: {
                Text("These settings take effect without saving.")
            }
            .settingsAnchor(SettingsAnchor.plugins)
        }
    }

    /// The broker's launch agent, when macOS doesn't let it run: the screen saver then can't
    /// start the app or, in its newer format, reach it (`ScreenSaverBrokerAgent`).
    @ViewBuilder private var brokerNote: some View {
        switch broker.state {
        case .requiresApproval:
            Label("Allow Open Wallpaper Engine in the background", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The screen saver needs Open Wallpaper Engine's background item to start the app while it isn't running and to show its frames. Turn it on in System Settings › General › Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items Settings…") { broker.openLoginItems() }
        case .failed(let reason):
            Label("The screen saver's background item couldn't be set up: \(reason)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .unavailable, .notRegistered, .enabled:
            EmptyView()
        }
    }
}
