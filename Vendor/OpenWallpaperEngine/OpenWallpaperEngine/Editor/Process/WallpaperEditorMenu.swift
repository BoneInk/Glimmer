import AppKit
import OWEEditor

/// The Wallpaper Editor process's menu bar: the app menu, File (Close, Save, Save as New
/// Wallpaper…, Revert to Saved…), Edit, View (Wallpaper Engine's editor View menu,
/// `EditorViewCommand.menu`), Window and Help. File's document actions and the View menu go to the
/// key editor window (`WallpaperEditorController`) through the responder chain.
@MainActor
enum WallpaperEditorMenu {
    /// File › Save (the key editor window answers it).
    static let save = #selector(WallpaperEditorController.saveDocument(_:))
    /// File › Save as New Wallpaper… (the key editor window answers it).
    static let saveAsNewWallpaper = #selector(WallpaperEditorController.saveAsNewWallpaper(_:))
    /// File › Revert to Saved… (the key editor window answers it).
    static let revertToSaved = #selector(WallpaperEditorController.revertToSaved(_:))
    /// View › …: each item carries its command (`ViewCommandBox`).
    static let viewCommand = #selector(WallpaperEditorController.performViewCommand(_:))

    /// A View menu item's command, as its `representedObject`.
    final class ViewCommandBox: NSObject {
        let command: EditorViewCommand
        init(_ command: EditorViewCommand) { self.command = command }
    }

    /// The View menu from the editor's own list, titled in its catalog.
    static func viewMenu(_ entries: [EditorViewCommand.MenuEntry], title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in entries {
            switch entry {
            case .command(let command):
                let commandItem = NSMenuItem(title: command.title, action: viewCommand, keyEquivalent: "")
                commandItem.representedObject = ViewCommandBox(command)
                menu.addItem(commandItem)
            case .submenu(let title, let entries):
                menu.addItem(viewMenu(entries, title: title))
            case .separator:
                menu.addItem(.separator())
            }
        }
        item.submenu = menu
        return item
    }

    static func make(helpTarget: AnyObject, help: Selector) -> NSMenu {
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            item.submenu?.items = items
            return item
        }
        func item(_ name: AppShortcut.Name, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
            NSMenuItem(AppShortcut[name], action: action, target: target)
        }
        func plain(_ title: String, _ action: Selector?, key: String = "",
                   modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
            return item
        }

        let appMenu = submenu(String(localized: "Wallpaper Editor"), [
            plain(String(localized: "Hide Wallpaper Editor"), #selector(NSApplication.hide(_:)), key: "h"),
            item(.hideOthers, #selector(NSApplication.hideOtherApplications(_:))),
            plain(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            plain(String(localized: "Quit Wallpaper Editor"), #selector(NSApplication.terminate(_:)), key: "q"),
        ])

        let fileMenu = submenu(String(localized: "File"), [
            plain(String(localized: "Close"), #selector(NSWindow.performClose(_:)), key: "w"),
            plain(String(localized: "Save"), save, key: "s"),
            plain(String(localized: "Save as New Wallpaper…",
                         comment: "Wallpaper Editor File menu: saves a new wallpaper with the edits to the library, leaving the original as it was saved"),
                  saveAsNewWallpaper, key: "s", modifiers: [.command, .shift]),
            plain(String(localized: "Revert to Saved…",
                         comment: "Wallpaper Editor File menu: asks before going back to the wallpaper as it was last saved"),
                  revertToSaved),
        ])

        let editMenu = submenu(String(localized: "Edit"), [
            item(.undo, Selector(("undo:"))),
            item(.redo, Selector(("redo:"))),
            .separator(),
            item(.cut, #selector(NSText.cut(_:))),
            item(.copy, #selector(NSText.copy(_:))),
            item(.paste, #selector(NSText.paste(_:))),
            plain(String(localized: "Delete"), #selector(NSText.delete(_:))),
            item(.selectAll, #selector(NSText.selectAll(_:))),
        ])

        let windowMenu = submenu(String(localized: "Window"), [
            item(.minimize, #selector(NSWindow.performMiniaturize(_:))),
            plain(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            plain(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])

        let helpMenu = submenu(String(localized: "Help"), [
            item(.help, help, target: helpTarget),
        ])

        let menu = NSMenu()
        let viewMenu = viewMenu(EditorViewCommand.menu, title: EditorViewCommand.menuTitle)
        menu.items = [appMenu, fileMenu, editMenu, viewMenu, windowMenu, helpMenu]
        return menu
    }

    /// Installs `menu` as the app's, with AppKit's window list and Help search in their menus.
    static func install(_ menu: NSMenu) {
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.first { $0.submenu?.title == String(localized: "Window") }?.submenu
        NSApp.helpMenu = menu.items.last?.submenu
    }
}
