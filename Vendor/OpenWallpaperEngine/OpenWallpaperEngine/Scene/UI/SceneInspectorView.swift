import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

/// Scene Edit / Export's modes: the wallpaper's objects, edited on the running wallpaper, or
/// the Screen Saver mode's version, the iPhone & iPad Export mode's lock screen or the Android
/// Export mode's screen, each edited on the mode's own copy (`IsolatedSceneEditSession`). The
/// picker lists them in this order.
enum SceneInspectorMode: CaseIterable {
    case wallpaper, screenSaver, deviceExport, androidExport

    var title: LocalizedStringResource {
        switch self {
        case .wallpaper: return LocalizedStringResource("Wallpaper", comment: "Scene Edit / Export: the mode that edits the running wallpaper")
        case .screenSaver: return LocalizedStringResource("Screen Saver", comment: "Scene Edit / Export: the mode that records the screen saver")
        case .deviceExport: return LocalizedStringResource("iPhone & iPad Export", comment: "Scene Edit / Export: the mode that exports a Live Photo")
        case .androidExport: return LocalizedStringResource("Android Export", comment: "Scene Edit / Export: the mode that exports a .mpkg for Wallpaper Engine's Android app")
        }
    }
}

/// Scene Edit / Export: its mode, and the editor for it. The Wallpaper mode edits the stores
/// the running wallpaper reads; the Screen Saver and iPhone & iPad Export modes each edit an
/// isolated copy of them made when the mode opens (`IsolatedSceneEditSession`), shown by the
/// mode's private instance and drawn by the screen saver or exported, and dropped when it closes. Every export
/// happens here, so a video opens it too, with the modes that apply to it (`SceneEditorModes`).
struct SceneInspectorView: View {
    private let wallpaper: WEWallpaper
    private let scopes: [WallpaperPropertyScope]
    @State private var exportModel: LivePhotoExportModel?
    @State private var screenSaverModel: ScreenSaverEditorModel?
    @State private var androidModel: AndroidExportEditorModel?
    @State private var videoScreenSaver: VideoScreenSaverModel?
    /// A mode shown but unavailable for this wallpaper, while it is chosen.
    @State private var unavailableMode: SceneInspectorMode?
    /// A video's picture size as it plays, which its export modes frame; read when the editor opens.
    @State private var videoSize: SIMD2<Double>?
    /// The mode the editor opens in, entered once its scene size is known.
    private let initialMode: SceneInspectorMode
    @State private var didEnterInitialMode = false

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope] = [.shared], initialMode: SceneInspectorMode = .wallpaper) {
        self.wallpaper = wallpaper
        self.scopes = scopes
        self.initialMode = SceneEditorModes.initialMode(initialMode, for: wallpaper)
    }

    private var isVideo: Bool { SceneEditorModes.isVideo(wallpaper) }

    var body: some View {
        if isVideo, videoSize == nil {
            ProgressView()
                .frame(minWidth: 1120, minHeight: 560)
                .frostedWindowBackground()
                .task {
                    // A file AVFoundation can't read (WebM, a remote video) has no export to frame.
                    var size: SIMD2<Double>?
                    if ScreenSaverVideoSource.isEligible(wallpaper) { size = await SceneEditorModes.videoSize(of: wallpaper.mediaURL) }
                    videoSize = size ?? SIMD2<Double>(SceneContentLoader.defaultCanvas)
                }
        } else if let exportModel {
            SceneInspectorContent(wallpaper: wallpaper, scopes: [exportModel.session.scope], isolated: exportModel.session,
                                  exportModel: exportModel, screenSaverModel: nil, onModeChange: setMode,
                                  initialMode: .deviceExport)
                .id(SceneInspectorMode.deviceExport)
        } else if let androidModel {
            SceneInspectorContent(wallpaper: wallpaper, scopes: [androidModel.session.scope], isolated: androidModel.session,
                                  exportModel: nil, screenSaverModel: nil, androidModel: androidModel, onModeChange: setMode,
                                  initialMode: .androidExport)
                .id(SceneInspectorMode.androidExport)
        } else if let screenSaverModel {
            SceneInspectorContent(wallpaper: wallpaper, scopes: [screenSaverModel.session.scope],
                                  isolated: screenSaverModel.session, exportModel: nil, screenSaverModel: screenSaverModel,
                                  onModeChange: setMode, initialMode: .screenSaver)
                .id(SceneInspectorMode.screenSaver)
        } else if let videoScreenSaver {
            SceneInspectorContent(wallpaper: wallpaper, scopes: scopes, isolated: nil, exportModel: nil, screenSaverModel: nil,
                                  videoScreenSaver: videoScreenSaver, onModeChange: setMode, initialMode: .screenSaver)
                .id(SceneInspectorMode.screenSaver)
        } else if let unavailableMode {
            SceneInspectorContent(wallpaper: wallpaper, scopes: scopes, isolated: nil, exportModel: nil, screenSaverModel: nil,
                                  unavailableMode: unavailableMode, onModeChange: setMode, initialMode: unavailableMode)
                .id("unavailable-\(unavailableMode)")
        } else {
            SceneInspectorContent(wallpaper: wallpaper, scopes: scopes, isolated: nil, exportModel: nil,
                                  screenSaverModel: nil, onModeChange: setMode,
                                  initialMode: didEnterInitialMode ? .wallpaper : initialMode)
                .id(SceneInspectorMode.wallpaper)
        }
    }

    /// Opening an isolated mode copies the edited store's values into its isolated store (the
    /// Screen Saver mode then takes its own saved choices, when it has any); leaving it drops
    /// them, once its preview (and with it the private instance) is gone.
    private func setMode(_ mode: SceneInspectorMode, sceneSize: SIMD2<Double>) {
        didEnterInitialMode = true
        leaveIsolatedModes(except: mode)
        if case .unavailable = SceneEditorModes.availability(of: mode, for: wallpaper) {
            unavailableMode = mode
            return
        }
        unavailableMode = nil
        // A video's modes frame its picture as it plays.
        let sceneSize = isVideo ? videoSize ?? sceneSize : sceneSize
        switch mode {
        case .deviceExport:
            guard exportModel == nil else { return }
            let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: LivePhotoExportModel.purpose,
                                                   seededFrom: scopes)
            exportModel = LivePhotoExportModel(session: session, sceneSize: sceneSize)
        case .androidExport:
            guard androidModel == nil else { return }
            let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: AndroidExportEditorModel.purpose,
                                                   seededFrom: scopes)
            let model = AndroidExportEditorModel(session: session, sceneSize: sceneSize)
            androidModel = model
            #if DEBUG
            AndroidBatchPicker.runScreenshotFixture(on: model)
            #endif
        case .screenSaver where isVideo:
            guard videoScreenSaver == nil else { return }
            videoScreenSaver = VideoScreenSaverModel(wallpaper: wallpaper, selectionService: AppDelegate.shared.screenSaverSelection)
        case .screenSaver:
            guard screenSaverModel == nil else { return }
            let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: ScreenSaverEditorModel.purpose,
                                                   seededFrom: scopes)
            let selectionService = AppDelegate.shared.screenSaverSelection
            screenSaverModel = ScreenSaverEditorModel(session: session, seededFrom: scopes, selectionService: selectionService,
                                                      store: selectionService.store)
        case .wallpaper:
            break
        }
    }

    private func leaveIsolatedModes(except mode: SceneInspectorMode) {
        if mode != .screenSaver { videoScreenSaver = nil }
        if mode != .deviceExport, let model = exportModel {
            exportModel = nil
            model.cancel()
            model.closeBatch()
            DispatchQueue.main.async { model.session.end() }
        }
        if mode != .screenSaver, let model = screenSaverModel {
            screenSaverModel = nil
            model.close()
            DispatchQueue.main.async { model.session.end() }
        }
        if mode != .androidExport, let model = androidModel {
            androidModel = nil
            model.cancel()
            model.closeBatch()
            DispatchQueue.main.async { model.session.end() }
        }
    }
}
