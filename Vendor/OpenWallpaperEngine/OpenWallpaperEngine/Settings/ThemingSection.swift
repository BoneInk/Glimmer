import OWEInspectorKit
import OWETheming
import SwiftUI

/// Settings › General › Theming: macOS follows the scheme colour of the main display's wallpaper
/// (`ThemingController`, docs/theming.md). A master switch and one checkbox per target, all off by
/// default. Accent Color has two choices: what the system-wide accent becomes, and whether the
/// app's own windows use the exact colour.
struct ThemingSection: View {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @ObservedObject var controller: ThemingController

    private var theming: Binding<ThemingSettings> { $viewModel.settings.theming }
    private var isOn: Bool { viewModel.settings.theming.isEnabled }

    var body: some View {
        Section {
            Toggle("Theme macOS with the Wallpaper's Color", isOn: theming.isEnabled)
                .changedFromDefault(viewModel.isChanged(\.theming))
                .help("Uses the scheme color of the wallpaper on the main display, which follows its properties. Turning it off puts your own settings back.")
            if isOn {
                LabeledContent("Color") { currentColor }
            }
            Group {
                Toggle("Menu Bar", isOn: theming.menuBar)
                    .help("Fills the top of the wallpaper behind the menu bar, and of the desktop picture Open Wallpaper Engine sets, with the color; the transparent menu bar shows it.")
                Toggle("Accent Color", isOn: theming.accentColor)
                    .help("Sets System Settings › Appearance › Color to the closest of its colors, as macOS has no custom accent color, and the text highlight color to a light tint of the color.")
                accentChoices
                    .disabled(!viewModel.settings.theming.accentColor)
                Toggle("Tinted Icon Color", isOn: theming.tintedIcons)
                    .help("Sets the icon and widget style to Tinted, in the color.")
                Toggle("Folder Color", isOn: theming.folderColor)
                    .help("Sets the icon, widget and folder color, which folders use with every icon style.")
                Toggle(isOn: theming.restartsDockAutomatically) {
                    Text("Restart the Dock automatically to apply icon and folder colors")
                    Text("The Dock briefly reloads once the color stops changing. Your windows stay open.")
                }
                .help("The Dock shows a new icon style or tint only once it starts again. It restarts 1.5 seconds after the last change, and not at all when the colors are unchanged.")
                if controller.needsDockRestart && !viewModel.settings.theming.restartsDockAutomatically {
                    HStack {
                        Spacer()
                        Button("Restart Dock") { controller.restartDock() }
                            .help("The Dock and the icons show a new style or tint once the Dock starts again. Your windows stay open.")
                    }
                }
                Toggle("Use the wallpaper's main color when it has no scheme color", isOn: theming.usesDominantColor)
                    .help("Finds the most common color in the wallpaper's picture. Otherwise a wallpaper without a scheme color leaves everything as it is.")
                Toggle("Restore on Quit", isOn: theming.restoresOnQuit)
                    .help("Puts your own colors back when Open Wallpaper Engine quits. After a crash they are put back at the next launch.")
            }
            .disabled(!isOn)
        } header: {
            Label("Theming", systemImage: "paintbrush.fill")
        } footer: {
            Text("Your own settings are saved before the first change and put back when an option is turned off. The menu bar is translucent, so its color is a tint, and the accent color is the closest of macOS's colors.")
        }
        .settingsAnchor(SettingsAnchor.theming)
    }

    /// The system-wide accent (`SystemAccentChoice`) and the app's own (`AppAccentChoice`).
    @ViewBuilder private var accentChoices: some View {
        LabeledContent {
            HStack {
                Picker(selection: theming.systemAccent) {
                    Text("Nearest Apple Accent", comment: "Settings › Theming: the system accent becomes the closest of macOS's eight accent colors").tag(SystemAccentChoice.nearestApple)
                    Text("Multicolor", comment: "Settings › Theming: the system accent is macOS's Multicolor, so each app uses its own accent").tag(SystemAccentChoice.multicolor)
                } label: {
                    Text("System Accent", comment: "Settings › Theming: picker label, what the accent color of every app becomes")
                }
                .labelsHidden()
                .fixedSize()
                InfoTip(String(localized: "macOS has only eight accent colors. Nearest Apple Accent uses the closest one, so every app matches, though not exactly. Multicolor lets each app use its own accent instead. Either way, the text highlight and Open Wallpaper Engine itself can use the exact color.", comment: "Settings › Theming: info tip of the System Accent picker"))
            }
        } label: {
            Text("System Accent", comment: "Settings › Theming: picker label, what the accent color of every app becomes")
        }
        LabeledContent {
            HStack {
                Picker(selection: theming.appAccent) {
                    Text("Exact Wallpaper Color", comment: "Settings › Theming: Open Wallpaper Engine's own controls use the wallpaper's color itself").tag(AppAccentChoice.themeColor)
                    Text("Follow System Accent", comment: "Settings › Theming: Open Wallpaper Engine's own controls use the system accent color, like other apps").tag(AppAccentChoice.system)
                } label: {
                    Text("Open Wallpaper Engine's Accent", comment: "Settings › Theming: picker label, the accent color of Open Wallpaper Engine's own windows")
                }
                .labelsHidden()
                .fixedSize()
                InfoTip(String(localized: "Exact Wallpaper Color gives the buttons, switches, sliders, selections and links of every Open Wallpaper Engine window the wallpaper's color itself, which the system accent can't show. Follow System Accent uses the same accent as other apps.", comment: "Settings › Theming: info tip of the Open Wallpaper Engine's Accent picker"))
            }
        } label: {
            Text("Open Wallpaper Engine's Accent", comment: "Settings › Theming: picker label, the accent color of Open Wallpaper Engine's own windows")
        }
    }

    @ViewBuilder private var currentColor: some View {
        if let color = controller.color {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: color.red, green: color.green, blue: color.blue))
                    .overlay(Circle().strokeBorder(.separator))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(controller.isDerivedColor ? "Wallpaper's main color" : "Scheme color")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("None").foregroundStyle(.secondary)
        }
    }
}
