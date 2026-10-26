import AppKit
import CoreGraphics

/// WindowServer 元数据即可判断尺寸，不读取窗口标题或图像，也不使用辅助功能 API。
enum GWMaximizedWindowGeometry {
    /// AppKit 使用主屏左下角为原点；WindowServer 使用主屏左上角，副屏可有负坐标。
    static func quartzRect(_ rect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func covers(_ visibleFrame: CGRect, window: CGRect, tolerance: CGFloat = 2) -> Bool {
        guard !visibleFrame.isEmpty, !window.isEmpty,
              [visibleFrame.minX, visibleFrame.minY, visibleFrame.maxX, visibleFrame.maxY,
               window.minX, window.minY, window.maxX, window.maxY].allSatisfy(\.isFinite) else { return false }
        return window.minX <= visibleFrame.minX + tolerance
            && window.maxX >= visibleFrame.maxX - tolerance
            && window.minY <= visibleFrame.minY + tolerance
            && window.maxY >= visibleFrame.maxY - tolerance
    }
}

@MainActor
enum GWMaximizedWindowDetector {
    static func hasMaximizedWindow() -> Bool {
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        // visibleFrame 每次重读，跟随 Dock 位置、自动隐藏、菜单栏及显示器布局变化。
        let frames = screens.map {
            GWMaximizedWindowGeometry.quartzRect($0.visibleFrame, primaryScreenTop: primary.frame.maxY)
        }
        let applicationPIDs = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
        }.map(\.processIdentifier))

        return windows.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, applicationPIDs.contains(pid),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frames.contains { GWMaximizedWindowGeometry.covers($0, window: rect) }
        }
    }
}
