import Combine
import Foundation

/// Scene Edit / Export's Screen Saver mode for a video wallpaper: the screen saver of a video
/// is the video itself, drawn live by the app as the desktop shows it (`ScreenSaverLiveVideo`), so
/// there is nothing to adjust; the mode sets it as the screen saver, or goes back to the desktop's
/// wallpaper.
@MainActor
final class VideoScreenSaverModel: ObservableObject {
    let wallpaper: WEWallpaper
    let selectionService: ScreenSaverSelectionService
    private var subscription: AnyCancellable?

    init(wallpaper: WEWallpaper, selectionService: ScreenSaverSelectionService) {
        self.wallpaper = wallpaper
        self.selectionService = selectionService
        subscription = selectionService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var isScreenSaver: Bool { selectionService.isSelected(wallpaper) }

    func setAsScreenSaver() {
        selectionService.pick(wallpaper, values: [:])
    }

    func stopUsingAsScreenSaver() {
        selectionService.stopUsingSelection()
    }
}
