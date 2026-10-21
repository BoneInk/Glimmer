import Foundation

/// Undo for the user properties the Wallpaper Editor shows (the Details panel's own view,
/// `SceneUserPropertiesView`, editing the editor's draft store, `WallpaperPropertyScope.editorDraft`):
/// each change it announces (`wallpaperUserPropertyChanged`) is registered on the editor's undo
/// manager, beside the layer edits, and undoing writes the earlier value back through the same stores.
@MainActor
final class EditorUserPropertyUndo: ObservableObject {
    /// Moves when an undo or redo changed a value under the view, which then reads the store again.
    @Published private(set) var revision = 0
    private let targets: WallpaperPropertyTargets
    private let wallpaperPath: String
    private let undoManager: UndoManager
    private let coalescingInterval: TimeInterval
    /// The values as last seen, so a change knows what it replaced.
    private var values: [String: String]
    private var lastChange: (key: String, date: Date)?
    /// After every change of the values, the user's, an undo's or a revert's.
    var onChange: (() -> Void)?
    /// Set once in init and read again only in deinit, when nothing else can reach it.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// `scope`: the store the Details panel edits.
    init(wallpaper: WEWallpaper, scope: WallpaperPropertyScope, undoManager: UndoManager, coalescingInterval: TimeInterval = 1) {
        targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [scope])
        wallpaperPath = wallpaper.wallpaperDirectory.path
        self.undoManager = undoManager
        self.coalescingInterval = coalescingInterval
        values = targets.storedValues
        observer = NotificationCenter.default.addObserver(forName: .wallpaperUserPropertyChanged, object: nil,
                                                          queue: .main) { [weak self] notification in
            let path = notification.object as? String
            let key = notification.userInfo?["key"] as? String
            let value = notification.userInfo?["value"] as? String
            let stores = notification.userInfo?["stores"] as? [String] ?? []
            MainActor.assumeIsolated {
                guard let self, path == self.wallpaperPath, let key, let value,
                      stores.contains(where: self.targets.runtimeKeys.contains) else { return }
                self.changed(key, to: value)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// A slider dragged or a field typed in within `coalescingInterval` is one undo step.
    func changed(_ key: String, to value: String, now: Date = Date()) {
        let previous = values[key]
        values[key] = value
        guard previous != value else { return }
        onChange?()
        let continues = lastChange.map { $0.key == key && now.timeIntervalSince($0.date) < coalescingInterval } ?? false
        lastChange = (key, now)
        guard !continues else { return }
        register(key, restoring: previous)
    }

    private func register(_ key: String, restoring value: String?) {
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(key, to: value) }
        }
        undoManager.setActionName(String(localized: "Change User Property"))
        if grouped { undoManager.endUndoGrouping() }
    }

    /// Undo or redo: `key` back to `value` (nil: its default, the key dropped) in the store and
    /// the running wallpapers, registering the way back.
    private func restore(_ key: String, to value: String?) {
        var stored = targets.storedValues
        register(key, restoring: stored[key])
        stored[key] = value
        values = stored
        lastChange = nil
        targets.save(stored)
        for runtimeKey in targets.runtimeKeys { WallpaperPropertyTargets.publishReplacing(runtimeKey, stored) }
        revision += 1
        onChange?()
    }

    /// A property's value in the store; nil when it has none (its default applies).
    func value(_ key: String) -> String? { targets.storedValues[key] }

    /// Sets a value as the Details panel does (a texture variant's Preview): saved, sent to the
    /// running wallpaper, one undo step.
    func set(_ key: String, to value: String) {
        var stored = targets.storedValues
        guard stored[key] != value else { return }
        stored[key] = value
        targets.save(stored)
        for runtimeKey in targets.runtimeKeys { WallpaperPropertyTargets.publishReplacing(runtimeKey, stored) }
        lastChange = nil
        changed(key, to: value)
        revision += 1
    }

    /// Revert to Saved: the user properties back to `saved` (the store's other values, layer edits,
    /// kept), one undo step named `actionName` (grouped with the layer edits' revert of the same event).
    func revert(to saved: [String: String], actionName: String) {
        let stored = targets.storedValues
        let next = WallpaperPropertyReset.sceneInspectorEdits(in: stored).merging(saved) { _, new in new }
        guard next != stored else { return }
        replace(with: next, actionName: actionName)
    }

    /// Every value at once, registering the way back.
    private func replace(with next: [String: String], actionName: String) {
        let previous = targets.storedValues
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.replace(with: previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if grouped { undoManager.endUndoGrouping() }
        values = next
        lastChange = nil
        targets.save(next)
        for runtimeKey in targets.runtimeKeys { WallpaperPropertyTargets.publishReplacing(runtimeKey, next) }
        revision += 1
        onChange?()
    }
}
