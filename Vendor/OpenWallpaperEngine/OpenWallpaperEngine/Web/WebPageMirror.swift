import SwiftUI

/// A clone's or stretch's member display showing its source display's Chromium page
/// (`WebPageMirrorView`).
struct WebPageMirror: NSViewRepresentable {
    let registry: WebPageMirrorRegistry
    let sourceScreenId: String

    func makeNSView(context: Context) -> WebPageMirrorView {
        WebPageMirrorView(registry: registry, sourceScreenId: sourceScreenId)
    }

    func updateNSView(_ nsView: WebPageMirrorView, context: Context) {}
}
