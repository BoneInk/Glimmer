import SwiftUI
import UniformTypeIdentifiers
import OWEInspectorKit
import OWESceneEditing

/// Wallpaper Engine authors often put a localization key in a property's `text` field rather than
/// a label. WE's own translation (`WallpaperEngineLabels`, from the bundled locale files) is used;
/// a key it doesn't know is turned into readable words instead of being shown raw.
private func sceneUserPropertyTitle(_ raw: String, labels: WallpaperEngineLabels = WallpaperEngineLabels()) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    // WE's (or the wallpaper's own) translation of a localisation key; authors' often carry
    // markup (`<u><h4>Audio Settings</h4></u>`), which a title shows as text.
    if let translated = labels.translation(trimmed) {
        return UserPropertyHTML.containsMarkup(translated) ? UserPropertyHTML.plainText(translated) : translated
    }
    // Authors write these keys inconsistently — ui_browse_ vs ui_browser_, property vs properties,
    // and stray hyphens — so the prefix is matched loosely rather than from a fixed list.
    guard let range = trimmed.range(of: #"(?i)^ui[_-][a-z]+[_-]propert(y|ies)[_-]"#,
                                    options: .regularExpression) else { return trimmed }
    let stripped = trimmed[range.upperBound...].replacingOccurrences(of: "-", with: "_")
    // Spelled as scheme_color, schemecolor and scheme_-color in the wild; all mean the same thing.
    if stripped.replacingOccurrences(of: "_", with: "").lowercased().hasPrefix("schemecolor") {
        return "Scheme"
    }
    let words = stripped.split(separator: "_").filter { !$0.isEmpty }.map { word -> String in
        word.count <= 2 ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
    }
    return words.isEmpty ? trimmed : words.joined(separator: " ")
}

struct SceneUserProperty: Identifiable {
    let id: String
    var title: String
    let type: String
    let order: Int
    let defaultValue: String
    let options: [(title: String, value: String)]
    let minimum: Double
    let maximum: Double
    /// project.json `condition`; nil when always shown.
    var condition: UserPropertyConditionExpression? = nil
    /// Raw (possibly HTML) label, kept for `text`/untyped notice rows.
    var rawText: String = ""
    var fraction: Bool = true
    var step: Double? = nil
    var precision: Int? = nil
    var editable: Bool = false

    var sliderFormat: UserPropertySliderFormat {
        UserPropertySliderFormat(minimum: minimum, maximum: maximum, fraction: fraction, step: step, precision: precision)
    }
}

struct SceneTextControl: Identifiable {
    let id: String
    let title: String
    let font: String
    let size: Double
}

final class SceneUserPropertiesModel: ObservableObject {
    @Published var properties: [SceneUserProperty] = []
    @Published var values: [String: String] = [:]
    @Published var textObjects: [SceneTextControl] = []
    @Published var authoredPropertyIDs: Set<String> = []
    /// The stores an edit goes to: the selected displays', or the shared one while synced.
    private let targets: WallpaperPropertyTargets
    private var pendingSave: DispatchWorkItem?
    private let wallpaperPath: String
    /// The text layers' Font and Size settings that hold the user's own value.
    private var userLayerSettings: Set<String> = []
    /// Tests and opens the user shortcuts bound here (this Mac's hash, read once).
    private(set) lazy var userShortcutLauncher = UserShortcutLauncher(opener: WorkspaceUserShortcutOpener(),
                                                                      systemHash: UserShortcutSystemHash.current())

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope]) {
        wallpaperPath = wallpaper.settingsDirectory.path
        targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: scopes)
        load(wallpaper)
    }

    func set(_ value: String, for property: SceneUserProperty) {
        set(value, forID: property.id)
    }

    func set(_ value: String, forID id: String) {
        guard values[id] != value else { return }
        values[id] = value
        if SceneTextLayerSettings.isLayerSetting(id) { userLayerSettings.insert(id) }
        NotificationCenter.default.post(name: .wallpaperUserPropertyChanged, object: wallpaperPath,
                                        userInfo: ["key": id, "value": value, "stores": targets.runtimeKeys])
        targets.publish(ownValues, defaults: defaultValues)
        pendingSave?.cancel()
        let snapshot = ownValues
        let work = DispatchWorkItem { [targets] in targets.save(snapshot) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Saves an edit `set` scheduled, now: for a caller that reads the stores back at once.
    func saveNow() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        targets.save(ownValues)
    }

    /// WE's Reset (`WallpaperPropertyReset`): every property shown here back to its default (the
    /// author's project.json value; the app's own settings at theirs), in every edited store, and
    /// applied to the running wallpapers at once, which rebuild what the dropped Scene Edit / Export
    /// edits changed (`SceneChangeImpact`).
    func resetToDefaults() {
        pendingSave?.cancel()
        pendingSave = nil
        let defaults = defaultValues
        let previous = values
        // Text layers' Font and Size go back to following the layers, so they aren't stored.
        values = targets.reset(to: defaults.filter { !SceneTextLayerSettings.isLayerSetting($0.key) })
        userLayerSettings = []
        // Web pages take a change key by key (WE's `applyUserProperties`).
        for (key, value) in values where previous[key] != value {
            NotificationCenter.default.post(name: .wallpaperUserPropertyChanged, object: wallpaperPath,
                                            userInfo: ["key": key, "value": value, "stores": targets.runtimeKeys])
        }
        for property in properties where values[property.id] == nil {
            values[property.id] = property.defaultValue
        }
    }

    /// The values to run and save: all but the text layers' Font and Size the user hasn't set,
    /// which show the layer's own (`SceneTextLayerSettings`).
    private var ownValues: [String: String] {
        values.filter { !SceneTextLayerSettings.isLayerSetting($0.key) || userLayerSettings.contains($0.key) }
    }

    private func trailingOrder(offset: Int, index: Int) -> Int {
        Int.max - max(0, offset - index)
    }

    private func load(_ wallpaper: WEWallpaper) {
        guard let root = OWELog.attempt(.ui, "Properties: project.json of \(wallpaper.wallpaperDirectory.lastPathComponent)", {
            try WEProject.json(in: wallpaper.wallpaperDirectory)
        }) ?? nil else { return }
        let definitions = UserPropertyDefinition.all(projectJSON: root)
        // A Workshop preset item's values are its defaults (what Reset returns to).
        let presetDefaults = WorkshopPresetItem.defaultValues(for: wallpaper)
        let labels = WallpaperEngineLabels.load(projectJSON: root)
        authoredPropertyIDs = Set(definitions.map(\.key))
        properties = definitions.map { definition in
            let plainTitle = UserPropertyHTML.containsMarkup(definition.text)
                ? UserPropertyHTML.plainText(definition.text) : definition.text
            var property = SceneUserProperty(id: definition.key, title: sceneUserPropertyTitle(plainTitle, labels: labels),
                                             type: definition.type, order: definition.order ?? Int.max,
                                             defaultValue: presetDefaults[definition.key] ?? definition.defaultValue,
                                             options: definition.options.map { (sceneUserPropertyTitle($0.label, labels: labels), $0.value) },
                                             minimum: definition.minimum, maximum: definition.maximum)
            property.condition = definition.condition.map(UserPropertyConditionExpression.init)
            // WE translates the whole `text` when it is a localisation key.
            property.rawText = labels.translation(definition.text) ?? definition.text
            property.fraction = definition.fraction
            property.step = definition.step
            property.precision = definition.precision
            property.editable = definition.editable
            return property
        }
        .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        let wallpaperType = wallpaper.project.type.lowercased()
        let isScene = wallpaperType == "scene"
        // Video goes through the same Metal scene renderer when that framework is selected, so it
        // gets the same adjustments and effect stack. Controls that need scene.json — layer
        // visibility and text layers — stay scene-only.
        let usesSceneRenderer: Bool
        if isScene {
            usesSceneRenderer = true
        } else if wallpaperType == "video" || wallpaperType == "remote-video" {
            // Read the persisted blob rather than the main-actor view model: this loader is nonisolated.
            let stored = UserDefaults.app.data(forKey: "GlobalSettings")
                .flatMap { data in OWELog.attempt(.settings, "Stored GlobalSettings") { try JSONDecoder().decode(GlobalSettings.self, from: data) } }
            usesSceneRenderer = (stored ?? GlobalSettings()).videoFramework == .metal
        } else {
            usesSceneRenderer = false
        }
        if usesSceneRenderer {
            let visibilityProperties = isScene
                ? undeclaredVisibilityToggles(for: wallpaper, excluding: Set(properties.map(\.id)))
                : []
            properties.append(contentsOf: [
                SceneUserProperty(id: "_owe_hue", title: String(localized: "Hue", comment: "Wallpaper setting added by the app"), type: "slider", order: Int.max - 5, defaultValue: "0", options: [], minimum: -Double.pi, maximum: Double.pi),
                SceneUserProperty(id: "_owe_saturation", title: String(localized: "Saturation", comment: "Wallpaper setting added by the app"), type: "slider", order: Int.max - 4, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_bloom", title: String(localized: "Bloom", comment: "Wallpaper setting added by the app"), type: "slider", order: Int.max - 3, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_blur", title: String(localized: "Blur", comment: "Wallpaper setting added by the app"), type: "slider", order: Int.max - 2, defaultValue: "1", options: [], minimum: 0, maximum: 2),
                SceneUserProperty(id: "_owe_speed", title: String(localized: "Animation Speed", comment: "Wallpaper setting added by the app"), type: "slider", order: Int.max - 1, defaultValue: "1", options: [], minimum: SceneClock.minimumRate, maximum: 2)
            ])
            // Mouse parallax (setting keys kept from when it lived with the native effects).
            properties.append(contentsOf: [
                SceneUserProperty(id: "_owe_effect_enabled_parallax", title: String(localized: "Mouse Parallax", comment: "Wallpaper setting added by the app"), type: "bool",
                                  order: Int.max - 7, defaultValue: "false", options: [], minimum: 0, maximum: 1),
                SceneUserProperty(id: "_owe_effect_parallax_amount", title: String(localized: "Parallax Amount", comment: "Wallpaper setting added by the app"), type: "slider",
                                  order: Int.max - 6, defaultValue: "1", options: [], minimum: 0, maximum: 2)
            ])
            // Some scenes gate a layer's visibility on a user property (e.g. a "dark"/"colored" variant
            // toggle) that the author forgot to declare in project.json; expose the simple on/off ones
            // anyway since the renderer already honors any visibleUserProperty by name.
            authoredPropertyIDs.formUnion(visibilityProperties.map(\.id))
            properties.append(contentsOf: visibilityProperties)
            if isScene { properties.append(contentsOf: colorCorrectionProperties(labels: labels)) }
            let textLayers = isScene ? textObjectsInScene(for: wallpaper) : []
            textObjects = textLayers
            for (index, textLayer) in textLayers.enumerated() {
                let prefix = "_owe_text_\(textLayer.id)_"
                properties.append(contentsOf: [
                    // Title is empty: the checkbox sits next to the text layer's own name, so "Enabled" would be redundant.
                    SceneUserProperty(id: prefix + "enabled", title: "", type: "bool", order: trailingOrder(offset: 110, index: index), defaultValue: "true", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "font", title: String(localized: "Font", comment: "Wallpaper setting added by the app"), type: "textinput", order: trailingOrder(offset: 100, index: index), defaultValue: textLayer.font, options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "size", title: String(localized: "Font Size", comment: "Wallpaper setting added by the app"), type: "slider", order: trailingOrder(offset: 90, index: index), defaultValue: String(textLayer.size), options: [], minimum: 1, maximum: 256),
                    SceneUserProperty(id: prefix + "bold", title: String(localized: "Bold", comment: "Wallpaper setting added by the app"), type: "bool", order: trailingOrder(offset: 80, index: index), defaultValue: "false", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "italic", title: String(localized: "Italic", comment: "Wallpaper setting added by the app"), type: "bool", order: trailingOrder(offset: 70, index: index), defaultValue: "false", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "color", title: String(localized: "Color", comment: "Wallpaper setting added by the app"), type: "color", order: trailingOrder(offset: 60, index: index), defaultValue: "1 1 1", options: [], minimum: 0, maximum: 1),
                    SceneUserProperty(id: prefix + "opacity", title: String(localized: "Transparency", comment: "Wallpaper setting added by the app"), type: "slider", order: trailingOrder(offset: 50, index: index), defaultValue: "1", options: [], minimum: 0, maximum: 1)
                ])
            }
        }
        // App extras (`_owe_…`, not in WE) keep their app-made ranges and slide in 0.01 steps;
        // at their defaults they leave WE's authored values untouched.
        properties = properties.map { property in
            guard property.id.hasPrefix("_owe_"), property.type == "slider", property.step == nil else { return property }
            var extra = property
            extra.step = 0.01
            extra.precision = 3
            return extra
        }
        // A stored Font or Size equal to the layer's own is one earlier versions stored: dropped.
        let layerDefaults: [String: String] = defaultValues.filter { SceneTextLayerSettings.isLayerSetting($0.key) }
        values = SceneTextLayerSettings.removingLayerValues(from: targets.storedValues, matching: [layerDefaults])
        userLayerSettings = Set(values.keys.filter(SceneTextLayerSettings.isLayerSetting))
        for property in properties where values[property.id] == nil {
            values[property.id] = property.defaultValue
        }
        targets.publish(ownValues, defaults: defaultValues)
    }

    /// Each shown property's default: what a wallpaper takes while its store lacks the key.
    private var defaultValues: [String: String] {
        Dictionary(properties.map { ($0.id, $0.defaultValue) }) { first, _ in first }
    }

    /// WE's own image filter and colour options, which its UI adds to every wallpaper's
    /// properties (`WEColorCorrectionProperty`), in WE's order after the authored ones.
    private func colorCorrectionProperties(labels: WallpaperEngineLabels) -> [SceneUserProperty] {
        WEColorCorrectionProperty.allCases.enumerated().map { index, key in
            let title = labels.translation(key.label.key) ?? key.label.english
            let order = trailingOrder(offset: 130, index: index)
            var property: SceneUserProperty
            switch key {
            case .filter:
                property = SceneUserProperty(id: key.rawValue, title: title, type: "combo", order: order,
                                             defaultValue: key.defaultValue,
                                             options: WEImageFilters.options { labels.translation($0) },
                                             minimum: 0, maximum: 1)
            case .showColorOptions:
                property = SceneUserProperty(id: key.rawValue, title: title, type: "bool", order: order,
                                             defaultValue: key.defaultValue, options: [], minimum: 0, maximum: 1)
            case .filterStrength, .brightness, .contrast, .saturation, .hueShift:
                property = SceneUserProperty(id: key.rawValue, title: title, type: "slider", order: order,
                                             defaultValue: key.defaultValue, options: [], minimum: 0, maximum: 100)
                // WE's slider row: step 1 (`property.step || 1`), whole numbers.
                property.fraction = false
                property.step = 1
            }
            property.condition = key.condition.map(UserPropertyConditionExpression.init)
            property.rawText = title
            return property
        }
    }

    /// Simple on/off `visibleUserProperty` gates (no string variant condition) that the author never
    /// declared in project.json. Condition-based "pick one of N" gates are skipped since we have no
    /// authored labels for their valid values.
    private func undeclaredVisibilityToggles(for wallpaper: WEWallpaper,
                                             excluding declaredIds: Set<String>) -> [SceneUserProperty] {
        let sceneFile = wallpaper.project.file
        let packageURL = wallpaper.wallpaperDirectory.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        guard let scene = Self.packagedScene(sceneFile, in: packageURL) else { return [] }

        var defaults: [String: String] = [:]
        func record(property: String?, value: Bool?, condition: String?) {
            guard let property, condition == nil, !declaredIds.contains(property), defaults[property] == nil else { return }
            defaults[property] = (value ?? true) ? "true" : "false"
        }
        for object in scene.objects {
            record(property: object.visibleUserProperty, value: object.visible, condition: object.visibleCondition)
            for effect in object.effects ?? [] {
                record(property: effect.visibleUserProperty, value: effect.visible, condition: effect.visibleCondition)
            }
        }
        return defaults.enumerated().map { index, entry in
            SceneUserProperty(id: entry.key, title: entry.key.capitalized, type: "bool",
                              order: trailingOrder(offset: 45, index: index), defaultValue: entry.value, options: [], minimum: 0, maximum: 1)
        }
    }

    /// The scene `sceneFile` in the package at `packageURL`; nil without a package (a folder
    /// wallpaper) or that scene, and, after one log line, when either can't be read.
    private static func packagedScene(_ sceneFile: String, in packageURL: URL) -> WEScene? {
        OWELog.attempt(.ui, "Properties: \(sceneFile) in \(packageURL.lastPathComponent)", quietIfMissing: true) {
            try PKGParser(url: packageURL).extractJSON(named: sceneFile, as: WEScene.self)
        } ?? nil
    }

    private func textObjectsInScene(for wallpaper: WEWallpaper) -> [SceneTextControl] {
        let sceneFile = wallpaper.project.file
        let packageURL = wallpaper.wallpaperDirectory.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        guard let scene = Self.packagedScene(sceneFile, in: packageURL) else { return [] }
        return scene.objects.enumerated().compactMap { index, object in
            guard object.textValue != nil else { return nil }
            return SceneTextControl(id: String(object.id ?? index), title: object.name?.isEmpty == false ? object.name!
                                        : String(localized: "Text \(index + 1)", comment: "A text layer without a name"),
                                    font: object.font ?? "", size: object.pointsize ?? WETextDefaults.pointSize)
        }
    }
}

struct SceneUserPropertiesView: View {
    @StateObject private var model: SceneUserPropertiesModel
    @ObservedObject private var musicSync = VideoMusicSyncStore.shared
    private let wallpaper: WEWallpaper
    /// Each change resets the properties to their defaults (the Details panel's Reset).
    private let resetRequest: Int

    /// `scopes`: whose properties it edits (`WallpaperViewModel.editedPropertyScopes`), the first shown.
    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope] = [.shared], resetRequest: Int = 0) {
        self.wallpaper = wallpaper
        self.resetRequest = resetRequest
        _model = StateObject(wrappedValue: SceneUserPropertiesModel(wallpaper: wallpaper, scopes: scopes))
    }

    private var isVideo: Bool { SceneContentLoader.isVideoType(wallpaper.project.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let wallpaperProperties = model.shownWallpaperProperties()
            if !wallpaperProperties.isEmpty {
                CollapsibleSection(title: "Wallpaper Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(wallpaperProperties) { property in
                            propertyView(property)
                        }
                    }
                }
            }
            let adjustmentProperties = model.properties.filter { property in
                property.id.hasPrefix("_owe_") && !isTextProperty(property)
            }
            if !adjustmentProperties.isEmpty || isVideo {
                CollapsibleSection(title: "User Scene Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if isVideo {
                            videoMusicSyncControls
                        }
                        if !adjustmentProperties.isEmpty {
                            DisclosureGroup("User Adjustments") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(adjustmentProperties) { property in
                                        propertyView(property)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        if !model.textObjects.isEmpty {
                            DisclosureGroup("Text Layers") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(model.textObjects, id: \.id) { textObject in
                                        DisclosureGroup {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ForEach(model.properties.filter { $0.id.hasPrefix("_owe_text_\(textObject.id)_") }) { property in
                                                    propertyView(property)
                                                }
                                            }
                                            .padding(.top, 4)
                                        } label: {
                                            HStack {
                                                if let enabled = model.properties.first(where: { $0.id == "_owe_text_\(textObject.id)_enabled" }) {
                                                    propertyView(enabled)
                                                }
                                                Text(textObject.title)
                                                Spacer()
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: resetRequest) { _, _ in model.resetToDefaults() }
        // While the panel shows, edits apply live (`ScenePropertyEditing`).
        .onAppear { WallpaperServices.shared.propertyEditing.begin() }
        .onDisappear { WallpaperServices.shared.propertyEditing.end() }
    }


    @ViewBuilder
    private var videoMusicSyncControls: some View {
        DisclosureGroup("Sync Video to Music") {
            VStack(alignment: .leading, spacing: 10) {
                videoMusicSyncRow(title: "Sync Zoom", help: SceneHelp.musicSync("zoom"),
                                  enabledKey: "zoomEnabled", amountKey: "zoomAmount",
                                  range: 0...0.5, defaultAmount: 0.08, suffix: "x")
                videoMusicSyncRow(title: "Sync Pace", help: SceneHelp.musicSync("pace"),
                                  enabledKey: "paceEnabled", amountKey: "paceAmount",
                                  range: -1...1, defaultAmount: 0.25, suffix: "x")
                videoMusicSyncRow(title: "Sync Tilt", help: SceneHelp.musicSync("tilt"),
                                  enabledKey: "tiltEnabled", amountKey: "tiltAmount",
                                  range: -15...15, defaultAmount: 3, suffix: "°")
                videoMusicSyncRow(title: "Sync Saturation", help: SceneHelp.musicSync("saturation"),
                                  enabledKey: "saturationEnabled", amountKey: "saturationAmount",
                                  range: -1...2, defaultAmount: 0.6, suffix: "x")
            }
            .padding(.top, 6)
        }
    }

    private func videoMusicSyncRow(title: LocalizedStringKey, help: String, enabledKey: String, amountKey: String,
                                   range: ClosedRange<Double>, defaultAmount: Double, suffix: String) -> some View {
        let wallpaper = self.wallpaper
        let isEnabled = Binding<Bool>(
            get: { VideoMusicSyncSettings.bool(wallpaper, enabledKey) },
            set: { VideoMusicSyncStore.shared.set($0, wallpaper, enabledKey) }
        )
        let amount = Binding<Double>(
            get: { VideoMusicSyncSettings.double(wallpaper, amountKey, default: defaultAmount) },
            set: { VideoMusicSyncStore.shared.set($0, wallpaper, amountKey) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Toggle(title, isOn: isEnabled)
                    .toggleStyle(.checkbox)
                infoButton(help)
            }
            if isEnabled.wrappedValue {
                HStack {
                    Text("Amount")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NumericSliderInput(value: amount, range: range,
                                       defaultValue: defaultAmount,
                                       suffix: suffix,
                                       fractionDigits: 3,
                                       sliderWidth: 100,
                                       fieldWidth: 64)
                }
            }
        }
    }

    private func isTextProperty(_ property: SceneUserProperty) -> Bool {
        property.id.hasPrefix("_owe_text_")
    }

    @ViewBuilder
    private func propertyView(_ property: SceneUserProperty) -> some View {
            switch property.type {
            case "group":
                HStack(spacing: 6) {
                    Text(property.title).font(.headline)
                    Divider()
                }
            case "slider":
                // WE shows the authored range, step and precision as they are (no unit conversion).
                let format = property.sliderFormat
                let value = Binding<Double>(
                    get: { Double(model.values[property.id] ?? property.defaultValue) ?? property.minimum },
                    set: { model.set(format.storedString($0), for: property) }
                )
                VStack(alignment: .leading, spacing: 4) {
                    parameterLabel(property.title, help: parameterHelp(property))
                    NumericSliderInput(value: value, range: property.minimum...max(property.maximum, property.minimum + 0.001),
                                       defaultValue: Double(property.defaultValue) ?? property.minimum,
                                       step: format.effectiveStep,
                                       fractionDigits: format.fractionDigits, fieldWidth: 76)
                    musicSyncControls(for: property)
                }
            case "bool":
                HStack {
                    Toggle(property.title, isOn: Binding(get: { (model.values[property.id] ?? property.defaultValue).lowercased() == "true" },
                                                          set: { model.set($0 ? "true" : "false", for: property) }))
                    infoButton(parameterHelp(property))
                }
                    .toggleStyle(.checkbox)
            case "combo":
                let selection = Binding(get: { model.values[property.id] ?? property.defaultValue },
                                        set: { model.set($0, for: property) })
                if property.editable {
                    // Editable combos accept a free value; the menu offers the authored options.
                    VStack(alignment: .leading, spacing: 4) {
                        parameterLabel(property.title, help: parameterHelp(property))
                        HStack(spacing: 4) {
                            TextField("", text: selection)
                            Menu {
                                ForEach(property.options, id: \.value) { option in
                                    Button(option.title) { selection.wrappedValue = option.value }
                                }
                            } label: { EmptyView() }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                } else {
                    Picker(selection: selection) {
                        ForEach(property.options, id: \.value) { option in Text(option.title).tag(option.value) }
                    } label: {
                        parameterLabel(property.title, help: parameterHelp(property))
                    }
                }
            case "textinput":
                HStack {
                    TextField(property.title, text: Binding(get: { model.values[property.id] ?? property.defaultValue },
                                                            set: { model.set($0, for: property) }))
                    infoButton(parameterHelp(property))
                }
            case "color":
                ColorPicker(selection: Binding(
                    get: { colorValue(model.values[property.id] ?? property.defaultValue) },
                    set: { model.set(colorString($0), for: property) }
                ), supportsOpacity: false) {
                    parameterLabel(property.title, help: parameterHelp(property))
                }
                .anchorsColorPanel()
            case "file", "directory", "texture", "scenetexture":
                pathPicker(property)
            case SceneScriptUserProperties.Property.userShortcutType:
                UserShortcutPropertyRow(title: property.title.isEmpty ? String(localized: "Shortcut") : property.title,
                                        help: parameterHelp(property),
                                        value: model.values[property.id] ?? property.defaultValue,
                                        launcher: model.userShortcutLauncher,
                                        onChange: { model.set($0, for: property) })
            default:
                // "text" and untyped rows: author notices, headers and dividers.
                noticeRow(property)
            }
    }

    @ViewBuilder
    private func noticeRow(_ property: SceneUserProperty) -> some View {
        let text = property.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(UserPropertyHTML.attributed(sceneUserPropertyTitle(text)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pathPicker(_ property: SceneUserProperty) -> some View {
        let current = model.values[property.id] ?? property.defaultValue
        return VStack(alignment: .leading, spacing: 4) {
            parameterLabel(property.title, help: parameterHelp(property))
            HStack(spacing: 6) {
                Text(current.isEmpty ? String(localized: "None") : (current as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(current.isEmpty ? .secondary : .primary)
                    .help(current)
                Spacer()
                Button("Choose…") {
                    if let path = UserPropertyPathPanel.choose(type: property.type) {
                        model.set(path, for: property)
                    }
                }
                if !current.isEmpty {
                    Button("Clear") { model.set("", for: property) }
                }
            }
        }
    }

    @ViewBuilder
    private func musicSyncControls(for property: SceneUserProperty) -> some View {
        let syncID = "\(property.id)_musicSync"
        let amountID = "\(property.id)_musicAmount"
        let isEnabled = Binding<Bool>(
            get: { (model.values[syncID] ?? "false").lowercased() == "true" },
            set: { model.set($0 ? "true" : "false", forID: syncID) }
        )
        Toggle("Sync to Music", isOn: isEnabled)
            .toggleStyle(.checkbox)
            .font(.caption)
        if isEnabled.wrappedValue {
            // App extra (WE has no music sync): a modulation of up to the slider's own span.
            let displaySpan = max(property.maximum - property.minimum, 0.001)
            let amount = Binding<Double>(
                get: { Double(model.values[amountID] ?? "0") ?? 0 },
                set: { model.set(String($0), forID: amountID) }
            )
            HStack {
                Text("Music Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NumericSliderInput(value: amount, range: -displaySpan...displaySpan,
                                   defaultValue: 0, fractionDigits: 3,
                                   sliderWidth: 100, fieldWidth: 64)
            }
        }
    }

    private func parameterLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            infoButton(help)
        }
    }

    private func infoButton(_ help: String) -> some View {
        InfoTip(help)
    }

    private func parameterHelp(_ property: SceneUserProperty) -> String {
        if property.type == "color" { return SceneHelp.parameter(key: "color") }
        return SceneHelp.parameter(key: property.id, title: property.title)
    }

    private func colorValue(_ value: String) -> Color {
        let components = SceneVector.numbers(value)
        let scale = components.max() ?? 1 > 1 ? 255.0 : 1.0
        return Color(red: (components.indices.contains(0) ? components[0] : 1) / scale,
                 green: (components.indices.contains(1) ? components[1] : 1) / scale,
                 blue: (components.indices.contains(2) ? components[2] : 1) / scale)
    }

    private func colorString(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return "\(nsColor.redComponent) \(nsColor.greenComponent) \(nsColor.blueComponent)"
    }
}
/// Open panel for `file`, `directory`, `texture` and `scenetexture` properties; returns the chosen path.
enum UserPropertyPathPanel {
    @MainActor
    static func choose(type: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = type == "directory"
        panel.canChooseFiles = type != "directory"
        if type == "texture" {
            panel.allowedContentTypes = [.image]
        }
        // WE's texture property takes a picture or a video (`SceneUserTexture`).
        if type == "scenetexture" {
            panel.allowedContentTypes = [.image, .movie]
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension SceneUserPropertiesModel {
    /// The wallpaper's own properties whose condition holds, in sidebar order, titled with the
    /// label their conditions leave (a script can rewrite one, e.g. "Clock : Disabled" to "Enabled").
    func shownWallpaperProperties() -> [SceneUserProperty] {
        let authored = properties.filter { authoredPropertyIDs.contains($0.id) }
        let scope = UserPropertyConditionScope(values: values,
                                               texts: Dictionary(authored.map { ($0.id, $0.rawText) }) { first, _ in first })
        var shown: [SceneUserProperty] = []
        for property in authored where property.condition.map({ scope.evaluate($0) }) ?? true {
            shown.append(property)
        }
        return shown.map { (property: SceneUserProperty) -> SceneUserProperty in
            guard let text = scope.texts[property.id], text != property.rawText else { return property }
            var retitled = property
            retitled.title = UserPropertyHTML.containsMarkup(text) ? UserPropertyHTML.plainText(text) : text
            return retitled
        }
    }
}
