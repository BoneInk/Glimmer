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

    static func coveredDisplays(
        frames: [String: CGRect], windows: [CGRect], mirroredDisplaySources: [String: String] = [:]
    ) -> Set<String> {
        let covered = Set(frames.compactMap { id, frame in
            windows.contains { covers(frame, window: $0) } ? id : nil
        })
        // 镜像接收屏没有独立 NSScreen，但仍可能有桌面播放会话，必须跟随源屏暂停。
        return covered.union(mirroredDisplaySources.compactMap { id, source in
            covered.contains(source) ? id : nil
        })
    }
}

@MainActor
enum GWMaximizedWindowDetector {
    static func hasMaximizedWindow() -> Bool {
        !maximizedDisplayIDs().isEmpty
    }

    static func maximizedDisplayIDs() -> Set<String> {
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return [] }

        // visibleFrame 每次重读，跟随 Dock 位置、自动隐藏、菜单栏及显示器布局变化。
        let identifiers = Dictionary(uniqueKeysWithValues: DisplayRegistry.enumerate().map { ($0.displayID, $0.id) })
        let frames = Dictionary(uniqueKeysWithValues: screens.compactMap { screen -> (String, CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let identifier = identifiers[number.uint32Value] else { return nil }
            return (identifier,
                    GWMaximizedWindowGeometry.quartzRect(screen.visibleFrame, primaryScreenTop: primary.frame.maxY))
        })
        let applicationPIDs = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
        }.map(\.processIdentifier))

        let bounds = windows.compactMap { info -> CGRect? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, applicationPIDs.contains(pid),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return rect
        }
        let mirroredDisplaySources = Dictionary(uniqueKeysWithValues: identifiers.compactMap { displayID, identifier -> (String, String)? in
            let sourceID = CGDisplayMirrorsDisplay(displayID)
            guard sourceID != kCGNullDirectDisplay, let source = identifiers[sourceID] else { return nil }
            return (identifier, source)
        })
        return GWMaximizedWindowGeometry.coveredDisplays(
            frames: frames, windows: bounds, mirroredDisplaySources: mirroredDisplaySources
        )
    }
}
