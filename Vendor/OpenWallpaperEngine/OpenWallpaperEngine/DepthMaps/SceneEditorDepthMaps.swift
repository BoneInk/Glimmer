import SwiftUI
import OWEEditor
import OWESceneEditing

/// Depth maps in Scene Edit / Export (the app's scene inspector). Its own edits are user-property
/// style values (`WallpaperPropertyTargets`), which can't hold an added effect or a texture, so
/// depth parallax is stored where the Wallpaper Editor keeps its edits: the wallpaper's overlay
/// (`SceneEditOverlayFiles`), through an edit session of its own. Both editors then read and
/// write one source of truth, and every running instance of the wallpaper reloads with it.
@MainActor
final class SceneEditorDepthMapHost: ObservableObject {
    @Published private(set) var session: SceneEditSession?
    private(set) var services: DepthMapEditorServices?
    private let wallpaper: WEWallpaper
    private var identity: WallpaperSettingsIdentity?
    private var sceneData: Data?
    private var observer: NSObjectProtocol?

    /// `generator`: the process's (`DepthMapPlugin.generator`) unless given.
    init(wallpaper: WEWallpaper, generator: DepthMapGenerator? = nil) {
        self.wallpaper = wallpaper
        guard WallpaperEditorController.canEdit(wallpaper) else { return }
        do {
            let source = try WallpaperEditorSource.read(wallpaper)
            let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
            self.identity = identity
            sceneData = source.scene
            let resources = EditorWallpaperResources(wallpaper: wallpaper, package: source.package,
                                                     assets: SceneEditOverlayFiles.assets(for: identity))
            services = DepthMapPlugin.services(for: wallpaper, resources: resources,
                                                generator: generator,
                                                openPlugins: { AppDelegate.shared.openSettings(for: .depthMaps) })
            makeSession(overlay: SceneEditOverlayFiles.overlay(for: identity) ?? SceneEditOverlay())
        } catch {
            OWELog.error(.ui, "Scene Edit / Export: no depth maps for \(wallpaper.wallpaperDirectory.lastPathComponent): \(error)")
            return
        }
        let directory = wallpaper.wallpaperDirectory.standardizedFileURL
        // The Wallpaper Editor saved another overlay: edit that one from now on.
        observer = NotificationCenter.default.addObserver(forName: .sceneEditOverlayDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["transient"] as? Bool != true,
                  (note.userInfo?["wallpaperDirectory"] as? URL)?.standardizedFileURL == directory,
                  let overlay = note.userInfo?["overlay"] as? SceneEditOverlay else { return }
            MainActor.assumeIsolated {
                guard let self, overlay != self.session?.overlay else { return }
                self.makeSession(overlay: overlay)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func makeSession(overlay: SceneEditOverlay) {
        guard let sceneData,
              let outline = OWELog.attempt(.ui, "Depth maps: scene outline", { try SceneOutline(sceneData: sceneData) }) else { return }
        let session = SceneEditSession(outline: outline, overlay: overlay)
        session.onChange = { [weak self] overlay in self?.save(overlay) }
        self.session = session
    }

    private func save(_ overlay: SceneEditOverlay) {
        guard let identity else { return }
        do {
            try SceneEditOverlayFiles.save(overlay, for: identity, wallpaperDirectory: wallpaper.wallpaperDirectory,
                                           base: session?.baseOutline)
        } catch {
            OWELog.error(.scene, "Can't save the depth parallax of \(wallpaper.project.title): \(error)")
        }
    }
}

/// Scene Edit / Export's depth map boxes for one object: its Create Mask from Depth Map (an image or
/// text layer, whose effects' masks it fills) and the whole scene's Depth Parallax, with undo.
struct SceneEditorDepthMapSection: View {
    @ObservedObject var host: SceneEditorDepthMapHost
    let objectID: Int

    var body: some View {
        if let session = host.session, let services = host.services {
            let sessionID = ObjectIdentifier(session)
            VStack(alignment: .leading, spacing: 10) {
                if let layer = session.outline.layer(objectID), SceneDepthParallax.placement(for: layer) == .onLayer {
                    DepthMapBox(session: session, layerID: objectID, services: services)
                        .id("\(sessionID.hashValue)-\(objectID)")
                }
                DepthMapBox(session: session, layerID: nil, services: services)
                    .id("\(sessionID.hashValue)-scene")
                SceneEditorDepthMapUndo(session: session)
            }
        }
    }
}

private struct SceneEditorDepthMapUndo: View {
    @ObservedObject var session: SceneEditSession

    var body: some View {
        HStack {
            Button("Undo") { session.undo() }
                .disabled(!session.canUndo)
            Button("Redo") { session.redo() }
                .disabled(!session.canRedo)
            Spacer()
        }
        .controlSize(.small)
    }
}
