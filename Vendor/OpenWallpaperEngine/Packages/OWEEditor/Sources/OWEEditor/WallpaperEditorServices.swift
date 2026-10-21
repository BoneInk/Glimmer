import CoreGraphics
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// What the editor needs from the app: the live scene drawn by the app's own renderer, and the
/// pieces of Scene Edit / Export it shows again (the user properties, WE's blend modes and effect
/// help), so the two never disagree.
public struct WallpaperEditorServices {
    /// The live wallpaper, drawn by the app's renderer at the size it is given. Made once.
    public var makeCanvas: () -> AnyView
    /// The wallpaper's user properties, as the Details panel shows them; nil hides the section.
    public var userProperties: (() -> AnyView)?
    /// The Blend Mode picker's title and WE's modes, as Scene Edit / Export lists them.
    public var blendModeTitle: String
    public var blendModes: [InspectorOption]
    /// Help for an effect, by its folder name (`waterripple`).
    public var effectHelp: (String) -> String
    /// The title a new wallpaper saved with the edits gets unless the user changes it.
    public var suggestedNewTitle: String
    /// Save as New Wallpaper: writes a new local wallpaper with the edits baked in and adds it to
    /// the library, leaving the wallpaper edited as it is; returns the title it was saved under.
    public var saveAsNewWallpaper: (String) throws -> String
    /// The window's timeline (editor-plan notes P4); nil shows none.
    public var timeline: SceneTimelineEditor?

    // MARK: Adding and editing (phases 2–3)

    /// The effects the editor can add: WE's built-in ones and the Workshop effects the wallpaper uses.
    public var effectCatalog: () -> [EffectCatalogEntry] = { [] }
    /// Makes an effect ready to add: WE's editor copies a built-in effect's materials, shaders and
    /// textures into the project (WE only reads them there), which the app does into the edits' files.
    public var prepareEffect: (EffectCatalogEntry) throws -> Void = { _ in }
    /// What an effect (`effects/…/effect.json`) lets the editor change, from its shaders.
    public var effectSchema: (String) -> EffectSchema? = { _ in nil }
    /// Where imported files and painted masks go; nil when the editor can't add files.
    public var assetStore: EditorAssetStore?
    /// The wallpaper's own files the asset browser lists (textures, models, sounds, fonts).
    public var wallpaperAssets: () -> [EditorAsset] = { [] }
    /// A texture's picture (`masks/…`, `editor/…`, a wallpaper's texture), for previews and for
    /// painting over an existing mask; nil when it can't be read.
    public var texture: (String) -> CGImage? = { _ in nil }
    /// Fonts a text layer can use: WE's, the wallpaper's, imported ones.
    public var fonts: () -> [EditorFont] = { [] }
    /// A file of the scene as the loader finds it (the wallpaper's, the editor's, WE's), by path.
    public var readFile: (String) -> Data? = { _ in nil }
    /// What else names the editor's files besides the draft (the saved edits, the scene), for
    /// Clean Project.
    public var projectReferences: () -> [Data] = { [] }
    /// The wallpaper's SceneScript `localStorage`, for Clean Local Storage; nil leaves it out.
    public var localStorage: EditorLocalStorage?
    /// Where Edit with External Image Editor keeps the pictures it hands out, and the editor's
    /// defaults (the chosen app); nil leaves it out.
    public var externalEditing: ExternalImageEditing?
    /// The wallpaper's user properties a value can be bound to (key, title), with their type.
    public var userPropertyChoices: () -> [EditorUserPropertyChoice] = { [] }
    /// The canvas's user property values (the Details panel's), which a texture variant's
    /// Preview switches; nil leaves Preview out.
    public var userPropertyValues: EditorUserPropertyValues?

    /// The wallpaper's project.json as it ships, whose `general.properties` the user-property
    /// editor starts from; nil hides the editor.
    public var projectJSON: Data?
    /// A file as the scene reads it (the wallpaper's, else WE's assets): an image layer's model
    /// and material for Lighting & Reflections.
    public var readAsset: (String) -> Data? = { _ in nil }
    /// What the wallpaper's running scripts log and the errors they raise; nil when the app
    /// doesn't report them.
    public var scriptConsole: SceneScriptConsoleFeed?
    /// The wallpaper's files and images the puppet editor reads; nil hides Puppet Warp.
    public var puppetAssets: PuppetEditorAssets?
    /// The particle editor (WE's presets and textures, restarting a system); nil leaves it out.
    public var particles: ParticleEditorServices?
    /// The app menu's document actions for this window; nil when only the toolbar offers them.
    public var commands: WallpaperEditorCommands?
    /// The draft's state, File › Save and Revert to Saved; nil leaves Save and Revert out.
    public var document: WallpaperEditorDocument?
    /// Depth maps for depth parallax (the Depth Map Generation plugin); nil leaves the sections out.
    public var depthMaps: DepthMapEditorServices?
    /// The effect and particle browsers' rendered previews; nil shows each one's group symbol.
    public var previews: EditorPreviewProvider?
    /// Whether WE's assets are installed: the browsers list WE's effects and particle systems.
    public var hasWEAssets: () -> Bool = { true }
    /// Opens the app's setup of WE's assets (Settings › Assets).
    public var openAssetsSetup: () -> Void = {}
    /// Take Snapshot and Record GIF: the library thumbnail made from the canvas; nil leaves them out.
    public var thumbnail: EditorThumbnail?
    /// A 3D scene's camera as the canvas's renderer drew its last frame, for the 3D gizmo; nil
    /// in a 2D scene or before the scene has drawn.
    public var sceneCamera: () -> EditorSceneCamera? = { nil }
    /// Caps the canvas's frame rate (Low FPS Simulation), nil for none.
    /// The puppets' hit boxes as the canvas's renderer posed them last frame (Show Hitboxes).
    public var puppetHitBoxes: () -> [EditorHitBox] = { [] }
    public var setCanvasFrameRateCap: (Int?) -> Void = { _ in }
    /// The canvas renderer's frame statistics for the stats overlay; nil leaves the overlay out.
    public var renderStats: RenderStatsFeed?
    /// The 3D models Add Layer › Model offers (`models/…/….mdl`): the wallpaper's own, then WE's.
    public var models: () -> [EditorModelChoice] = { [] }
    /// WE's presets that add other layers than particle systems (Clock, Countdown, Light Shafts),
    /// for Add Layer › Preset; empty without WE's assets.
    public var layerPresets: () -> [ParticlePreset] = { [] }
    /// The shader editor's translator and WE's snippets; nil edits shaders without checking them.
    public var shaders: ShaderEditorServices?

    // MARK: Script editor

    /// WE's own snippet script by its file name (`ui/dist/monaco/snippets/<name>.js` of the user's
    /// WE copy, as WE's editor reads it); nil when it has none, and the editor's own is used.
    public var scriptSnippet: (String) -> String? = { _ in nil }
    /// The modules a script can import besides WE's base ones: the other files of WE's
    /// `scripts/jsmodules`, which the runtime resolves the same way.
    public var customScriptModules: () -> [String] = { [] }
    /// Run Preview / Stop Preview: whether the canvas runs the wallpaper's scripts; nil leaves the
    /// toggle out.
    public var setScriptsRunning: ((Bool) -> Void)?
    /// Where the editor keeps its own choices (the console's Clear Log on Run and Auto Scroll).
    public var preferences: UserDefaults = .standard

    public init(makeCanvas: @escaping () -> AnyView, userProperties: (() -> AnyView)? = nil,
                blendModeTitle: String, blendModes: [InspectorOption], effectHelp: @escaping (String) -> String,
                suggestedNewTitle: String, saveAsNewWallpaper: @escaping (String) throws -> String,
                projectJSON: Data? = nil, scriptConsole: SceneScriptConsoleFeed? = nil) {
        self.makeCanvas = makeCanvas
        self.userProperties = userProperties
        self.blendModeTitle = blendModeTitle
        self.blendModes = blendModes
        self.effectHelp = effectHelp
        self.suggestedNewTitle = suggestedNewTitle
        self.saveAsNewWallpaper = saveAsNewWallpaper
        self.projectJSON = projectJSON
        self.scriptConsole = scriptConsole
    }
}

/// A file the asset browser lists.
public struct EditorAsset: Hashable, Identifiable, Sendable {
    /// WE's asset folders (Materials, Models, Particles, Sounds), textures and fonts apart.
    public enum Kind: String, CaseIterable, Sendable {
        case texture, material, model, particle, sound, font, other
    }

    /// Its path in the scene (`materials/foo.tex`, `models/foo.json`).
    public var path: String
    public var kind: Kind
    /// Imported in the editor rather than shipped by the wallpaper.
    public var isImported: Bool

    public var id: String { path }

    public init(path: String, kind: Kind, isImported: Bool = false) {
        self.path = path
        self.kind = kind
        self.isImported = isImported
    }

    /// Its kind by its path, as WE lays a wallpaper's folder out.
    public static func kind(of path: String) -> Kind {
        let lowered = path.lowercased()
        let fileExtension = (lowered as NSString).pathExtension
        if ["tex", "png", "jpg", "jpeg", "gif"].contains(fileExtension), lowered.hasPrefix("materials/") { return .texture }
        if fileExtension == "json", lowered.hasPrefix("models/") { return .model }
        if fileExtension == "json", lowered.hasPrefix("materials/") { return .material }
        if fileExtension == "json", lowered.hasPrefix("particles/") { return .particle }
        if EditorAssetStore.soundTypes.contains(fileExtension) { return .sound }
        if EditorAssetStore.fontTypes.contains(fileExtension) { return .font }
        return .other
    }

    /// The texture name a material or effect slot uses for it (`materials/foo.tex` → `foo`).
    public var textureName: String? {
        guard kind == .texture, path.lowercased().hasPrefix("materials/") else { return nil }
        return ((path as NSString).deletingPathExtension as NSString).substring(from: "materials/".count)
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// A font a text layer can use: its `font` value and a name to show.
public struct EditorFont: Hashable, Identifiable, Sendable {
    public var value: String
    public var title: String
    public var id: String { value }

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

extension WallpaperEditorServices {
    /// A user property's label as the property panels show it: the app's title for it (WE's
    /// translation of a localisation key, HTML dropped; `userPropertyChoices`), else the label of
    /// one the editor added (`properties`), else its key.
    func userPropertyTitle(_ key: String, properties: [UserPropertyDraft]? = nil) -> String {
        if let choice = userPropertyChoices().first(where: { $0.key == key }) { return choice.title }
        if let draft = properties?.first(where: { $0.key == key }) { return PropertyTitle.title(draft) }
        return key
    }
}

/// The values the canvas runs the wallpaper's user properties with (the editor's draft).
public struct EditorUserPropertyValues {
    /// A property's value; nil when it has none set (its default applies).
    public var value: (String) -> String?
    /// Sets a property's value, as the Details panel does (undoable there).
    public var set: (String, String) -> Void

    public init(value: @escaping (String) -> String?, set: @escaping (String, String) -> Void) {
        self.value = value
        self.set = set
    }
}

/// A user property a value can follow.
public struct EditorUserPropertyChoice: Hashable, Identifiable, Sendable {
    public var key: String
    public var title: String
    /// WE's type (`slider`, `color`, `bool`, `combo`, …).
    public var type: String

    public var id: String { key }

    public init(key: String, title: String, type: String) {
        self.key = key
        self.title = title
        self.type = type
    }
}

/// A 3D model Add Layer › Model can draw.
public struct EditorModelChoice: Hashable, Identifiable, Sendable {
    /// Its path in the scene (`models/tree/tree.mdl`), the layer's `model`.
    public var path: String
    /// From WE's assets rather than the wallpaper.
    public var isShared: Bool
    public var id: String { path }

    public init(path: String, isShared: Bool) {
        self.path = path
        self.isShared = isShared
    }

    /// The file's name without its extension, for the layer's name.
    public var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// The wallpaper's SceneScript `localStorage` (WE's Clean Local Storage).
public struct EditorLocalStorage {
    /// Whether the wallpaper's scripts stored anything.
    public var hasData: () -> Bool
    /// Deletes what they stored and runs the canvas's scripts again from nothing.
    public var clean: () throws -> Void

    public init(hasData: @escaping () -> Bool, clean: @escaping () throws -> Void) {
        self.hasData = hasData
        self.clean = clean
    }
}

/// What Edit with External Image Editor needs from the app.
public struct ExternalImageEditing {
    /// Where the pictures handed to the external editor are written (one per layer).
    public var directory: URL
    /// The editor's defaults, which keep the chosen app (WE's "Custom image editor path").
    public var defaults: UserDefaults

    public init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
    }
}
