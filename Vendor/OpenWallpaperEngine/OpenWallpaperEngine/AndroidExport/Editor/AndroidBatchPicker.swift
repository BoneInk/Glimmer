import AppKit
import Observation

/// "Export More with These Settings…": the main window's Installed tab becomes a picker for the
/// Android Export mode's batch. The grid keeps its search, filters, folders and Finder's click
/// selection (`ClickSelection`), with its own set of picked wallpapers that lasts across folders
/// and searches; every other library action is off while it is shown. Wallpapers Android can't
/// play are dimmed and can't be picked (`reason(for:)`). **Export as .mpkg** hands the picks to
/// the mode's batch (`AndroidExportEditorModel.exportMore`), with the mode's settings, and ends
/// the selection; **Cancel** (Esc) ends it without exporting. Nothing of it is saved: it lives
/// only while the Android Export mode that started it is open.
@MainActor @Observable
final class AndroidBatchPicker {
    /// The Android Export mode whose settings the batch uses.
    let model: AndroidExportEditorModel
    /// The picked wallpapers' `identityPath`s; the edited wallpaper starts picked.
    private(set) var selected: Set<String>
    @ObservationIgnored private var anchor: String?
    /// `AndroidExportPlan.skipReason` per wallpaper, read once: it looks at a video's size on disk.
    @ObservationIgnored private var reasons: [String: String?] = [:]
    @ObservationIgnored private let skipReason: @MainActor (WEWallpaper) -> String?
    /// The whole library, which the picks are read from (they may be in other folders).
    @ObservationIgnored private let library: @MainActor () -> [WEWallpaper]
    @ObservationIgnored private let exporter: @MainActor ([WEWallpaper]) -> Void
    /// Ends the selection in the window showing it (`ContentViewModel.endAndroidBatchPicker`).
    @ObservationIgnored var onFinish: (@MainActor (AndroidBatchPicker) -> Void)?

    init(model: AndroidExportEditorModel, library: @escaping @MainActor () -> [WEWallpaper],
         skipReason: @escaping @MainActor (WEWallpaper) -> String? = AndroidExportPlan.skipReason,
         export: (@MainActor ([WEWallpaper]) -> Void)? = nil) {
        self.model = model
        self.library = library
        self.skipReason = skipReason
        exporter = export ?? { [weak model] in model?.exportMore($0) }
        let edited = model.wallpaper.identityPath
        selected = skipReason(model.wallpaper) == nil ? [edited] : []
        anchor = edited
    }

    var count: Int { selected.count }

    /// Why `wallpaper` can't be exported to Android; nil when it can.
    func reason(for wallpaper: WEWallpaper) -> String? {
        let key = wallpaper.identityPath
        if let reason = reasons[key] { return reason }
        let reason = skipReason(wallpaper)
        reasons[key] = .some(reason)
        return reason
    }

    func isSelected(_ wallpaper: WEWallpaper) -> Bool { selected.contains(wallpaper.identityPath) }

    /// A click on a tile, in the order the grid shows `shown`: a plain click or ⌘-click picks or
    /// unpicks it, ⇧-click adds the run from the last one clicked. Picks elsewhere stay picked.
    func click(_ wallpaper: WEWallpaper, kind: ClickSelection.Kind, in shown: [WEWallpaper]) {
        guard reason(for: wallpaper) == nil else { return }
        let id = wallpaper.identityPath
        switch kind {
        case .replace, .toggle:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        case .extend:
            let order = shown.filter { reason(for: $0) == nil }.map(\.identityPath)
            if let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
                selected.formUnion(order[min(start, end)...max(start, end)])
            } else {
                selected.insert(id)
                anchor = id
            }
        }
    }

    /// Edit › Select All: picks every wallpaper shown that can be exported.
    func selectAll(_ shown: [WEWallpaper]) {
        selected.formUnion(shown.filter { reason(for: $0) == nil }.map(\.identityPath))
        anchor = shown.first?.identityPath
    }

    /// What the batch exports, in its order: the edited wallpaper first, then the others by title.
    func picked() -> [WEWallpaper] {
        let edited = model.wallpaper
        let all = ExportLibraryPicker.library(library(), with: edited)
        var seen = Set<String>()
        let chosen = all.filter { selected.contains($0.identityPath) && reason(for: $0) == nil && seen.insert($0.identityPath).inserted }
            .sorted { $0.project.displayTitle.localizedStandardCompare($1.project.displayTitle) == .orderedAscending }
        return chosen.filter { $0.isSameWallpaper(as: edited) } + chosen.filter { !$0.isSameWallpaper(as: edited) }
    }

    /// The settings the batch uses: the device, the output and, pre-rendered, the frame rate.
    var summary: String {
        let mode = model.isPreRendered
            ? String(localized: "Pre-Rendered, \(model.options.frameRate) FPS")
            : String(localized: "Dynamic")
        let device = model.device?.name ?? String(localized: "Custom")
        return String(localized: "\(device) · \(mode). Only “\(model.wallpaper.project.displayTitle)” keeps its edits; the others export as authored.")
    }

    /// Export as .mpkg: runs the mode's batch on the picks, then ends the selection.
    func export() {
        let wallpapers = picked()
        guard !wallpapers.isEmpty else { return }
        exporter(wallpapers)
        finish()
    }

    /// Cancel (Esc): ends the selection without exporting.
    func cancel() { finish() }

    private func finish() { onFinish?(self) }
}

extension AppDelegate {
    /// Shows the main window's Installed tab as the picker for `model`'s batch, once Scene Edit /
    /// Export's sheets have closed: changing the main window while a sheet's close animation runs
    /// its own run loop sent AppKit into an endless constraints pass. When it ends, Scene Edit /
    /// Export comes back to the front, where the batch's progress shows.
    func beginAndroidBatchPicking(for model: AndroidExportEditorModel, attempts: Int = 40) {
        if let editor = sceneInspectorWindow, editor.attachedSheet != nil, attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.beginAndroidBatchPicking(for: model, attempts: attempts - 1)
            }
            return
        }
        // A later turn of the main run loop, outside any animation's.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let content = contentViewModel
            let library = content.library
            let selection = AndroidBatchPicker(model: model, library: { library.allWallpapers })
            selection.onFinish = { [weak self, weak content] selection in
                content?.endAndroidBatchPicker(selection)
                self?.sceneInspectorWindow?.makeKeyAndOrderFront(nil)
            }
            openMainWindow()
            content.showAndroidBatchPicker(selection)
        }
    }
}
