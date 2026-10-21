import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

struct SceneInspectorContent: View {
    @StateObject var model: SceneInspectorModel
    /// Depth maps and depth parallax, kept in the wallpaper's editor overlay.
    @StateObject var depthMaps: SceneEditorDepthMapHost
    @State var selectedID: String?
    @State var searchText = ""
    @State var didCopyPath = false
    /// The compact frame readout of the scene this mode runs (`SceneRenderStatsSampler`).
    @State var statsFeed: RenderStatsFeed?
    @State var isMovementPresented = true
    @State var isConfirmingReset = false
    /// Why a JSON editor's Save failed, shown until dismissed.
    @State var saveError: String?
    @State var columnVisibility: NavigationSplitViewVisibility
    /// Moves when the Export Settings sheet closes, so the panel reads the properties it changed.
    @State var exportPanelRevision = 0
    @FocusState var isSearchFocused: Bool
    let wallpaperDirectory: URL
    let wallpaper: WEWallpaper
    /// The stores the editor edits: the running wallpaper's, or the isolated session's.
    let scopes: [WallpaperPropertyScope]
    /// An isolated mode's session; nil in the Wallpaper mode.
    let isolated: IsolatedSceneEditSession?
    let exportModel: LivePhotoExportModel?
    let screenSaverModel: ScreenSaverEditorModel?
    let androidModel: AndroidExportEditorModel?
    let videoScreenSaver: VideoScreenSaverModel?
    /// A mode shown but unavailable for this wallpaper (`SceneEditorModes`), while it is chosen.
    let unavailableMode: SceneInspectorMode?
    let onModeChange: (SceneInspectorMode, SIMD2<Double>) -> Void
    /// The mode to enter once the scene's size is known (`showSceneInspector(…mode:)`). An isolated
    /// mode's content passes its own mode, so appearing doesn't switch straight back to Wallpaper.
    let initialMode: SceneInspectorMode

    var mode: SceneInspectorMode {
        if let unavailableMode { return unavailableMode }
        if exportModel != nil { return .deviceExport }
        if androidModel != nil { return .androidExport }
        return screenSaverModel == nil && videoScreenSaver == nil ? .wallpaper : .screenSaver
    }

    /// Why the chosen mode can't be used for this wallpaper; nil when it can.
    var unavailableReason: String? {
        guard let unavailableMode, case .unavailable(let reason) = SceneEditorModes.availability(of: unavailableMode, for: wallpaper)
        else { return nil }
        return reason
    }

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope], isolated: IsolatedSceneEditSession?,
         exportModel: LivePhotoExportModel?, screenSaverModel: ScreenSaverEditorModel?, androidModel: AndroidExportEditorModel? = nil,
         videoScreenSaver: VideoScreenSaverModel? = nil, unavailableMode: SceneInspectorMode? = nil,
         onModeChange: @escaping (SceneInspectorMode, SIMD2<Double>) -> Void, initialMode: SceneInspectorMode = .wallpaper) {
        self.initialMode = initialMode
        self.videoScreenSaver = videoScreenSaver
        self.unavailableMode = unavailableMode
        // A video has no layers to list: its modes open on their preview alone.
        _columnVisibility = State(initialValue: SceneEditorModes.isVideo(wallpaper) ? .detailOnly : .all)
        wallpaperDirectory = wallpaper.wallpaperDirectory
        self.wallpaper = wallpaper
        self.scopes = scopes
        self.isolated = isolated
        self.exportModel = exportModel
        self.screenSaverModel = screenSaverModel
        self.androidModel = androidModel
        self.onModeChange = onModeChange
        _model = StateObject(wrappedValue: SceneInspectorModel(wallpaper: wallpaper, scopes: scopes))
        _depthMaps = StateObject(wrappedValue: SceneEditorDepthMapHost(wallpaper: wallpaper))
    }

    func matches(_ item: SceneInspectorItem) -> Bool {
        guard !searchText.isEmpty else { return true }
        if item.name.localizedCaseInsensitiveContains(searchText)
            || item.kind.localizedCaseInsensitiveContains(searchText)
            || item.sourcePath.localizedCaseInsensitiveContains(searchText)
            || (item.materialPath?.localizedCaseInsensitiveContains(searchText) ?? false)
            || (item.versionName?.localizedCaseInsensitiveContains(searchText) ?? false) {
            return true
        }
        if item.texturePaths.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
            || item.shaderPaths.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) {
            return true
        }
        return item.effects.contains { effect in
            effect.name.localizedCaseInsensitiveContains(searchText)
                || effect.title.localizedCaseInsensitiveContains(searchText)
                || (effect.maskPath?.localizedCaseInsensitiveContains(searchText) ?? false)
                || effect.controls.contains { $0.title.localizedCaseInsensitiveContains(searchText) || $0.key.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        inspectorSplitView
            .frame(minWidth: 1120, minHeight: 560)
            .frostedWindowBackground()
            .onAppear {
                selectedID = model.initiallySelectedID
                loadSelectedTextures()
                if statsFeed == nil { statsFeed = Self.statsFeed(wallpaper: wallpaper, scopes: scopes, isolated: isolated) }
                if initialMode != mode, SceneEditorModes.availability(of: initialMode, for: wallpaper) != nil {
                    onModeChange(initialMode, model.sceneSize)
                }
            }
            .onChange(of: selectedID) { _, _ in loadSelectedTextures() }
            .onDisappear {
                // The screen saver's last choices are saved before its store goes.
                screenSaverModel?.close()
                // The library's export selection for this mode ends with it.
                androidModel?.closeBatch()
                isolated?.end()
            }
    }

    /// Both side columns (the object list and the movement controls) start at one width.
    static let sidebarWidth: CGFloat = 300

    /// The frame readout's feed: an isolated mode's private instance, else the desktop's.
    static func statsFeed(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope],
                                  isolated: IsolatedSceneEditSession?) -> RenderStatsFeed {
        SceneRenderStatsSampler(instance: { [weak isolated] in
            if let isolated { return isolated.instances.instance(for: isolated.instanceKey) }
            return AppDelegate.shared.wallpaperViewModel.sceneInstances
                .instance(for: WallpaperInstanceKey(wallpaper, properties: scopes.first ?? .shared))
        }).makeFeed()
    }

    /// The symbol for an item's kind: particle systems and effects as everywhere in the editors.
    static func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "Particle": return "sparkles"
        case "Effect Stack": return "slider.horizontal.3"
        default: return "photo"
        }
    }

    /// The name shown for an item's kind; `kind` itself stays English, as the code matches on it.
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "Image": return String(localized: "Image", comment: "Scene Edit / Export: the kind of a scene object")
        case "Particle": return String(localized: "Particle System", comment: "Scene Edit / Export: the kind of a scene object")
        case "Video": return String(localized: "Video")
        case "Audio": return String(localized: "Audio")
        case "Effect Stack": return String(localized: "Effect Stack", comment: "Scene Edit / Export: the effects applied to a video")
        default: return String(localized: "Other", comment: "Scene Edit / Export: the kind of a scene object that is neither an image nor particles")
        }
    }

    var inspectorSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                // On the column, not the split view: there, with the right-hand inspector, the
                // search field's place in the toolbar and the columns' widths kept re-laying each
                // other out, and AppKit stopped the window's first layout after 300 passes.
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
                .modifier(SearchFieldFocus(isFocused: $isSearchFocused))
                // `sidebarToggle` takes its place, right before the modes.
                .toolbar(removing: .sidebarToggle)
                // Outermost, after `toolbar(removing:)`: inside it the width never reached the
                // column, which then opened at AppKit's default of about 140 points.
                .navigationSplitViewColumnWidth(min: 240, ideal: Self.sidebarWidth, max: 440)
        } detail: {
            modeDetail
                .overlay(alignment: .bottomTrailing) {
                    if let statsFeed { RenderStatsFeedBadge(feed: statsFeed).padding(10) }
                }
                .inspector(isPresented: $isMovementPresented) {
                    Group {
                        if let exportModel {
                            LivePhotoExportLayerPanel(model: exportModel) {
                                layerAdjustments(for: model.items.first(where: { $0.id == selectedID }))
                            }
                            .id(exportPanelRevision)
                        } else if let androidModel {
                            AndroidExportLayerPanel(model: androidModel) {
                                layerAdjustments(for: model.items.first(where: { $0.id == selectedID }))
                            }
                            .id(exportPanelRevision)
                        } else if let screenSaverModel {
                            ScreenSaverEditorPanel(model: screenSaverModel) {
                                layerAdjustments(for: model.items.first(where: { $0.id == selectedID }))
                            }
                        } else if let videoScreenSaver {
                            VideoScreenSaverPanel(model: videoScreenSaver)
                        } else if let unavailableReason {
                            Text(unavailableReason)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            movementColumn(for: model.items.first(where: { $0.id == selectedID }))
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: Self.sidebarWidth, max: 400)
                }
                .modifier(LivePhotoExportSheetHost(model: exportModel, onClose: { exportPanelRevision += 1 }))
                .modifier(AndroidExportSheetHost(model: androidModel, onClose: { exportPanelRevision += 1 }))
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        sidebarToggle
                    }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .navigation)
                    }
                    ToolbarItem(placement: .navigation) {
                        modePicker
                    }
                    // Separate items at the trailing end: on macOS 26 a fixed spacer keeps them
                    // from sharing one glass capsule.
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible)
                    }
                    ToolbarItem(placement: .automatic) {
                        pathControl
                    }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.fixed)
                    }
                    ToolbarItem(placement: .automatic) {
                        modeAction
                    }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.fixed)
                    }
                    // The right-hand panel's toggle is the last item, at the trailing edge of the
                    // window, as macOS places an inspector toggle.
                    ToolbarItem(placement: .automatic) {
                        panelToggle
                    }
                }
                .alert("Reset Scene Edits", isPresented: $isConfirmingReset) {
                    Button("Reset", role: .destructive) {
                        model.removeEdits()
                        // Rebuilt from the stored values, now without the edits, once this view's
                        // alert has closed.
                        let wallpaper = wallpaper, scopes = scopes
                        DispatchQueue.main.async { AppDelegate.shared.showSceneInspector(for: wallpaper, scopes: scopes) }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Do you want to undo every scene edit of “\(wallpaper.project.displayTitle)”? Its properties are kept.")
                }
                .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(saveError ?? "")
                }
        }
        .background {
            Button("") { focusSearch() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
            Button("") { toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .hidden()
        }
    }

    var isSidebarShown: Bool { columnVisibility != .detailOnly }

    func toggleSidebar() {
        withAnimation { columnVisibility = isSidebarShown ? .detailOnly : .all }
    }

    /// Shows or hides the object list; the system's own toggle is removed so this one sits right
    /// before the modes whether the list is shown or not.
    var sidebarToggle: some View {
        let title: LocalizedStringKey = isSidebarShown ? "Hide Sidebar" : "Show Sidebar"
        return Button(action: toggleSidebar) {
            Label(title, systemImage: "sidebar.left")
        }
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }

    /// The detail column: the selected object, or the device's lock screen.
    @ViewBuilder
    var modeDetail: some View {
        if let exportModel {
            LockScreenPreview(model: exportModel)
        } else if let androidModel {
            AndroidScreenPreview(model: androidModel)
        } else if let screenSaverModel {
            ScreenSaverEditorPreview(model: screenSaverModel)
        } else if videoScreenSaver != nil {
            VideoScreenSaverPreview(wallpaper: wallpaper)
        } else if let unavailableMode, let unavailableReason {
            ContentUnavailableView {
                Label { Text(unavailableMode.title) } icon: { Image(systemName: "nosign") }
            } description: {
                Text(unavailableReason)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            detailColumn
        }
    }

    /// Shows or hides the right-hand panel: Move & Align, the Screen Saver panel, or an export mode's Layer Adjustments.
    var panelToggle: some View {
        Button {
            withAnimation { isMovementPresented.toggle() }
        } label: {
            switch mode {
            case .wallpaper: Label("Move & Align", systemImage: "sidebar.right")
            case .screenSaver: Label("Screen Saver Panel", systemImage: "sidebar.right")
            case .deviceExport, .androidExport: Label("Layer Adjustments Panel", systemImage: "sidebar.right")
            }
        }
        .help(panelToggleHelp)
    }

    var panelToggleHelp: Text {
        switch mode {
        case .wallpaper: return Text("Show or hide the move, size and align controls")
        case .screenSaver: return Text("Show or hide the Screen Saver panel")
        case .deviceExport, .androidExport: return Text("Show or hide the Layer Adjustments panel")
        }
    }

    /// The Wallpaper mode's Reset Edits, or the export mode's Export Settings.
    @ViewBuilder
    var modeAction: some View {
        if let exportModel {
            Button {
                exportModel.showSettings()
            } label: {
                Label("Export Settings", systemImage: "square.and.arrow.up")
            }
            .help("Open the export settings and export: device, crop, clip, quality and properties")
        } else if let androidModel {
            Button {
                androidModel.showSettings()
            } label: {
                Label("Export Settings", systemImage: "square.and.arrow.up")
            }
            .help("Open the export settings and export: device, crop, output and properties")
        } else if let screenSaverModel {
            Button {
                screenSaverModel.setAsScreenSaver()
            } label: {
                Label("Set as Screen Saver", systemImage: "display")
            }
            .help("Make this version of the wallpaper the screen saver")
        } else if videoScreenSaver != nil || unavailableMode != nil {
            EmptyView()
        } else {
            Button {
                isConfirmingReset = true
            } label: {
                Label("Reset Edits", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Undo every change made to this wallpaper in Scene Edit / Export")
        }
    }

    /// The modes this wallpaper shows (`SceneEditorModes`): all of them for a scene, a video's
    /// screen saver and exports, a web wallpaper's Wallpaper mode and its unavailable Android Export.
    var modePicker: some View {
        let entries = SceneEditorModes.entries(for: wallpaper)
        return Picker("Mode", selection: Binding(get: { mode }, set: { newValue in
            guard newValue != mode else { return }
            onModeChange(newValue, model.sceneSize)
        })) {
            ForEach(entries, id: \.mode) { entry in
                Text(entry.mode.title).tag(entry.mode)
            }
        }
        .pickerStyle(.segmented)
        .help(Text("Edit the running wallpaper, set it as your screen saver, preview it as an iPhone or iPad lock screen and export a Live Photo, or frame it for an Android device and export a .mpkg, without changing your desktop"))
    }

    /// ⌘K. macOS 15 focuses a search field through `searchFocused`; macOS 14 has no API for it,
    /// so the window's search field is made first responder directly.
    func focusSearch() {
        if #available(macOS 15, *) {
            isSearchFocused = true
        } else {
            guard let window = NSApp.keyWindow,
                  let field = Self.searchField(in: window.contentView?.superview ?? window.contentView) else { return }
            window.makeFirstResponder(field)
        }
    }

    static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
