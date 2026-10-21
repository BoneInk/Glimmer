import AppKit
import SwiftUI
import OWESceneEditing

/// A browser tile's picture: the subject's rendered preview (a still, or a muted loop), a spinner
/// while it is rendered, else `symbol`. Asks the provider for the preview when it first shows.
struct EditorPreviewView: View {
    @ObservedObject var provider: EditorPreviewProvider
    let subject: EditorPreviewSubject
    let symbol: String

    var body: some View {
        ZStack {
            switch provider.state(of: subject) {
            case .ready(let url) where url.pathExtension.lowercased() == EditorPreviewCache.movieExtension:
                LoopingMovieView(url: url)
            case .ready(let url):
                StillPreview(url: url, symbol: symbol)
            case .generating, nil:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L("Rendering preview"))
            case .failed:
                SymbolPreview(symbol: symbol)
            }
        }
        .onAppear { provider.request(subject) }
    }
}

/// The group's symbol, for an effect or system without a preview.
struct SymbolPreview: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
    }
}

/// A still preview, decoded off the main thread.
private struct StillPreview: View {
    let url: URL
    let symbol: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                SymbolPreview(symbol: symbol)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let url = url
            let decoded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            image = decoded
            failed = decoded == nil
        }
    }
}
