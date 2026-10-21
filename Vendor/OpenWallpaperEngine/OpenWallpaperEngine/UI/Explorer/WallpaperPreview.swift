//
//  WallpaperPreview.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI
import OWEInspectorKit

struct WallpaperPreview: SubviewOfContentView {
    @Environment(\.appAccentColor) private var accentColor
    var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @Environment(\.undoManager) var undoManager
    
    @State var isEditingId = ""
    @State var title = ""
    @State var newTag = ""
    
    @State var hoveredTag: String?
    /// SwiftUI cannot observe UserDefaults, so this store is what re-renders the music controls
    /// after their bindings write.
    @ObservedObject private var musicSync = VideoMusicSyncStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    /// Re-renders Set as Screen Saver as video files are checked and put in place.
    @ObservedObject private var screenSaver = AppDelegate.shared.screenSaver
    /// Re-renders Set as Screen Saver as it is set or stopped.
    @ObservedObject private var screenSaverSelection = AppDelegate.shared.screenSaverSelection
    /// The install a web page's Set as Screen Saver offers, and whether one is there.
    @ObservedObject private var chromiumEngine = AppDelegate.shared.chromiumEngine
    @State var isTagsHovered = false
    /// Counts the confirmed Resets; `SceneUserPropertiesView` resets on each change.
    @State private var propertyResets = 0
    @State private var isConfirmingPropertyReset = false
    /// Counts applied presets; the property rows reload their values on each change.
    @State private var presetApplications = 0

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }
    
    /// The displayed wallpaper's size on disk, measured off the main thread once per wallpaper: it
    /// walks every file, which stalled each redraw of the panel.
    @State private var measuredSize: (directory: URL, text: String)?

    /// Whether each scene shown ships sounds (`SceneAudioPresence`), found off the main thread
    /// once per wallpaper: it reads the wallpaper's packages.
    @State private var sceneAudioPresence: [URL: Bool] = [:]

    var wallpaperSize: String {
        guard let measuredSize, measuredSize.directory == wallpaperViewModel.displayedWallpaper.wallpaperDirectory
        else { return "…" }
        return measuredSize.text
    }

    private static func sizeText(of directory: URL) -> String {
        // An unreadable folder has no size to show; the placeholder says so.
        guard let sizeBytes = try? directory.directoryTotalAllocatedSize(includingSubfolders: true) else {
            return String(localized: "Unknown Size", comment: "Details panel: the wallpaper's size on disk can't be read")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
    
    /// The selected wallpaper's Set as Screen Saver, below Set as Wallpaper. It sets it at once,
    /// with its default settings (`ScreenSaverSelectionService.setAsScreenSaver`); customising it
    /// is Scene Edit / Export's Screen Saver tab.
    ///
    /// - Already the screen saver: a checked "Screen Saver" that opens Screen Saver settings
    ///   (where macOS's screen saver is chosen), and beside it Stop Using as Screen Saver, as
    ///   Delete sits beside Set as Wallpaper. A checked state says what is true at a glance;
    ///   stopping stays a separate, deliberate click rather than the main button's second meaning.
    /// - Can't be set: disabled, with why below it; a web page or WebM video without the
    ///   Chromium engine shows the install offer there.
    @ViewBuilder private var screenSaverButton: some View {
        let wallpaper = wallpaperViewModel.displayedWallpaper
        let availability = ScreenSaverSelectionService.availability(of: wallpaper,
                                                                    chromiumInstalled: chromiumEngine.installedVersion != nil)
        let pluginStatus = screenSaver.status(for: wallpaper)
        VStack(spacing: 6) {
            if screenSaverSelection.isSelected(wallpaper) {
                HStack(spacing: 6) {
                    Button {
                        ScreenSaverInstaller.current.openSettings()
                    } label: {
                        Label {
                            Text("Screen Saver")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                    .help(String(localized: "Open Screen Saver Settings",
                                 comment: "Details panel: opens System Settings where the screen saver is chosen"))
                    .accessibilityValue(Text("Selected", comment: "Details panel: this wallpaper is the screen saver"))
                    Button {
                        screenSaverSelection.stopUsingSelection()
                    } label: {
                        Label("Stop Using as Screen Saver", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .glassButtonStyle()
                    .help("Stop Using as Screen Saver")
                }
            } else {
                Button {
                    screenSaverSelection.setAsScreenSaver(wallpaper)
                } label: {
                    Label("Set as Screen Saver", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .disabled(!availability.isAvailable || pluginStatus == .notEligible)
            }
            screenSaverNote(availability)
        }
    }

    /// Why Set as Screen Saver can't apply, under it.
    @ViewBuilder private func screenSaverNote(_ availability: ScreenSaverSelectionService.Availability) -> some View {
        switch availability {
        case .needsChromium:
            VStack(alignment: .leading, spacing: 6) {
                screenSaverNoteText(String(localized: "Web wallpapers and WebM videos move in the screen saver only with the Chromium engine. Without it, the screen saver shows their picture."))
                Button("Install the Chromium Engine") { chromiumEngine.install() }
                    .glassButtonStyle()
                    .disabled(chromiumEngine.isBusy || chromiumEngine.pin == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .unavailable(let reason):
            screenSaverNoteText(reason)
        case .available:
            EmptyView()
        }
    }

    private func screenSaverNoteText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned outside the ScrollView so it stays put while the details scroll.
            Text("Details")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        GifImage(contentsOf: wallpaperViewModel.displayedWallpaper.previewURL
                                    ?? AppBundleLayout.wallpaperNotFoundURL,
                                 animates: viewModel.navigation.isApplicationActive)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color(nsColor: NSColor.controlBackgroundColor))
                            .frame(width: 280, height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16.0))
                            .overlay { RoundedRectangle(cornerRadius: 16.0).strokeBorder(Color.white, lineWidth: 4) }
                        HStack {
                            if isEditingId == "title" {
                                TextField("Wallpaper Title", text: $title)
                                    .onSubmit {
                                        var wallpaper = wallpaperViewModel.displayedWallpaper
                                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                                        // An empty or unchanged title keeps the current one.
                                        guard !trimmed.isEmpty, trimmed != wallpaper.project.title else {
                                            isEditingId = ""
                                            return
                                        }
                                        wallpaper.project.title = trimmed

                                        guard WallpaperProjectFileEdit.setLogging(["title": wallpaper.project.title], inProjectAt: wallpaper.wallpaperDirectory) else { return }

                                        wallpaperViewModel.inspect(wallpaper)

                                        isEditingId = ""
                                    }
                                    .onExitCommand { isEditingId = "" }
                            } else {
                                Text(verbatim: wallpaperViewModel.displayedWallpaper.project.displayTitle)
                                    .frame(minWidth: 50)
                                    .id("title")
                                    .lineLimit(1)
                                    .onTapGesture(count: 2, perform: beginTitleEdit)
                                Button(action: beginTitleEdit) {
                                    Label("Rename", systemImage: "square.and.pencil")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain)
                                .help("Rename")
                            }
                            
                        }
                    }
                        HStack {
                            Spacer()
                        AsyncImage(url: wallpaperViewModel.inspectedAuthor?.avatarURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable()
                            } else {
                                Image("we.placeholder").resizable()
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                        let authorID = wallpaperViewModel.inspectedAuthor?.steamId ?? wallpaperViewModel.inspectedWorkshopItem?.creatorId
                        if let authorID {
                            Button {
                                viewModel.navigation.topTabBarSelection = 1
                                viewModel.workshopVM.showAuthor(authorID)
                            } label: {
                                Text(wallpaperViewModel.inspectedAuthor?.personaName ?? authorID)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(.link)
                            .help("View this author's Workshop items")
                        } else if wallpaperViewModel.displayedWallpaper.project.official == true {
                            // WE's own default wallpapers: no Workshop author, made by Wallpaper Engine.
                            Text(verbatim: "Wallpaper Engine")
                        } else {
                            Text("Unknown Author")
                        }
                        Spacer()
                    }
                    .task(id: wallpaperViewModel.displayedWallpaper.wallpaperDirectory) {
                        wallpaperViewModel.loadDisplayedWorkshopDetails()
                    }
                    favoriteControl
                    HStack {
                        Text(verbatim: LocalizedLabels.wallpaperType(wallpaperViewModel.displayedWallpaper.project.type))
                        Text(wallpaperSize)
                            .task(id: wallpaperViewModel.displayedWallpaper.wallpaperDirectory) {
                                let directory = wallpaperViewModel.displayedWallpaper.wallpaperDirectory
                                let text = await Task.detached(priority: .utility) { Self.sizeText(of: directory) }.value
                                measuredSize = (directory, text)
                            }
                    }
                    .task(id: wallpaperViewModel.displayedWallpaper.wallpaperDirectory) {
                        let wallpaper = wallpaperViewModel.displayedWallpaper
                        let directory = wallpaper.wallpaperDirectory
                        guard wallpaper.project.type.lowercased() == "scene", sceneAudioPresence[directory] == nil else { return }
                        let hasAudio = await Task.detached(priority: .utility) {
                            SceneAudioPresence.hasAudio(in: directory)
                        }.value
                        sceneAudioPresence[directory] = hasAudio
                    }
                    .font(.footnote)

                    if let folder = LibraryFolders().folder(containing: wallpaperViewModel.displayedWallpaper.settingsDirectory) {
                        Label {
                            Text(verbatim: folder.lastPathComponent)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Text("From the library folder \(folder.path(percentEncoded: false))", comment: "%@ is a folder path"))
                    }
                    
                    ViewThatFits(in: .horizontal) {
                        tags.animation(.spring(), value: isTagsHovered)
                        ScrollView(.horizontal, showsIndicators: false) {
                            tags.animation(.spring(), value: isTagsHovered)
                        }
                    }
                    
                    .onHover { isTagsHovered = $0 }
                    
                    if isEditingId == "tags" {
                        HStack {
                            Button {
                                newTag = ""
                                isEditingId = ""
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            TextField("New Tag", text: $newTag)
                                .onSubmit {
                                    defer {
                                        newTag = ""
                                        isEditingId = ""
                                    }
                                    
                                    var wallpaper = wallpaperViewModel.displayedWallpaper
                                    let tags = ProjectTagList.adding(newTag, to: wallpaper.project.tags ?? [])
                                    guard tags != wallpaper.project.tags else { return }
                                    wallpaper.project.tags = tags

                                    guard WallpaperProjectFileEdit.setLogging(["tags": wallpaper.project.tags], inProjectAt: wallpaper.wallpaperDirectory) else { return }
                                    
                                    wallpaperViewModel.inspect(wallpaper)
                                }
                        }
                    }
                    GlassGroup(spacing: 6) {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Button {
                                    wallpaperViewModel.applyInspectedWallpaper()
                                } label: {
                                    Label("Set as Wallpaper", systemImage: "checkmark.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .glassButtonStyle(.prominent)

                                Button(role: .destructive) {
                                    viewModel.presentation.hoveredWallpaper = wallpaperViewModel.displayedWallpaper
                                    viewModel.presentation.isUnsubscribeConfirming = true
                                } label: {
                                    Label("Delete wallpaper", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .glassButtonStyle()
                                .help("Delete wallpaper")
                            }
                            screenSaverButton
                            Button {
                                AppDelegate.shared.showSceneInspector(for: wallpaperViewModel.displayedWallpaper,
                                                                      scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper))
                            } label: {
                                Label("Scene Edit / Export", systemImage: "square.stack.3d.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .glassButtonStyle()
                            .help("Scene Edit / Export", shortcut: .sceneInspector)
                        }
                    }
                    // MARK: Properties
                    CollapsibleSection(title: "Properties") {
                        VStack(alignment: .leading, spacing: 16) {
                            if wallpaperViewModel.displayedWallpaper.project.workshopid == nil {
                                Picker("Age Rating", selection: Binding(
                                    get: { wallpaperViewModel.displayedWallpaper.project.contentrating ?? "Everyone" },
                                    set: { wallpaperViewModel.setContentRating($0, for: wallpaperViewModel.displayedWallpaper) }
                                )) {
                                    ForEach(WorkshopTags.ratings, id: \.self) { rating in
                                        Text(LocalizedLabels.filterOption(rating)).tag(rating)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            HStack {
                                Label("Placement", systemImage: "arrow.up.left.and.arrow.down.right")
                                infoButton(SceneHelp.placement)
                                Spacer()
                                Picker("", selection: $wallpaperViewModel.wallpaperPlacement) {
                                    ForEach(WallpaperPlacement.allCases) { placement in
                                        Text(placement.label).tag(placement)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()
                            }
                            WallpaperDisplayOptionsSection(wallpaperViewModel: wallpaperViewModel)
                            switch wallpaperViewModel.displayedWallpaper.project.type.lowercased() {
                            case "video", "remote-video":
                                HStack {
                                    Label("Volume", systemImage: "speaker.wave.3.fill")
                                    infoButton(SceneHelp.volume)
                                    Spacer()
                                    NumericSliderInput(value: $wallpaperViewModel.playVolume, range: 0...1,
                                                       defaultValue: 1, displayScale: 100, suffix: "%",
                                                       fractionDigits: 0, sliderWidth: 100, fieldWidth: 36)
                                }
                                HStack {
                                    Label("Video Speed", systemImage: "play.fill")
                                    infoButton(SceneHelp.videoSpeed)
                                    Spacer()
                                    NumericSliderInput(value: $wallpaperViewModel.playRate, range: 0...2,
                                                       defaultValue: 1, step: 0.1, suffix: "x",
                                                       fractionDigits: 2, sliderWidth: 100, fieldWidth: 42)
                                }
                                HStack {
                                    Label("Audio Speed", systemImage: "waveform")
                                    infoButton(SceneHelp.audioSpeed)
                                    Spacer()
                                    Button {
                                        wallpaperViewModel.arePlaybackRatesLinked.toggle()
                                    } label: {
                                        Image(systemName: "link")
                                            .foregroundStyle(wallpaperViewModel.arePlaybackRatesLinked ? Color.primary : .gray)
                                    }
                                    .buttonStyle(.plain)
                                    .help(SceneHelp.linkRates)
                                    NumericSliderInput(value: $wallpaperViewModel.audioPlayRate, range: 0...2,
                                                       defaultValue: 1, step: 0.1, suffix: "x",
                                                       fractionDigits: 2, sliderWidth: 76, fieldWidth: 42)
                                        .disabled(wallpaperViewModel.arePlaybackRatesLinked)
                                }
                            case "scene":
                                MissingWorkshopDependenciesBanner(steamCmd: viewModel.steamCmd,
                                                                  dependencies: AppDelegate.shared.workshopDependencies,
                                                                  wallpaper: wallpaperViewModel.displayedWallpaper)
                                    .id(wallpaperViewModel.displayedWallpaper.wallpaperDirectory)
                                if sceneAudioPresence[wallpaperViewModel.displayedWallpaper.wallpaperDirectory] == true {
                                    sceneMusicControls(for: wallpaperViewModel.displayedWallpaper)
                                }
                            case "web":
                                ChromiumFeatureBadge(wallpaper: wallpaperViewModel.displayedWallpaper)
                                    .id(wallpaperViewModel.displayedWallpaper.wallpaperDirectory)
                            default:
                                EmptyView()
                            }
                        }
                    }
                    SceneUserPropertiesView(wallpaper: wallpaperViewModel.displayedWallpaper,
                                            scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper),
                                            resetRequest: propertyResets)
                        .id([wallpaperViewModel.displayedWallpaper.wallpaperDirectory.path]
                            + wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper).map(\.description)
                            + [String(presetApplications)])
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Text("Your Presets")
                            VStack {
                                Divider()
                                    .frame(height: 1)
                                    .overlay(accentColor)
                            }
                        }
                        WallpaperPresetsSection(wallpaper: wallpaperViewModel.displayedWallpaper,
                                                scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper),
                                                onApply: { presetApplications += 1 })
                            .id([wallpaperViewModel.displayedWallpaper.wallpaperDirectory.path]
                                + wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper).map(\.description))
                        // WE's Reset, last in its properties' action rows.
                        Button {
                            isConfirmingPropertyReset = true
                        } label: {
                            Label("Reset", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButtonStyle(.prominent)
                        .tint(.red)
                        .help(PropertyResetConfirmation.help)
                    }
                    .alert(PropertyResetConfirmation.title, isPresented: $isConfirmingPropertyReset) {
                        Button("Reset", role: .destructive) { propertyResets += 1 }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        let wallpaper = wallpaperViewModel.displayedWallpaper
                        Text(verbatim: PropertyResetConfirmation.message(
                            title: wallpaper.project.displayTitle,
                            scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaper)))
                    }
                }
                .blur(radius: wallpaperViewModel.displayedWallpaper.project == .invalid ? 16.0 : 0)
                .overlay {
                    if wallpaperViewModel.displayedWallpaper.project == .invalid {
                        Text("Please select a valid wallpaper")
                    }
                }
                .disabled(wallpaperViewModel.displayedWallpaper.project == .invalid ? true : false)
                .animation(.default, value: wallpaperViewModel.displayedWallpaper.project)
                .padding([.horizontal, .top])
                .padding(.bottom)
            }
        }
    }

    private var favoriteControl: some View {
        let wallpaper = wallpaperViewModel.displayedWallpaper
        let isFavorite = favorites.contains(wallpaper)
        let subscriptions = wallpaperViewModel.inspectedWorkshopItem?.subscriptions ?? 0
        return Button {
            favorites.toggle(wallpaper)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? Color.red : Color.secondary)
                if subscriptions > 0 {
                    Text(formatCount(subscriptions))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    private func sceneMusicControls(for wallpaper: WEWallpaper) -> some View {
        let enabledKey = "SceneMusicEnabled.\(wallpaper.wallpaperDirectory.path)"
        let volumeKey = "SceneMusicVolume.\(wallpaper.wallpaperDirectory.path)"
        let enabled = Binding<Bool>(
            get: { UserDefaults.app.object(forKey: enabledKey) == nil ? true : UserDefaults.app.bool(forKey: enabledKey) },
            set: {
                UserDefaults.app.set($0, forKey: enabledKey)
                musicSync.objectWillChange.send()
                NotificationCenter.default.post(name: .sceneMusicSettingsDidChange, object: nil,
                                                userInfo: ["path": wallpaper.wallpaperDirectory.path])
            }
        )
        let volume = Binding<Double>(
            get: { UserDefaults.app.object(forKey: volumeKey) == nil ? 1 : UserDefaults.app.double(forKey: volumeKey) },
            set: {
                UserDefaults.app.set($0, forKey: volumeKey)
                musicSync.objectWillChange.send()
                NotificationCenter.default.post(name: .sceneMusicSettingsDidChange, object: nil,
                                                userInfo: ["path": wallpaper.wallpaperDirectory.path])
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Scene Music", isOn: enabled)
                .toggleStyle(.checkbox)
                .help(SceneHelp.sceneMusic)
            if enabled.wrappedValue {
                HStack {
                    Label("Scene Music Volume", systemImage: "music.note")
                    infoButton(SceneHelp.sceneMusicVolume)
                    Spacer()
                    NumericSliderInput(value: volume, range: 0...1,
                                       defaultValue: 1, displayScale: 100, suffix: "%",
                                       fractionDigits: 0, sliderWidth: 100, fieldWidth: 36)
                }
            }
        }
    }
    
    /// Shows all tags about current wallpaper in horizontal: project.json's, then the Workshop
    /// item's. Only project.json's can be removed here.
    var tags: some View {
        HStack {
            let tags = viewModel.library.tags(of: wallpaperViewModel.displayedWallpaper)
            let projectTags = wallpaperViewModel.displayedWallpaper.project.tags ?? []
            if !tags.isEmpty {
                ForEach(tags, id: \.self) { tag in
                    Text(LocalizedLabels.filterOption(tag))
                        .padding(5)
                        .padding(.horizontal, 2)
                        .glassBackground(in: Capsule()) { pill in
                            // Before glass: a frosted pill with the old outline.
                            pill.background {
                                Capsule().fill(.regularMaterial)
                                Capsule().stroke(Color.secondary, lineWidth: 1.6)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if hoveredTag == tag, projectTags.contains(tag) {
                                Button {
                                    var wallpaper = wallpaperViewModel.displayedWallpaper
                                    // Optional lookup: the button shows only for project.json's own tags.
                                    guard let tags = wallpaper.project.tags else { return }
                                    wallpaper.project.tags = ProjectTagList.removing(tag, from: tags)

                                    guard WallpaperProjectFileEdit.setLogging(["tags": wallpaper.project.tags], inProjectAt: wallpaper.wallpaperDirectory) else { return }
                                    
                                    wallpaperViewModel.inspect(wallpaper)
                                } label: {
                                    Label("Remove Tag", systemImage: "xmark.circle.fill")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain)
                                .help("Remove Tag")
                                .foregroundStyle(.white, .red)
                                .symbolRenderingMode(.palette)
                                .offset(x: 5, y: -2.5)
                            }
                        }
                        .onHover { hovered in
                            if hovered {
                                hoveredTag = tag
                            } else {
                                hoveredTag = nil
                            }
                        }
                }
            } else {
                Text("No Tags")
                    .foregroundStyle(Color.secondary)
            }
            
            if isTagsHovered {
                Button {
                    isEditingId = "tags"
                } label: {
                    Label("Add Tag", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Add Tag")
            }
        }
        .font(.footnote)
        .lineLimit(1)
    }

    private func beginTitleEdit() {
        title = wallpaperViewModel.displayedWallpaper.project.title
        isEditingId = "title"
    }

    private func formatCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    private func infoButton(_ help: String) -> some View {
        InfoTip(help)
    }
}

/// A web wallpaper that uses APIs only Chromium has (`ChromiumFeatureAdvisor`): a small badge in
/// its details, with the APIs in its tooltip. The wallpaper is scanned when its details show.
private struct ChromiumFeatureBadge: View {
    let wallpaper: WEWallpaper
    @ObservedObject private var advisor = ChromiumFeatureAdvisor.shared
    @ObservedObject private var router = WebEngineRouter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Which engine plays it: Automatic (Chromium only when needed), or forced.
            Picker("Web engine", selection: Binding(get: { router.override(for: wallpaper) },
                                                    set: { router.setOverride($0, for: wallpaper) })) {
                Text("Automatic").tag(WebEngineOverride.automatic)
                Text(verbatim: "WebKit").tag(WebEngineOverride.webKit)
                Text(verbatim: "Chromium").tag(WebEngineOverride.chromium)
                    .selectionDisabled(!router.installed)
            }
            .pickerStyle(.menu)
            .help("Automatic plays this wallpaper in Chromium only if it uses Chromium-only features and the engine is installed; otherwise in WebKit, which uses far less memory.")
            badge
        }
        .task { await advisor.scan(wallpaper) }
    }

    @ViewBuilder private var badge: some View {
        Group {
            if let features = advisor.features(of: wallpaper), !features.isEmpty {
                Label("Some features only available on Chromium", systemImage: "globe.badge.chevron.backward")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .help(Text(verbatim: features.map(\.api).joined(separator: ", ")))
                    .accessibilityValue(Text(verbatim: features.map(\.api).joined(separator: ", ")))
            }
        }
    }
}

/// Shows when a scene wallpaper references effects/materials that live in another Steam Workshop
/// item that isn't installed locally, and lets the user download + link them in. Items that were
/// removed, made private or belong to another app are named with the reason and a link to their
/// Workshop page; the wallpaper plays without them.
private struct MissingWorkshopDependenciesBanner: View {
    @ObservedObject var steamCmd: SteamCmdService
    @ObservedObject var dependencies: WorkshopDependencyService
    let wallpaper: WEWallpaper

    @State private var missingIds: [String] = []

    private var unavailableIds: [String] { missingIds.filter { dependencies.unavailableReason(for: $0) != nil } }
    private var downloadableIds: [String] { missingIds.filter { dependencies.unavailableReason(for: $0) == nil } }

    var body: some View {
        Group {
            if !missingIds.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        if !downloadableIds.isEmpty {
                            Label("This wallpaper needs \(downloadableIds.count) other Workshop items to render correctly.",
                                  systemImage: "shippingbox")
                                .font(.footnote)
                        }
                        if !unavailableIds.isEmpty {
                            Label("\(unavailableIds.count) required Workshop items are unavailable",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                        }
                        ForEach(missingIds, id: \.self) { workshopId in
                            row(for: workshopId)
                        }
                        if !unavailableIds.isEmpty {
                            Button("Retry") {
                                dependencies.retry(Set(unavailableIds), forItemAt: wallpaper.wallpaperDirectory)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        if downloadableIds.isEmpty {
                            // Nothing left to download.
                        } else if !steamCmd.isInstalled || !steamCmd.isLoggedIn {
                            Text("Log in on the Workshop tab to download these.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Download All") {
                                for workshopId in downloadableIds {
                                    steamCmd.downloadWorkshopItem(workshopId: workshopId, asDependency: true)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: steamCmd.downloadProgress) { _ in
            for workshopId in missingIds where steamCmd.downloadProgress[workshopId] == .completed {
                WorkshopDependencyResolver.linkInstalledDependencies(for: wallpaper)
            }
            refresh()
        }
    }

    @ViewBuilder
    private func row(for workshopId: String) -> some View {
        if let reason = dependencies.unavailableReason(for: workshopId) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(workshopId).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if let page = WorkshopItemAvailability.workshopPageURL(for: workshopId) {
                        Link("Open in Workshop", destination: page).font(.caption)
                    }
                }
                Text(reason.message).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text(workshopId).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                statusView(for: workshopId)
            }
        }
    }

    @ViewBuilder
    private func statusView(for workshopId: String) -> some View {
        switch steamCmd.downloadProgress[workshopId] {
        case .downloading(let status):
            Text(status).font(.caption).foregroundStyle(.secondary)
        case .completed:
            Label("Linked", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private func refresh() {
        missingIds = Array(WorkshopDependencyResolver.missingWorkshopIds(for: wallpaper)).sorted()
    }
}

extension URL {
    /// check if the URL is a directory and if it is reachable
    func isDirectoryAndReachable() throws -> Bool {
        guard try resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return false
        }
        return try checkResourceIsReachable()
    }

    /// The allocated size of the regular files in the directory, and in its subfolders when
    /// `includingSubfolders`; nil when it isn't a reachable directory. Entries that can't be read
    /// are left out (logged) instead of losing the whole size.
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? {
        guard try isDirectoryAndReachable() else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: self, includingPropertiesForKeys: Array(keys),
            options: includingSubfolders ? [] : [.skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                OWELog.debug(.library, "Size of \(url.path) left out: \(error)")
                return true
            }) else { return nil }
        var total = 0
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                total += values.totalFileAllocatedSize ?? 0
            } catch {
                OWELog.debug(.library, "Size of \(url.path) left out: \(error)")
            }
        }
        return total
    }
}
