//
//  ContentViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import Combine
import Observation
import SwiftUI

/// The main window's state, split by concern so a view redraws only for what it reads:
/// `navigation` (tabs, panes, tile size), `presentation` (alerts, sheets, confirmations),
/// `filters` (the Installed filter sidebar) and `library` (the Installed list: search, sorting,
/// pages, selection). This owner keeps the Workshop services and the trust prompt.
@MainActor @Observable
final class ContentViewModel {
    let navigation = ContentNavigation()
    let presentation = ContentPresentation()
    let filters = FilterResultsViewModel()
    let library: InstalledLibraryModel

    var isUnsafeWallpaperWarningPresented = false

    /// The Installed tab picks wallpapers for an Android batch ("Export More with These
    /// Settings…") while this is set; nil is the library as usual. Never saved.
    private(set) var androidBatchPicker: AndroidBatchPicker?

    /// The Installed tab's own actions (context menus, Details and Set as Wallpaper, dragging into
    /// folders, imports, deleting, the other tabs): off while it picks wallpapers for an export.
    var allowsLibraryActions: Bool { androidBatchPicker == nil }

    /// Whether steamcmd is there and logged in: the only part of the service that reaches this
    /// model (the main window's Workshop tab and sidebar depend on it). The Workshop and Downloads
    /// views observe the service itself, so a download's progress doesn't redraw the window.
    private var steamCmdStatus: [Bool] = []
    private let steamCmdService = SteamCmdService()
    @ObservationIgnored private var steamCmdCancellable: AnyCancellable?

    /// Reading it observes whether steamcmd is there and logged in.
    var steamCmd: SteamCmdService {
        _ = steamCmdStatus
        return steamCmdService
    }
    /// Workshop wallpapers and authors hidden from the Workshop and Discover tabs.
    @ObservationIgnored lazy var workshopBlockList = WorkshopBlockList()
    @ObservationIgnored lazy var workshopVM: WorkshopViewModel = {
        let model = WorkshopViewModel(steamCmd: steamCmdService, blockList: workshopBlockList)
        model.showsBrowser = { [weak self] in self?.navigation.topTabBarSelection = 1 }
        model.attach(setAs: WorkshopSetAsFlow(environment: .app(workshop: model, library: library)))
        return model
    }()
    /// The Discover tab's lists.
    @ObservationIgnored lazy var discoverVM = WorkshopDiscoverViewModel(blockList: workshopBlockList)

    init() {
        library = InstalledLibraryModel(filters: filters, steamCmd: steamCmdService, presentation: presentation)
        let svc = steamCmdService
        steamCmdCancellable = svc.$isLoggedIn
            .combineLatest(svc.$steamCmdPath.map { $0 != nil })
            .map { [$0, $1] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.steamCmdStatus = status }
                } else {
                    DispatchQueue.main.async { self?.steamCmdStatus = status }
                }
            }
    }

    /// Asks whether to trust `wallpaper` before it runs its code. The sheet is on the main window,
    /// which comes forward first: a wallpaper picked from the menu bar's Recent Wallpapers with the
    /// window closed would otherwise wait for an answer no one can see.
    func warningUnsafeWallpaperModal(which wallpaper: WEWallpaper) {
        OWELog.info(.library, "Asking to trust \(wallpaper.wallpaperDirectory.lastPathComponent) (\(wallpaper.project.type)) before it runs")
        AppDelegate.shared.openMainWindow()
        self.isUnsafeWallpaperWarningPresented = true
    }

    /// The library changed on disk: the next read lists and sorts it again.
    func refresh() {
        library.refresh()
    }

    // MARK: Android export selection

    /// Shows the Installed tab as `selection`'s picker, in place of one already shown.
    func showAndroidBatchPicker(_ selection: AndroidBatchPicker) {
        androidBatchPicker = selection
        navigation.topTabBarSelection = 0
    }

    /// Ends `selection`, if it is the one shown.
    func endAndroidBatchPicker(_ selection: AndroidBatchPicker) {
        guard androidBatchPicker === selection else { return }
        androidBatchPicker = nil
    }

    /// The Android Export mode `model` closed: its selection, if shown, ends.
    func endAndroidBatchPicker(for model: AndroidExportEditorModel) {
        guard let selection = androidBatchPicker, selection.model === model else { return }
        androidBatchPicker = nil
    }
}
