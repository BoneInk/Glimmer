import AppKit
import Observation

/// 菜单栏控制器（F08）：打开素材库、播放/暂停、切换到壁纸、退出。
@MainActor
@Observable
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: VideoLibraryStore
    private let playback: DesktopPlaybackController
    private let importService: ImportService
    private let displayRegistry: DisplayRegistry
    private var statusItem: NSStatusItem?

    /// 由 AppDelegate 注入：打开/聚焦素材库窗口。
    var openLibraryHandler: (() -> Void)?
    /// 由 AppDelegate 注入：保存状态并退出应用。
    var quitHandler: (() -> Void)?
    /// 由 AppDelegate 注入：打开桌面预览窗口（不影响真实桌面）。
    var previewHandler: (() -> Void)?
    /// 由 AppDelegate 注入：当前策略挂起原因（无挂起返回 nil）。
    var policyStatusProvider: (() -> String?)?

    init(
        store: VideoLibraryStore,
        playback: DesktopPlaybackController,
        importService: ImportService,
        displayRegistry: DisplayRegistry
    ) {
        self.store = store
        self.playback = playback
        self.importService = importService
        self.displayRegistry = displayRegistry
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
                NSColor.black.setFill()
                for (x, y, radius) in [
                    (12.5, 14.4, 0.8), (8.1, 15.4, 1.5),
                    (4.0, 13.0, 0.85), (2.7, 8.5, 1.45),
                    (5.0, 4.4, 0.7), (9.5, 3.1, 1.55),
                    (13.6, 5.0, 0.9), (14.6, 8.6, 1.3),
                    (10.7, 8.4, 0.95)
                ] {
                    NSBezierPath(ovalIn: NSRect(
                        x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
                    )).fill()
                }
                return true
            }
            button.image?.accessibilityDescription = AppConstants.displayName
            button.image?.isTemplate = true
            button.toolTip = "Glimmer"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let libraryItem = NSMenuItem(title: "打开素材库…", action: #selector(openLibrary), keyEquivalent: "o")
        libraryItem.target = self
        menu.addItem(libraryItem)

        menu.addItem(.separator())

        if playback.sessions.isEmpty {
            let empty = NSMenuItem(title: "没有正在播放的桌面壁纸", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // 播放/暂停按钮以「保存的用户意图」为准：策略挂起时 player.rate 为 0，
            // 不能据此判断用户想要播放还是暂停（否则点击会得到相反结果）。
            let anyIntentPlaying = playback.sessions.keys.contains { !store.settings(for: $0).isPaused }
            let playItem = NSMenuItem(
                title: anyIntentPlaying ? "暂停全部" : "继续全部",
                action: anyIntentPlaying ? #selector(pauseAll) : #selector(resumeAll),
                keyEquivalent: ""
            )
            playItem.target = self
            menu.addItem(playItem)

            if let reason = policyStatusProvider?(), !reason.isEmpty {
                let suspendItem = NSMenuItem(title: "自动暂停中：\(reason)", action: nil, keyEquivalent: "")
                suspendItem.isEnabled = false
                menu.addItem(suspendItem)
            }
        }

        let previewItem = NSMenuItem(title: "桌面预览…", action: #selector(openPreview), keyEquivalent: "")
        previewItem.target = self
        menu.addItem(previewItem)

        // 最近使用的素材，便于快速切换
        let recent = store.items
            .filter { $0.fileExists }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            .prefix(6)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "切换到壁纸", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in recent {
                let menuItem = NSMenuItem(
                    title: item.displayTitle,
                    action: #selector(applyRecent(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = item.id.uuidString
                menuItem.state = playback.sessions.values.contains { $0.item.id == item.id } ? .on : .off
                menu.addItem(menuItem)
            }
        }

        if playback.sessions.count > 1 {
            let clearItem = NSMenuItem(title: "移除全部桌面播放", action: #selector(clearAll), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(.separator())
        let infoItem = NSMenuItem(
            title: "显示器：\(displayRegistry.displays.count) 台 · 素材：\(store.items.count) 个",
            action: nil,
            keyEquivalent: ""
        )
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出Glimmer", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func openLibrary() {
        openLibraryHandler?()
    }

    @objc private func openPreview() {
        previewHandler?()
    }

    @objc private func pauseAll() {
        playback.pauseAll()
    }

    @objc private func resumeAll() {
        playback.resumeAll()
    }

    @objc private func applyRecent(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let item = store.item(withID: id) else { return }
        playback.apply(item: item, to: nil)
    }

    @objc private func clearAll() {
        playback.clear()
    }

    @objc private func quit() {
        quitHandler?()
    }
}
