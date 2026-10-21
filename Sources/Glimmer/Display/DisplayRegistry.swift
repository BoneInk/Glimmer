import AppKit
import CoreGraphics
import Foundation
import Observation

/// 一台显示器的稳定描述符。
struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    /// 系统分配的稳定 UUID（`CGDisplayCreateUUIDFromDisplayID`），用于跨重启持久化。
    let id: String
    let displayID: UInt32
    let localizedName: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: Double
    let isPrimary: Bool
    let pixelSize: CGSize

    var resolutionText: String {
        "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }

    var shortIdentifier: String {
        String(id.prefix(8)).uppercased()
    }
}

/// 显示器注册表：枚举 + 变化通知（插拔、分辨率变化、主屏变化）。
///
/// macOS 在显示器参数变化时会发出 `NSApplication.didChangeScreenParametersNotification`；
/// 注册表把它转换为一次 `refresh()`，避免把屏幕状态散落在各处。
@MainActor
@Observable
final class DisplayRegistry {
    private(set) var displays: [DisplayDescriptor] = []
    private(set) var lastChangeAt: Date?
    /// 最近一次变化说明，用于诊断（例如「新增 1 台显示器」）。
    private(set) var lastChangeSummary: String?

    /// 通知令牌放在非隔离的盒子里：`deinit` 是 nonisolated 上下文，
    /// 而 `@Observable` 不允许把可变存储属性声明为 nonisolated。
    private final class NotificationTokenBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }

    private let tokenBox = NotificationTokenBox()

    init(observeChanges: Bool = true) {
        refresh()
        guard observeChanges else { return }
        tokenBox.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// An immutable initial snapshot for isolated preview/test sessions; no system observer.
    init(snapshot: [DisplayDescriptor]) {
        displays = snapshot
    }

    deinit {
        if let token = tokenBox.token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refresh() {
        let previous = Set(displays.map(\.id))
        displays = Self.enumerate()
        let current = Set(displays.map(\.id))
        let added = current.subtracting(previous)
        let removed = previous.subtracting(current)

        if lastChangeAt != nil || !previous.isEmpty {
            var parts: [String] = []
            if !added.isEmpty { parts.append("新增 \(added.count) 台") }
            if !removed.isEmpty { parts.append("移除 \(removed.count) 台") }
            if parts.isEmpty {
                parts.append("参数已更新（分辨率或排列）")
            }
            lastChangeSummary = parts.joined(separator: "，")
            lastChangeAt = Date()
        }
        // 只在真正变化时更新，避免首次刷新也记为「变化」
        if previous.isEmpty && !current.isEmpty {
            lastChangeSummary = nil
            lastChangeAt = nil
        }
    }

    var primary: DisplayDescriptor? {
        displays.first { $0.isPrimary } ?? displays.first
    }

    func descriptor(for id: String) -> DisplayDescriptor? {
        displays.first { $0.id == id }
    }

    func displayID(for uuidString: String) -> UInt32? {
        descriptor(for: uuidString)?.displayID
    }

    /// 系统枚举：同时使用 CGDisplay 与 NSScreen，两者都失败时返回空数组（不崩溃）。
    static func enumerate() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        let primaryID = CGMainDisplayID()

        let result = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        var displayIDs: [CGDirectDisplayID] = []
        if result == .success {
            displayIDs = Array(ids.prefix(Int(count)))
        }
        if displayIDs.isEmpty {
            displayIDs = NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }
        }

        var descriptors: [DisplayDescriptor] = []
        for displayID in displayIDs {
            guard let uuid = uuidString(for: displayID) else { continue }
            // On scaled Retina displays CGDisplayPixelsWide/High can report
            // logical mode dimensions. The active mode exposes backing pixels.
            let mode = CGDisplayCopyDisplayMode(displayID)
            var pixelSize = CGSize(
                width: CGFloat(mode?.pixelWidth ?? CGDisplayPixelsWide(displayID)),
                height: CGFloat(mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
            )
            let screen = NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }
            let frame = screen?.frame ?? CGDisplayBounds(displayID)
            if frame.width != frame.height,
               (frame.width < frame.height) != (pixelSize.width < pixelSize.height) {
                pixelSize = CGSize(width: pixelSize.height, height: pixelSize.width)
            }
            let visibleFrame = screen?.visibleFrame ?? frame
            let scale = screen?.backingScaleFactor ?? 1.0
            let name = screen?.localizedName ?? "显示器 \(displayID)"

            descriptors.append(
                DisplayDescriptor(
                    id: uuid,
                    displayID: displayID,
                    localizedName: name.isEmpty ? "显示器 \(displayID)" : name,
                    frame: frame,
                    visibleFrame: visibleFrame,
                    backingScaleFactor: Double(scale),
                    isPrimary: displayID == primaryID || CGDisplayIsMain(displayID) != 0,
                    pixelSize: pixelSize == .zero ? frame.size : pixelSize
                )
            )
        }
        return descriptors.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY > rhs.frame.minY
        }
    }

    /// 显示器 UUID 字符串。CGDisplayCreateUUIDFromDisplayID 在部分虚拟屏上可能失败，失败返回 nil。
    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let value = cfUUID.takeRetainedValue()
        let string = CFUUIDCreateString(nil, value) as String
        return string.uppercased()
    }
}
