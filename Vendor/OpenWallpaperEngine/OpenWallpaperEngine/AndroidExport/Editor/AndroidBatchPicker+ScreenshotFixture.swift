#if DEBUG
import AppKit

extension AndroidBatchPicker {
    /// The launch argument that opens Scene Edit / Export's Android Export tab on the library's
    /// first scene and goes through "Export More with These Settings…" (the Export Settings sheet,
    /// then the Installed tab's picker), for screenshots of an isolated development copy
    /// (`OWE_ISOLATED_STATE`). `light` or `dark` after it sets the app's appearance. Debug builds only.
    static let screenshotFixtureArgument = "-OWEAndroidBatchPickerScreenshotFixture"

    static var isScreenshotFixture: Bool { ProcessInfo.processInfo.arguments.contains(screenshotFixtureArgument) }

    /// Opens the editor for the fixture once the library has loaded.
    static func openScreenshotFixtureIfRequested(library: InstalledLibraryModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: screenshotFixtureArgument) else { return }
        if arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
        // As a person would: the library window open and laid out first, then the editor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AppDelegate.shared.openMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let scene = library.allWallpapers.first(where: { $0.project.type.lowercased() == "scene" }) else {
                    OWELog.error(.app, "Android batch picker fixture: the library has no scene")
                    return
                }
                AppDelegate.shared.showSceneInspector(for: scene, mode: .androidExport)
            }
        }
    }

    /// The Android Export mode opened for the fixture: its Export Settings sheet, then Export More.
    static func runScreenshotFixture(on model: AndroidExportEditorModel) {
        guard isScreenshotFixture else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // `direct`: Export More without the sheet, to tell the sheet's part from the picker's.
            if ProcessInfo.processInfo.arguments.contains("direct") { return model.chooseMoreWallpapers() }
            model.showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.chooseMoreAfterSheet() }
        }
    }
}
#endif

