//
//  AboutUsView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI

extension AppDelegate {
    @objc func showAboutUs() {
        let window = NSWindow()
        window.styleMask = [.closable, .titled]
        window.isReleasedWhenClosed = false
        window.title = ""
        window.contentView = NSHostingView(rootView: AboutUsView().frostedWindowBackground().appAccentTint())
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutUsView: View {
    static let websiteURL = URL(string: "https://openwallpaperengine.app/")!
    static let authorsURL = URL(string: "https://github.com/deepratna-awale/open-wallpaper-engine-mac/blob/main/AUTHORS.md")!

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Image(nsImage: NSImage(named: "AppIcon")!)
                Divider().frame(maxHeight: 100)
                VStack(alignment: .leading) {
                    Text(verbatim: "Open Wallpaper Engine").bold().font(.title)
                    Text("Wallpaper Engine for Mac").font(.footnote)
                }
            }
            VStack(spacing: 12) {
                Text("Version \(AppVersion.current)")
                    .textSelection(.enabled)
                Link(String("openwallpaperengine.app"), destination: Self.websiteURL)
                    .font(.callout)

                Divider().frame(width: 200)

                Text("Maintainer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                creditRow("Deepratna Awale", handle: "deepratna-awale", role: "Maintainer")
                    .font(.caption)

                Text("Credits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    creditRow("Haren Chen", handle: "haren724", role: "Original creator")
                    creditRow("MrWindDog", handle: "MrWindDog", role: "Upstream maintainer")
                    creditRow("Chen Chia Yang", handle: "Unayung", role: "Scene rendering, Workshop, multi-display")
                    creditRow("1ris_W", handle: "Erica-Iris", role: "Chinese i18n")
                    creditRow("Klaus Zhu", handle: "klauszhu1105", role: "Original logo design")
                }
                .font(.caption)

                Link("All contributors", destination: Self.authorsURL)
                    .font(.caption)

                // The optional Depth Map Generation plugin's model (`DepthMapModelPin`).
                DepthMapPluginCredit()
                    .font(.caption)
            }
        }
        .frame(width: 440, height: 500)
    }
}

extension AboutUsView {
    private func creditRow(_ name: String, handle: String, role: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Link(String("@\(handle)"), destination: URL(string: "https://github.com/\(handle)")!)
                .frame(width: 120, alignment: .leading)
            Text(verbatim: "—")
                .foregroundStyle(.tertiary)
            Text(role)
                .foregroundStyle(.secondary)
        }
    }
}

struct AboutUsView_Previews: PreviewProvider {
    static var previews: some View {
        AboutUsView()
    }
}
