import AppKit
import SwiftUI

@main @MainActor
enum WallpaperActionLabelLayoutTests {
    static func main() {
        _ = NSApplication.shared
        for (title, symbol) in [("设为壁纸", "display"), ("锁屏", "lock.rectangle")] {
            let idle = NSHostingView(rootView: Button {} label: {
                WallpaperActionLabel(title: title, symbol: symbol, busy: false)
            }.buttonStyle(.glass).controlSize(.regular))
            let busy = NSHostingView(rootView: Button {} label: {
                WallpaperActionLabel(title: title, symbol: symbol, busy: true)
            }.buttonStyle(.glass).controlSize(.regular))
            let before = idle.fittingSize, during = busy.fittingSize
            precondition(before.width > 0 && before.height > 0)
            precondition(abs(before.width - during.width) < 0.5 && abs(before.height - during.height) < 0.5,
                         "Action button moved during loading: \(before) → \(during)")
            print("PASS \(title): idle \(before), busy \(during)")
        }
    }
}
