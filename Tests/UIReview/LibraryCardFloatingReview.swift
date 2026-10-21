// Standalone focused fixture. Compile only with WallpaperCardView, model and glass helpers.
// It intentionally replaces ThumbnailCache with a read-only fixture actor, never production cache.
import AppKit
import SwiftUI

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    func thumbnail(for item: WallpaperItem) async -> NSImage? {
        guard !item.title.contains("无封面") else { return nil }
        return await MainActor.run {
            let image = NSImage(size: NSSize(width: 640, height: 520))
            image.lockFocus()
            NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: NSRect(x: 0, y: 0, width: 640, height: 520), angle: 35)
            NSColor.systemOrange.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: 330, y: 200, width: 220, height: 220)).fill()
            image.unlockFocus()
            return image
        }
    }
}

@MainActor private struct ReviewCards: View {
    let transparent: Bool
    let items: [WallpaperItem]
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(Array(zip([CGFloat(240), 290, 340], items)), id: \.1.id) { width, item in
                WallpaperCardView(item: item, isSelected: width == 290, isMissing: width == 340,
                    style: .init(reduceTransparency: !transparent, reduceMotion: true),
                    onToggleFavorite: {}, onSelect: {}, onApply: {}, onOpenDetails: {})
                    .frame(width: width)
            }
        }
        .padding(24)
        .background(LinearGradient(colors: [.purple.opacity(0.35), .teal.opacity(0.3)], startPoint: .top, endPoint: .bottom))
    }
}

@main struct LibraryCardFloatingReview {
    @MainActor static func main() async throws {
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/library-card-floating-review.png"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var items = [
            WallpaperItem(title: "很长的中文作品标题：晴空下远山与海岸，以及不需要挤在传统页脚里的文字", filePath: "/fixture/a.mp4", source: .local),
            WallpaperItem(title: "无封面的本地网页作品", filePath: "/fixture/project.json", source: .local),
            WallpaperItem(title: "原文件丢失仍可查看详情、收藏与重新定位", filePath: "/fixture/missing.mp4", source: .steamWorkshop)
        ]
        items[1].contentKind = .web
        let content = VStack(spacing: 24) {
            ReviewCards(transparent: true, items: items)
            ReviewCards(transparent: false, items: items)
        }.padding(16)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "库卡片隔离演示素材"
        window.contentView = host
        window.orderFrontRegardless()
        // Give native SwiftUI its initial layout and fixture thumbnail tasks.
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try bytes.write(to: URL(fileURLWithPath: output))
        window.orderOut(nil)
        print("Native card fixture rendered to \(output); no production cache, library or playback")
    }
}
