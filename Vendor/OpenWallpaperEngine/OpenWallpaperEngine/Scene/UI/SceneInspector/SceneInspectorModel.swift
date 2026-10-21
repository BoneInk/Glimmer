import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

/// The inspector's unsaved edits over the store it saves to.
struct SceneInspectorEditBuffer {
    var pending: [String: String]?

    func values(stored: @autoclosure () -> [String: String]) -> [String: String] {
        pending ?? stored()
    }
}

final class SceneInspectorModel: ObservableObject {
    @Published var items: [SceneInspectorItem] = []
    @Published var errorMessage: String?
    @Published var decodedTextures: [SceneInspectorTexture] = []
    @Published var decodedMasks: [String: SceneInspectorTexture] = [:]
    @Published var effectValues: [String: Double] = [:]
    @Published var effectEnabled: [String: Bool] = [:]
    @Published var comboValues: [String: Int] = [:]
    /// Linked vec2 parameters (by `effectID:key`) currently edited as one value.
    @Published var linkedParameters: Set<String> = []
    @Published var decodedItemID: String?
    @Published var loadingItemID: String?
    private(set) var initiallySelectedID: String?
    /// The scene's objects as the Wallpaper Editor's layer list nests them (`SceneOutline.tree()`);
    /// empty for a video, whose layers are described without a scene.json.
    private(set) var objectTree: [SceneOutline.Node] = []
    /// The objects' parents, for dimming what a hidden group hides.
    private var outline: SceneOutline?
    /// The combo properties that switch layers, in project.json's order.
    private(set) var versionProperties: [SceneVersionProperty] = []
    /// Each property's authored value, for the ones the stores don't hold yet.
    private var propertyDefaults: [String: String] = [:]
    /// The size the renderer draws the scene at (`SceneDrawnSize`): the iPhone & iPad and Android
    /// Exports' crops frame the drawn scene, in their previews and their renders alike.
    private(set) var sceneSize = SIMD2<Double>(SceneContentLoader.defaultCanvas)

    private let directory: URL
    private let package: PKGParser?
    /// The stores its edits go to: the selected displays', or the shared one while synced.
    private let targets: WallpaperPropertyTargets
    private var textureLoadGeneration = 0
    private var pendingSave: DispatchWorkItem?
    /// The values handed to the wallpaper but not yet saved (the save is debounced). Reads go
    /// through it, so a control reading the store (Music Amount, Sync to Music) shows its new value
    /// at once, and a second edit inside the debounce doesn't drop the first.
    @Published private var editBuffer = SceneInspectorEditBuffer()
    private var storedValues: [String: String] { editBuffer.values(stored: targets.storedValues) }
    /// Each item's `rawObject` parsed, for the getters every SwiftUI pass calls; an entry serves
    /// only the text it was parsed from, so an edit in the JSON editor is parsed again.
    private var parsedObjects: [String: (raw: String, object: [String: Any]?)] = [:]

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope]) {
        directory = wallpaper.wallpaperDirectory
        targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: scopes)
        let scenePath = wallpaper.project.file
        let packageURL = directory.appending(path: (scenePath as NSString).deletingPathExtension + ".pkg")
        // Most wallpapers have no package: a missing one is quiet.
        package = OWELog.attempt(.ui, "Scene Edit / Export: \(packageURL.lastPathComponent)", quietIfMissing: true) {
            try PKGParser(url: packageURL)
        }
        let directory = directory
        let package = package

        func data(_ path: String) -> Data? {
            Self.assetData(path, package: package, directory: directory)
        }
        func rawJSON(_ path: String) -> String? {
            guard let data = data(path),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            return String(data: formatted, encoding: .utf8)
        }
        guard let sceneData = data(scenePath),
              let scene = OWELog.attempt(.ui, "Scene Edit / Export: \(scenePath)", { try JSONDecoder().decode(WEScene.self, from: sceneData) }),
              let sceneJSON = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any], // decoded just above
              let rawObjects = sceneJSON["objects"] as? [[String: Any]] else {
            if SceneContentLoader.isVideoType(wallpaper.project.type) {
                buildVideoLayers(for: wallpaper)
            } else {
                errorMessage = String(localized: "Unable to read the scene definition.")
            }
            return
        }
        sceneSize = Self.drawnSize(of: sceneData, scene: scene, wallpaper: wallpaper, storedValues: targets.storedValues)
        outline = OWELog.attempt(.ui, "Scene Edit / Export: outline of \(scenePath)") { try SceneOutline(sceneData: sceneData) }
        objectTree = outline?.tree() ?? []

        let storedValues: [String: String] = targets.storedValues
        let definitions = WallpaperEngineShareJSON.definitions(in: directory)
        let labels = WallpaperEngineLabels.load(wallpaperDirectory: directory)
        // Read once per open: scenes repeat the same effects on many layers.
        let effectLabels = WallpaperEngineLabels.load()
        let shaders = SceneInspectorEffectShaders(wallpaperDirectory: directory)
        items = scene.objects.enumerated().map { index, object in
            let objectID = object.id ?? index
            var rawObject = rawObjects.indices.contains(index) ? prettyJSON(rawObjects[index]) : "{}"
            if let origin = storedValues["_owe_scene_object_\(objectID)_origin"] {
                rawObject = Self.rawObject(rawObject, settingOrigin: origin)
            }
            let visibility = SceneObjectVisibilitySwitch(objectID: objectID, property: object.visibleUserProperty,
                                                         authored: object.visible ?? true)
            let visible = visibility.isShown(storedValues)
            let switchedOn = visibility.isOn(storedValues)
            let effects = makeEffects(object.effects ?? [], objectID: objectID, storedValues: storedValues,
                                      labels: effectLabels, shaders: shaders)
            let version = SceneLayerVersion(object: object, definitions: definitions).map { (choice: $0, title: $0.title(labels: labels)) }
            // An empty or blank name is no name ("name": "" in WE's GIF template), as the Wallpaper
            // Editor's list treats it.
            let authoredName = object.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            if let imagePath = object.image {
                let model: WEModel? = data(imagePath).flatMap { Self.decode(WEModel.self, from: $0, path: imagePath) }
                let materialPath = model?.material
                let material: WEMaterial? = materialPath.flatMap { path in data(path).flatMap { Self.decode(WEMaterial.self, from: $0, path: path) } }
                let passes = material?.passes ?? []
                return SceneInspectorItem(id: String(object.id ?? index), name: authoredName ?? String(localized: "Image \(index + 1)", comment: "Scene Edit / Export: an image layer without a name"),
                                          kind: "Image", sourcePath: imagePath, materialPath: materialPath,
                                          texturePaths: passes.flatMap { $0.textures?.compactMap { $0 } ?? [] },
                                          shaderPaths: passes.compactMap(\.shader), rawObject: rawObject,
                                          rawMaterial: materialPath.flatMap(rawJSON), rawParticle: nil,
                                          visible: visible,
                                          version: version, effects: effects,
                                          visibility: visibility, isSwitchedOn: switchedOn)
            }
            if let particlePath = object.particle {
                let particle: WEParticleSystem? = data(particlePath).flatMap { Self.decode(WEParticleSystem.self, from: $0, path: particlePath) }
                let materialPath = particle?.material
                let material: WEMaterial? = materialPath.flatMap { path in data(path).flatMap { Self.decode(WEMaterial.self, from: $0, path: path) } }
                let passes = material?.passes ?? []
                return SceneInspectorItem(id: String(object.id ?? index), name: authoredName ?? String(localized: "Particle \(index + 1)", comment: "Scene Edit / Export: a particle system without a name"),
                                          kind: "Particle", sourcePath: particlePath, materialPath: materialPath,
                                          texturePaths: passes.flatMap { $0.textures?.compactMap { $0 } ?? [] },
                                          shaderPaths: passes.compactMap(\.shader), rawObject: rawObject,
                                          rawMaterial: materialPath.flatMap(rawJSON), rawParticle: rawJSON(particlePath),
                                          visible: visible,
                                          version: version, effects: effects,
                                          visibility: visibility, isSwitchedOn: switchedOn)
            }
            return SceneInspectorItem(id: String(object.id ?? index), name: authoredName ?? String(localized: "Object \(index + 1)", comment: "Scene Edit / Export: a scene object without a name"),
                                      kind: "Other", sourcePath: "", materialPath: nil, texturePaths: [], shaderPaths: [],
                                      rawObject: rawObject, rawMaterial: nil, rawParticle: nil,
                                      visible: visible,
                                      version: version, effects: effects,
                                      visibility: visibility, isSwitchedOn: switchedOn)
        }
        propertyDefaults = definitions.compactMapValues(\.value)
        let versionKeys = Set(items.compactMap { $0.version?.choice.property })
        versionProperties = definitions.values
            .filter { versionKeys.contains($0.key) }
            .sorted { ($0.order ?? .max, $0.key) < ($1.order ?? .max, $1.key) }
            .map { definition in
                let title = { (text: String) in UserPropertyHTML.plainText(labels.translation(text) ?? text) }
                let condition = definition.condition?.trimmingCharacters(in: .whitespaces)
                return SceneVersionProperty(id: definition.key, title: title(definition.text),
                                            options: definition.options.map { ($0.value, title($0.label)) },
                                            condition: condition.flatMap { $0.isEmpty ? nil : UserPropertyConditionExpression($0) })
            }
        // The version the property's current value (else its default) shows.
        initiallySelectedID = items.first { item in
            guard let version = item.version?.choice else { return false }
            return version.value == (storedValues[version.property] ?? definitions[version.property]?.defaultValue)
        }?.id ?? items.first?.id
    }

    /// Wallpaper Engine renders a video through its `scenes/videoplayer` scene, and the Metal path
    /// here does the same: one video layer plus the shared effect stack. There is no scene.json to
    /// read, so those layers are described directly instead of leaving the inspector empty.
    private func buildVideoLayers(for wallpaper: WEWallpaper) {
        let file = wallpaper.project.file
        let url = directory.appending(path: file)
        let syncKeys = ["zoom", "pace", "tilt", "saturation"]
        let enabledSync = syncKeys.filter { VideoMusicSyncSettings.bool(wallpaper, "\($0)Enabled") }

        items = [
            SceneInspectorItem(id: "video", name: String(localized: "Video"), kind: "Video", sourcePath: file,
                               materialPath: nil, texturePaths: [], shaderPaths: [],
                               rawObject: prettyJSON(["file": file, "status": String(localized: "Reading media…")]),
                               rawMaterial: nil, rawParticle: nil, visible: true,
                               version: nil,
                               effects: [], isSynthetic: true),
            SceneInspectorItem(id: "effects", name: String(localized: "Effects"), kind: "Effect Stack", sourcePath: "",
                               materialPath: nil, texturePaths: [], shaderPaths: [],
                               rawObject: prettyJSON([
                                   "musicSync": enabledSync.isEmpty ? "none" : enabledSync.joined(separator: ", "),
                                   "note": String(localized: "Scene effects are toggled under User Scene Settings.")
                               ]),
                               rawMaterial: nil, rawParticle: nil, visible: true,
                               version: nil,
                               effects: [], isSynthetic: true)
        ]
        initiallySelectedID = "video"

        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            // A video AVFoundation can't open logs once; the summary then shows only the file.
            let videoTrack = await OWELog.attemptAsync(.ui, "Scene Edit / Export: \(file)") {
                try await asset.loadTracks(withMediaType: .video).first
            } ?? nil
            // Optional below: a value the movie doesn't carry is left out of the summary.
            let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
            let size = try? await videoTrack?.load(.naturalSize)
            let frameRate = try? await videoTrack?.load(.nominalFrameRate)

            var summary: [String: Any] = ["file": file]
            if let size { summary["resolution"] = "\(Int(size.width)) x \(Int(size.height))" }
            if let duration, duration.isFinite { summary["duration"] = String(format: "%.2f s", duration) }
            if let frameRate { summary["frameRate"] = String(format: "%.2f fps", frameRate) }
            summary["hasAudio"] = audioTrack != nil

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let index = self.items.firstIndex(where: { $0.id == "video" }) {
                    self.items[index].rawObject = prettyJSON(summary)
                }
                guard audioTrack != nil else { return }
                var audioSummary: [String: Any] = ["file": file, "track": "embedded soundtrack"]
                if let duration, duration.isFinite {
                    audioSummary["duration"] = String(format: "%.2f s", duration)
                }
                let audio = SceneInspectorItem(id: "audio", name: String(localized: "Audio"), kind: "Audio", sourcePath: file,
                                               materialPath: nil, texturePaths: [], shaderPaths: [],
                                               rawObject: prettyJSON(audioSummary),
                                               rawMaterial: nil, rawParticle: nil, visible: true,
                                               version: nil,
                                               effects: [], isSynthetic: true)
                self.items.insert(audio, at: 1)
            }
        }
    }

    private func makeEffects(_ effects: [WEObjectEffect], objectID: Int, storedValues: [String: String],
                             labels: WallpaperEngineLabels, shaders: SceneInspectorEffectShaders) -> [SceneInspectorEffect] {
        return effects.enumerated().map { effectIndex, effect in
            let name = ((effect.file as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
            let effectID = "\(objectID):\(effectIndex)"
            let enabledKey = sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: effectIndex)
            effectEnabled[effectID] = storedValues[enabledKey].map { $0.lowercased() != "false" }
                ?? effect.visible.map { $0 != false } ?? true
            // Parameters come from the effect's own shaders, as in WE's editor: its ranges,
            // defaults and labels, nothing widened or renamed.
            let parameters = shaders.parameters(for: effect.file)
            let authored = effect.passes?.first?.constants ?? [:]
            var controls: [SceneInspectorEffectControl] = []
            for parameter in parameters {
                let authoredSource = authored.first { $0.key.caseInsensitiveCompare(parameter.materialKey) == .orderedSame }?
                    .value.valueSource
                // WE's editor shows no value control for a parameter bound to a user property: the
                // user property sets it (`SceneEffectPlanBuilder.applyingOverrides`).
                if authoredSource?.boundUserProperty != nil { continue }
                let authoredValue = authoredSource.flatMap { source -> [Double]? in
                    if case .literal(let value) = source { return value.components.map(Double.init) }
                    return nil
                }
                let baseValues = authoredValue ?? parameter.defaultValue
                let overrideKey = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex,
                                                                  parameter: parameter.materialKey)
                let overrideValues = storedValues[overrideKey].map(SceneVector.numbers)
                let values = overrideValues?.isEmpty == false ? overrideValues! : baseValues
                let title = labels.translation(parameter.label) ?? parameter.title
                let count = parameter.defaultValue.count
                if parameter.isLinked, count == 2, values.count >= 2, values[0] == values[1] {
                    linkedParameters.insert("\(effectID):\(parameter.materialKey)")
                }
                for component in parameter.defaultValue.indices {
                    let controlID = "\(effectID):\(parameter.materialKey):\(component)"
                    let value = values.indices.contains(component) ? values[component] : parameter.defaultValue[component]
                    effectValues[controlID] = value
                    // A colour is one picker, titled as WE titles it.
                    let suffix = count > 1 && !parameter.isColor ? " " + ["X", "Y", "Z", "W"][min(component, 3)] : ""
                    controls.append(SceneInspectorEffectControl(
                        id: controlID, effectID: effectID, key: parameter.materialKey, component: component,
                        title: title + suffix,
                        minimum: parameter.minimum, maximum: parameter.maximum,
                        defaultValue: baseValues.indices.contains(component) ? baseValues[component] : 0,
                        displaysDegrees: false, isInteger: parameter.isInteger, isColor: parameter.isColor,
                        isLinked: parameter.isLinked, componentCount: count))
                }
            }
            let authoredCombos = effect.passes?.first?.combos ?? [:]
            var combos: [SceneInspectorEffectCombo] = []
            for combo in shaders.combos(for: effect.file) where combo.isEditable {
                let comboID = "\(effectID):combo:\(combo.combo)"
                let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: SceneEffectParameters.comboOverrideKey(combo.combo))
                let authoredValue = authoredCombos.first { $0.key.caseInsensitiveCompare(combo.combo) == .orderedSame }?.value
                comboValues[comboID] = storedValues[key].flatMap { Int($0) } ?? authoredValue ?? combo.defaultValue
                combos.append(SceneInspectorEffectCombo(
                    id: comboID, effectID: effectID, combo: combo.combo,
                    title: labels.translation(combo.label) ?? SceneEffectParameters.title(combo.label),
                    options: combo.options.map { option in
                        (labels.translation(option.label) ?? option.english ?? SceneEffectParameters.title(option.label),
                         option.value, option.group.map { labels.translation($0) ?? Self.groupTitle($0) })
                    },
                    requirements: combo.requirements))
            }
            let maskPath = effect.passes?.first?.textures?.compactMap { $0 }.first
            return SceneInspectorEffect(id: effectID, name: name,
                                        title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                                        maskPath: maskPath, controls: controls, combos: combos)
        }
    }

    /// A blend-mode group heading without WE's translation table: its English text.
    private static func groupTitle(_ key: String) -> String {
        SceneBlendModeOptions.groupTitle(key)
    }

    func setEffectValue(_ value: Double, control: SceneInspectorEffectControl) {
        effectValues[control.id] = value
        // A linked vec2 moves both components together, as WE's linked slider does.
        if control.isLinked, linkedParameters.contains("\(control.effectID):\(control.key)") {
            for component in 0..<control.componentCount {
                effectValues["\(control.effectID):\(control.key):\(component)"] = value
            }
        }
        let prefix = "\(control.effectID):\(control.key):"
        let components = effectValues.keys.filter { $0.hasPrefix(prefix) }
            .sorted { (Int($0.split(separator: ":").last!) ?? 0) < (Int($1.split(separator: ":").last!) ?? 0) }
            .compactMap { effectValues[$0] }
        let parts = control.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex,
                                                 parameter: control.key)
        var values = storedValues
        values[key] = components.map { String($0) }.joined(separator: " ")
        persist(values)
    }

    func isLinked(_ control: SceneInspectorEffectControl) -> Bool {
        linkedParameters.contains("\(control.effectID):\(control.key)")
    }

    /// WE's link toggle: linking copies X into Y.
    func setLinked(_ linked: Bool, control: SceneInspectorEffectControl) {
        let id = "\(control.effectID):\(control.key)"
        if linked {
            linkedParameters.insert(id)
            setEffectValue(effectValues["\(id):0"] ?? control.defaultValue, control: control)
        } else {
            linkedParameters.remove(id)
        }
    }

    /// WE shows a combo only while the combos it `require`s have those values.
    func requirementsHold(_ combo: SceneInspectorEffectCombo, in effect: SceneInspectorEffect) -> Bool {
        combo.requirements.allSatisfy { name, value in
            effect.combos.first { $0.combo == name }.map { comboValue($0) == value } ?? true
        }
    }

    func comboValue(_ combo: SceneInspectorEffectCombo) -> Int {
        comboValues[combo.id] ?? 0
    }

    func setComboValue(_ value: Int, combo: SceneInspectorEffectCombo) {
        comboValues[combo.id] = value
        let parts = combo.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: SceneEffectParameters.comboOverrideKey(combo.combo))
        var values = storedValues
        values[key] = String(value)
        persist(values)
    }

    func displayedEffectValue(for control: SceneInspectorEffectControl) -> Double {
        let value = effectValues[control.id] ?? control.defaultValue
        return control.displaysDegrees ? value * 180 / .pi : value
    }

    func effectColor(for control: SceneInspectorEffectControl) -> Color {
        let prefix = "\(control.effectID):\(control.key):"
        let values = effectValues.keys.filter { $0.hasPrefix(prefix) }.sorted().compactMap { effectValues[$0] }
        // WE's colour uniforms are normalised 0...1.
        return Color(red: values.indices.contains(0) ? values[0] : 1,
                     green: values.indices.contains(1) ? values[1] : 1,
                     blue: values.indices.contains(2) ? values[2] : 1)
    }

    func setEffectColor(_ color: Color, control: SceneInspectorEffectControl) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let rgb = [nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent]
        let prefix = "\(control.effectID):\(control.key):"
        for (index, id) in effectValues.keys.filter({ $0.hasPrefix(prefix) }).sorted().enumerated() where index < 3 {
            effectValues[id] = rgb[index]
        }
        let parts = control.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: control.key)
        var values = storedValues
        values[key] = rgb.map(String.init).joined(separator: " ")
        persist(values)
    }

    func setDisplayedEffectValue(_ value: Double, control: SceneInspectorEffectControl) {
        setEffectValue(control.displaysDegrees ? value * .pi / 180 : value, control: control)
    }

    func musicSyncEnabled(for control: SceneInspectorEffectControl) -> Bool {
        let key = musicSyncKey(for: control)
        let values = storedValues
        return (values[key] ?? "false").lowercased() == "true"
    }

    func setMusicSyncEnabled(_ enabled: Bool, for control: SceneInspectorEffectControl) {
        var values = storedValues
        values[musicSyncKey(for: control)] = enabled ? "true" : "false"
        if values[musicAmountKey(for: control)] == nil {
            values[musicAmountKey(for: control)] = "0"
        }
        persist(values)
    }

    func musicAmount(for control: SceneInspectorEffectControl) -> Double {
        let values = storedValues
        let raw = Double(values[musicAmountKey(for: control)] ?? "0") ?? 0
        return control.displaysDegrees ? raw * 180 / .pi : raw
    }

    func setMusicAmount(_ amount: Double, for control: SceneInspectorEffectControl) {
        var values = storedValues
        values[musicAmountKey(for: control)] = String(control.displaysDegrees ? amount * .pi / 180 : amount)
        persist(values)
    }

    private func overrideKey(for control: SceneInspectorEffectControl) -> String? {
        let parts = control.effectID.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return nil }
        let key = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: control.key)
        let prefix = "\(control.effectID):\(control.key):"
        let componentCount = effectValues.keys.filter { $0.hasPrefix(prefix) }.count
        return componentCount > 1 ? "\(key)_\(control.component)" : key
    }

    private func musicSyncKey(for control: SceneInspectorEffectControl) -> String {
        "\(overrideKey(for: control) ?? control.id)_musicSync"
    }

    private func musicAmountKey(for control: SceneInspectorEffectControl) -> String {
        "\(overrideKey(for: control) ?? control.id)_musicAmount"
    }

    func setEffectEnabled(_ enabled: Bool, effect: SceneInspectorEffect) {
        effectEnabled[effect.id] = enabled
        let parts = effect.id.split(separator: ":")
        guard parts.count == 2, let objectID = Int(parts[0]), let effectIndex = Int(parts[1]) else { return }
        let key = sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: effectIndex)
        var values = storedValues
        values[key] = enabled ? "true" : "false"
        persist(values)
    }

    /// The object's switch (`SceneObjectVisibilitySwitch`): on an object a user property shows,
    /// off hides it whatever the property says and on hands it back to the property.
    func setObjectVisible(_ on: Bool, item: SceneInspectorItem) {
        let visibility = item.visibility
            ?? SceneObjectVisibilitySwitch(objectID: Int(item.id) ?? 0, property: nil, authored: item.visible)
        let values = visibility.values(storedValues, settingOn: on)
        // A dropped key must leave the running stores too.
        persist(values, replacing: values[visibility.key] == nil)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].visible = visibility.isShown(values)
            items[index].isSwitchedOn = visibility.isOn(values)
        }
    }

    func origin(for item: SceneInspectorItem) -> SIMD3<Double> {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let object = parsedObject(items[index]) else {
            return SIMD3<Double>(0, 0, 0)
        }
        return Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
    }

    func moveObject(_ item: SceneInspectorItem, deltaX: Double, deltaY: Double) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        let current = Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let updated = SIMD3<Double>(current.x + deltaX, current.y + deltaY, current.z)
        setObjectOrigin(item, index: index, object: &object, origin: updated)
    }

    func alignObject(_ item: SceneInspectorItem, horizontal: SceneHorizontalSnap) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        let current = Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let size = Self.parseSize(object["size"]) ?? SIMD2<Double>(300, 120)
        let x: Double
        switch horizontal {
        case .left:
            x = size.x / 2
        case .center:
            x = sceneSize.x / 2
        case .right:
            x = sceneSize.x - size.x / 2
        }
        setObjectOrigin(item, index: index, object: &object, origin: SIMD3<Double>(x, current.y, current.z))
    }

    func alignObject(_ item: SceneInspectorItem, vertical: SceneVerticalSnap) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        let current = Self.parseOrigin(object["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let size = Self.parseSize(object["size"]) ?? SIMD2<Double>(300, 120)
        let y: Double
        switch vertical {
        case .top:
            y = sceneSize.y - size.y / 2
        case .center:
            y = sceneSize.y / 2
        case .bottom:
            y = size.y / 2
        }
        setObjectOrigin(item, index: index, object: &object, origin: SIMD3<Double>(current.x, y, current.z))
    }

    private func setObjectOrigin(_ item: SceneInspectorItem, index: Int, object: inout [String: Any], origin updated: SIMD3<Double>) {
        let origin = Self.originString(updated)
        object["origin"] = origin
        items[index].rawObject = prettyJSON(object)
        var values = storedValues
        values["_owe_scene_object_\(item.id)_origin"] = origin
        persist(values)
    }

    func scale(for item: SceneInspectorItem) -> Double {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let object = parsedObject(items[index]),
              let parsed = Self.parseOrigin(object["scale"]) else {
            return 1
        }
        return parsed.x == 0 ? 1 : parsed.x
    }

    func setObjectScale(_ item: SceneInspectorItem, scale value: Double) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        let current = Self.parseOrigin(object["scale"]) ?? SIMD3<Double>(1, 1, 1)
        // Scaling uniformly keeps the object's aspect, and the renderer scales each effect's mask
        // with the layer it belongs to, so masks follow along.
        let updated = SIMD3<Double>(value, value, current.z == 0 ? 1 : current.z)
        let scale = Self.originString(updated)
        object["scale"] = scale
        items[index].rawObject = prettyJSON(object)
        var values = storedValues
        values["_owe_scene_object_\(item.id)_scale"] = scale
        persist(values)
    }

    /// The scene as the renderer draws it, its saved overlay and edits applied; the authored
    /// scene's size when those can't be applied (logged).
    private static func drawnSize(of sceneData: Data, scene: WEScene, wallpaper: WEWallpaper,
                                  storedValues: [String: String]) -> SIMD2<Double> {
        do {
            return try SceneDrawnSize.of(sceneData: sceneData, overlay: SceneDrawnSize.savedOverlay(of: wallpaper),
                                         edits: ScenePreparation.split(storedValues: storedValues).edits,
                                         readAsset: SceneImageSize.reader(for: wallpaper))
        } catch {
            OWELog.error(.ui, "Scene Edit / Export: no drawn size for \(wallpaper.wallpaperDirectory.lastPathComponent), framing the authored scene: \(error)")
            let read = SceneImageSize.reader(for: wallpaper)
            return SIMD2<Double>(SceneContentLoader.sceneSize(of: scene) { SceneImageSize.of(model: $0, readAsset: read) })
        }
    }

    private static func rawObject(_ rawObject: String, settingOrigin origin: String) -> String {
        guard let data = rawObject.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return rawObject }
        object["origin"] = origin
          guard let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return rawObject }
          return String(data: formatted, encoding: .utf8) ?? rawObject
    }

    private static func parseOrigin(_ value: Any?) -> SIMD3<Double>? {
        if let string = value as? String {
            let parts = SceneVector.numbers(string)
            guard parts.count >= 2 else { return nil }
            return SIMD3<Double>(parts[0], parts[1], parts.indices.contains(2) ? parts[2] : 0)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
            guard parts.count >= 2 else { return nil }
            return SIMD3<Double>(parts[0], parts[1], parts.indices.contains(2) ? parts[2] : 0)
        }
        if let dict = value as? [String: Any] {
            let x = (dict["x"] as? NSNumber)?.doubleValue ?? dict["x"] as? Double
            let y = (dict["y"] as? NSNumber)?.doubleValue ?? dict["y"] as? Double
            let z = (dict["z"] as? NSNumber)?.doubleValue ?? dict["z"] as? Double ?? 0
            if let x, let y { return SIMD3<Double>(x, y, z) }
        }
        return nil
    }

    private static func parseSize(_ value: Any?) -> SIMD2<Double>? {
        if let string = value as? String {
            let parts = SceneVector.numbers(string)
            guard parts.count >= 2 else { return nil }
            return SIMD2<Double>(parts[0], parts[1])
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
            guard parts.count >= 2 else { return nil }
            return SIMD2<Double>(parts[0], parts[1])
        }
        if let dict = value as? [String: Any] {
            let x = (dict["x"] as? NSNumber)?.doubleValue ?? dict["x"] as? Double
            let y = (dict["y"] as? NSNumber)?.doubleValue ?? dict["y"] as? Double
            if let x, let y { return SIMD2<Double>(x, y) }
        }
        return nil
    }

    private static func originString(_ origin: SIMD3<Double>) -> String {
        let components: [Double] = [origin.x, origin.y, origin.z]
        let parts: [String] = components.map { value -> String in
            value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        }
        return parts.joined(separator: " ")
    }

    /// An image layer's `alpha` (WE's default 1); nil while something else sets it (a user
    /// property, a script or an animation), which WE's editor shows no value for either.
    func alpha(for item: SceneInspectorItem) -> Double? {
        guard let object = parsedObject(item) else { return 1 } // not an object: WE's default
        switch object["alpha"] {
        case nil: return 1
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Sets an image layer's `alpha`, saved with the object's edited JSON.
    func setAlpha(_ value: Double, for item: SceneInspectorItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        object["alpha"] = min(max(value, 0), 1)
        saveObject(object, item: items[index])
    }

    /// An image layer's `color` (WE's default white); nil while something else sets it.
    func color(for item: SceneInspectorItem) -> SIMD3<Double>? {
        guard let object = parsedObject(item) else { return SIMD3(1, 1, 1) } // WE's default
        guard let value = object["color"] else { return SIMD3(1, 1, 1) }
        guard !(value is [String: Any]), let parsed = Self.parseOrigin(value) else { return nil }
        return parsed
    }

    /// Sets an image layer's `color`, saved with the object's edited JSON.
    func setColor(_ color: Color, for item: SceneInspectorItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let components: [Double] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Double($0) }
        object["color"] = components.map { String(format: "%.5g", $0) }.joined(separator: " ")
        saveObject(object, item: items[index])
    }

    /// An image layer's `colorBlendMode` (WE's default 0, Normal).
    func blendMode(for item: SceneInspectorItem) -> Int {
        guard let object = parsedObject(item) else { return 0 } // not an object: Normal
        return (object["colorBlendMode"] as? NSNumber)?.intValue ?? 0
    }

    /// Sets an image layer's `colorBlendMode`, saved with the object's edited JSON.
    func setBlendMode(_ value: Int, for item: SceneInspectorItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              var object = parsedObject(items[index]) else { return }
        object["colorBlendMode"] = value
        saveObject(object, item: items[index])
    }

    /// The material blendings a layer offers: its kind's (`WEMaterialBlending`); none for a layer
    /// without a material of its own.
    static func blendingOptions(for item: SceneInspectorItem) -> [WEMaterialBlending] {
        guard !item.isSynthetic, item.materialPath != nil, Int(item.id) != nil else { return [] }
        switch item.kind {
        case "Image": return WEMaterialBlending.imageLayer
        case "Particle": return WEMaterialBlending.particleSystem
        default: return []
        }
    }

    /// The blending of the layer's material as the scene loads it: its first pass's, with the
    /// material's own edit (`saveAssetJSON`) when it has one.
    func authoredBlending(for item: SceneInspectorItem) -> WEMaterialBlending {
        let particle = item.kind == "Particle"
        let raw = item.materialPath.flatMap { storedValues[sceneAssetOverrideKey(path: $0)] } ?? item.rawMaterial
        guard let data = raw?.data(using: .utf8),
              let material = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // no material: its default
              let pass = (material["passes"] as? [[String: Any]])?.first else {
            return WEMaterialBlending.authored(nil, particle: particle)
        }
        return WEMaterialBlending.authored(pass["blending"] as? String, particle: particle)
    }

    /// The blending the layer draws with: the one set here, else its material's.
    func materialBlending(for item: SceneInspectorItem) -> WEMaterialBlending {
        guard let objectID = Int(item.id),
              let value = storedValues[sceneObjectBlendingKey(objectID: objectID)],
              let blending = WEMaterialBlending(authored: value),
              Self.blendingOptions(for: item).contains(blending) else { return authoredBlending(for: item) }
        return blending
    }

    /// Draws the layer's material with `blending`, applied live (the content is rebuilt, the
    /// scene isn't reloaded) and saved with the other edits.
    func setMaterialBlending(_ blending: WEMaterialBlending, for item: SceneInspectorItem) {
        guard let objectID = Int(item.id), Self.blendingOptions(for: item).contains(blending) else { return }
        var values = storedValues
        values[sceneObjectBlendingKey(objectID: objectID)] = blending.rawValue
        persist(values)
    }

    /// Back to the material's own blending: the edit is removed, so the layer no longer counts as
    /// edited, and the running wallpaper's store is replaced so it drops the key too.
    func resetMaterialBlending(for item: SceneInspectorItem) {
        guard let objectID = Int(item.id) else { return }
        var values = storedValues
        guard values.removeValue(forKey: sceneObjectBlendingKey(objectID: objectID)) != nil else { return }
        objectWillChange.send()
        persist(values, replacing: true)
    }

    /// WE's blend modes as its editor lists them (`WEImageBlendModes`), with WE's labels.
    lazy var blendModeCombo: SceneInspectorEffectCombo = {
        // Shared with the Wallpaper Editor (`SceneBlendModeOptions`).
        let labels = WallpaperEngineLabels.load()
        return SceneInspectorEffectCombo(
            id: "colorBlendMode", effectID: "", combo: "BLENDMODE",
            title: SceneBlendModeOptions.title(labels: labels),
            options: SceneBlendModeOptions.options(labels: labels).map { (title: $0.title, value: $0.value, group: $0.group) })
    }()

    /// Saves the layer's object as edited in the JSON editor. Throws, saving nothing, when the
    /// text isn't a JSON object.
    func saveObjectJSON(_ text: String, item: SceneInspectorItem) throws {
        saveObject(try Self.jsonObject(text), item: item)
    }

    /// Saves the layer's object (a field edited in the inspector).
    private func saveObject(_ object: [String: Any], item: SceneInspectorItem) {
        let formatted = prettyJSON(object)
        var values = storedValues
        values["_owe_scene_object_\(item.id)_json"] = formatted
        persist(values)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].rawObject = formatted
        }
    }

    /// Saves a material or particle as edited in the JSON editor. Throws, saving nothing, when the
    /// text isn't a JSON object.
    func saveAssetJSON(_ text: String, path: String) throws {
        let object = try Self.jsonObject(text)
        var values = storedValues
        values[sceneAssetOverrideKey(path: path)] = prettyJSON(object)
        persist(values)
    }

    /// Why a JSON editor's text can't be saved.
    enum InvalidJSON: LocalizedError {
        /// The text doesn't parse; the parser's reason.
        case unparseable(String)
        /// It parses, but to something other than an object.
        case notAnObject

        var errorDescription: String? {
            switch self {
            case .unparseable(let reason):
                return String(localized: "This isn't valid JSON: \(reason)",
                              comment: "Scene Edit / Export: Save in a JSON editor whose text doesn't parse; the argument is the parser's reason")
            case .notAnObject:
                return String(localized: "This is valid JSON, but not an object in braces { }.",
                              comment: "Scene Edit / Export: Save in a JSON editor whose text is an array, string or number")
            }
        }
    }

    /// `text` as a JSON object, or why it isn't one.
    static func jsonObject(_ text: String) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            throw InvalidJSON.unparseable((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
        guard let object = parsed as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw InvalidJSON.notAnObject
        }
        return object
    }

    func useVersion(_ item: SceneInspectorItem) {
        guard let version = item.version?.choice else { return }
        setProperty(version.property, to: version.value)
    }

    /// A property's current value: the stores', else the authored one.
    func propertyValue(_ key: String) -> String {
        storedValues[key] ?? propertyDefaults[key] ?? ""
    }

    func setProperty(_ key: String, to value: String) {
        var values = storedValues
        values[key] = value
        persist(values)
    }

    /// The Versions rows whose property shows for the current values (its `condition`), as in WE's
    /// properties sidebar: a wallpaper with a copy of the property per language shows only the
    /// language's.
    var shownVersionProperties: [SceneVersionProperty] {
        let values = propertyDefaults.merging(storedValues) { $1 }
        return versionProperties.filter { $0.condition?.evaluate(values) ?? true }
    }

    /// A parent (or its parent…) is hidden, which hides the object too (WE's visibility chain,
    /// wallpaper64.exe 0x140185010); its own switch stays as it is.
    func isHiddenByParent(_ item: SceneInspectorItem) -> Bool {
        guard let id = Int(item.id), let outline else { return false }
        return outline.ancestors(of: id).contains { parent in
            items.first { $0.id == String(parent.id) }.map { !$0.visible } ?? false
        }
    }

    /// "Clock Location: Middle" under a layer that one option of a Versions property shows.
    func versionCaption(_ item: SceneInspectorItem) -> String? {
        guard let version = item.version else { return nil }
        let property = versionProperties.first { $0.id == version.choice.property }
        return property.map { "\($0.title): \(version.title)" } ?? version.title
    }

    func loadTextures(for item: SceneInspectorItem) {
        textureLoadGeneration &+= 1
        let generation = textureLoadGeneration
        decodedTextures = []
        decodedMasks = [:]
        decodedItemID = nil
        guard !item.texturePaths.isEmpty else {
            loadingItemID = nil
            decodedItemID = item.id
            return
        }
        loadingItemID = item.id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let textures = self.decodeTextures(for: item)
            let masks = Dictionary(uniqueKeysWithValues: item.effects.compactMap { effect -> (String, SceneInspectorTexture)? in
                guard let path = effect.maskPath, let texture = self.decodeTexture(path, itemID: effect.id,
                                                                                   materialPath: "materials") else { return nil }
                return (effect.id, texture)
            })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textureLoadGeneration == generation else { return }
                self.decodedTextures = textures
                self.decodedMasks = masks
                self.decodedItemID = item.id
                self.loadingItemID = nil
            }
        }
    }

    private func decodeTextures(for item: SceneInspectorItem) -> [SceneInspectorTexture] {
        item.texturePaths.compactMap { decodeTexture($0, itemID: item.id, materialPath: item.materialPath) }
    }

    private func decodeTexture(_ textureName: String, itemID: String, materialPath: String?) -> SceneInspectorTexture? {
        let materialDirectory = ((materialPath ?? "") as NSString).deletingLastPathComponent
        let fileName = (textureName as NSString).pathExtension.isEmpty ? "\(textureName).tex" : textureName
        let candidates = ["\(materialDirectory)/\(fileName)", "materials/\(fileName)", fileName]
            .filter { !$0.hasPrefix("/") }
        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            guard let bytes = data(path) else { continue }
            let parser = TEXParser(data: bytes)
            let image = parser.extractAnimatedImages()?.images.first ?? parser.extractImage() ?? NSImage(data: bytes)
            if let image { return SceneInspectorTexture(id: "\(itemID):\(path)", path: path, image: image) }
        }
        return nil
    }

    /// `item.rawObject` as an object, parsed once per text (`parsedObjects`); nil when it isn't one.
    private func parsedObject(_ item: SceneInspectorItem) -> [String: Any]? {
        if let cached = parsedObjects[item.id], cached.raw == item.rawObject { return cached.object }
        // Optional: text that isn't a JSON object has no fields to show (the JSON editor shows it).
        let object = item.rawObject.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        parsedObjects[item.id] = (item.rawObject, object)
        return object
    }

    private func data(_ path: String) -> Data? {
        Self.assetData(path, package: package, directory: directory)
    }

    /// The bytes of `path` in the package or the folder; nil when neither has it. The inspector
    /// shows an unreadable file as a missing one, after logging why it couldn't be read.
    private static func assetData(_ path: String, package: PKGParser?, directory: URL) -> Data? {
        if let data = package?.extractFile(named: path) { return data }
        return OWELog.attempt(.ui, "Scene Edit / Export: \(path)") { try AssetPathResolver.data(path, in: directory) } ?? nil
    }

    /// `data` decoded as `type`; nil, after one log line, when `path` isn't one (the layer then
    /// shows without its model, material or particle details).
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) -> T? {
        OWELog.attempt(.ui, "Scene Edit / Export: \(path)") { try JSONDecoder().decode(type, from: data) }
    }

    private func prettyJSON(_ json: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Drops every edit made here to the wallpaper, in every store it edits (its Reset Edits);
    /// the wallpaper's properties stay.
    func removeEdits() {
        pendingSave?.cancel()
        pendingSave = nil
        editBuffer = SceneInspectorEditBuffer()
        targets.removeSceneInspectorEdits()
    }

    /// `replacing`: the running stores take `values` whole, so a removed key is dropped there too.
    private func persist(_ values: [String: String], replacing: Bool = false) {
        editBuffer.pending = values
        if replacing {
            for key in targets.runtimeKeys { WallpaperPropertyTargets.publishReplacing(key, values) }
        } else {
            targets.publish(values)
        }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self, targets] in
            targets.save(values)
            self?.editBuffer.pending = nil
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
