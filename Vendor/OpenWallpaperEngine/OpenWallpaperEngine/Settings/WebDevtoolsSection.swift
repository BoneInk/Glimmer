import SwiftUI

/// Settings › Optimizations › Developer Tools: WE's "CEF devtools" row (Advanced), for both web
/// engines (`WebDevtools`). The switch lasts for this session only.
struct WebDevtoolsSection: View {
    @ObservedObject var devtools: WebDevtools
    @State private var opened: WebDevtools.Target?

    var body: some View {
        Section {
            Toggle("Web wallpaper devtools", isOn: $devtools.isEnabled)
                .changedFromDefault(devtools.isEnabled)
                .help("Lets Safari's Web Inspector attach to web wallpapers and opens Chromium's DevTools to this Mac only (127.0.0.1, port 9222). Web wallpapers in Chromium reload when you switch it. Turns off when Open Wallpaper Engine quits.")
            HStack {
                if let opened { Text(Self.message(for: opened)).foregroundStyle(.secondary) }
                Spacer()
                Button("Open Devtools") { opened = devtools.open() }
                    .disabled(!devtools.isEnabled)
            }
        } header: {
            Label("Developer Tools", systemImage: "hammer.fill")
        }
        .settingsAnchor(SettingsAnchor.webDevtools)
        .onChange(of: devtools.isEnabled) { opened = nil }
    }

    static func message(for target: WebDevtools.Target) -> String {
        switch target {
        case .chromium(let url):
            return String(localized: "Chromium's DevTools list the web wallpapers at \(url.absoluteString)",
                          comment: "%@ is a local address, e.g. http://127.0.0.1:9222/")
        case .webKit:
            return String(localized: "In Safari, choose Develop, then this Mac, then the wallpaper's page. Turn on “Show features for web developers” in Safari's Advanced settings if there is no Develop menu.")
        case .none:
            return String(localized: "No web wallpaper active.")
        }
    }
}
