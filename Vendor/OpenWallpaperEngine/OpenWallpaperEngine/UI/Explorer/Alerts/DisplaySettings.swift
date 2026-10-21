//
//  DisplaySettingsView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct DisplaySettings: SubviewOfContentView {
    var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = AppDelegate.shared.wallpaperViewModel
    }

    /// Every display that shows a wallpaper, a split display's regions in its place.
    private var allDisplays: Set<String> {
        Set(wallpaperViewModel.layoutResolution.shownDisplays(NSScreen.screens.map(WallpaperViewModel.screenId(for:))))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Display Settings")
                .font(.largeTitle)

            Text("Click a display to select it. Hold Shift while clicking to select multiple desktops.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // WE's layouts, and its profiles of the whole layout.
            HStack(spacing: 12) {
                Picker("Layout", selection: Binding(
                    get: { wallpaperViewModel.displayLayout.layout },
                    set: { wallpaperViewModel.setLayout($0) }
                )) {
                    Text("Wallpaper per display").tag(DisplayLayoutMode.perDisplay)
                    Text("Stretch single wallpaper").tag(DisplayLayoutMode.stretch)
                    Text("Clone single wallpaper").tag(DisplayLayoutMode.clone)
                }
                .pickerStyle(.menu)
                .fixedSize()
                DisplayProfilesMenu(profiles: wallpaperViewModel.displayProfiles)
            }

            ScreenSaverLayoutPicker(layout: $wallpaperViewModel.screenSaverLayout)

            Text("Right-click a display to stretch or clone it with the selected displays, split it, choose the main clone display, flip a clone or mute a display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Toggle("All Desktops", isOn: Binding(
                get: {
                    let screenIds = allDisplays
                    return !screenIds.isEmpty && wallpaperViewModel.selectedScreenIds == screenIds
                },
                set: { selectAll in
                    let screenIds = allDisplays
                    wallpaperViewModel.selectedScreenIds = selectAll ? screenIds : [wallpaperViewModel.selectedScreenId]
                }
            ))
            .toggleStyle(.checkbox)

            // Monitor layout
            MonitorLayoutView(wallpaperViewModel: wallpaperViewModel)
                .frame(maxHeight: 200)

            // Selected screen info (a region of a split display shows its own size)
            let selectedScreen = DisplayLayoutResolution.screen(of: wallpaperViewModel.selectedScreenId)
            if let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == selectedScreen }) {
                let screenId = wallpaperViewModel.selectedScreenId
                let wp = wallpaperViewModel.wallpaper(for: screenId)
                let size = wallpaperViewModel.displayRect(of: screenId)?.size ?? screen.frame.size

                GroupBox {
                    VStack(spacing: 8) {
                        HStack {
                            Text(WallpaperViewModel.screenName(for: screen))
                                .font(.headline)
                            Text(verbatim: "\(Int(size.width))×\(Int(size.height))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { wallpaperViewModel.isScreenEnabled(screenId) },
                                set: { _ in wallpaperViewModel.toggleScreen(screenId) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        if wallpaperViewModel.isScreenEnabled(screenId) {
                            HStack {
                                DisplayWallpaperPicture(wallpaper: wp,
                                                        displayName: WallpaperViewModel.screenName(for: screen),
                                                        displaySize: size,
                                                        displayScale: screen.backingScaleFactor,
                                                        placement: wallpaperViewModel.wallpaperPlacement)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(DisplaySettings.title(of: wp))
                                        .font(.callout)
                                        .fontWeight(.medium)
                                    Text(verbatim: wp.project == .invalid || wp.project.type.isEmpty ? "—" : LocalizedLabels.wallpaperType(wp.project.type))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove") {
                                    // A clone shows its main display's wallpaper: removing it removes that.
                                    wallpaperViewModel.wallpapers.removeValue(
                                        forKey: wallpaperViewModel.layoutResolution.source(of: screenId))
                                }
                                .glassButtonStyle()
                                .controlSize(.small)
                                .disabled(wp.project == .invalid)
                            }
                        } else {
                            Text("Wallpaper display is disabled on this screen.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    viewModel.presentation.isDisplaySettingsReveal = false
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(.prominent)
            }
        }
        .padding(.horizontal, 40)
    }

    /// The name shown for a display's wallpaper; "No wallpaper" for the placeholder a display
    /// without one has (titled "Error" in its project).
    static func title(of wallpaper: WEWallpaper) -> String {
        wallpaper.project == .invalid || wallpaper.project.title.isEmpty
            ? String(localized: "No wallpaper") : wallpaper.project.title
    }
}
