import Foundation
import OWEControlProtocol
import OWEEditor
import OWESceneEditing

/// One wallpaper edited without a window: an edit session (`SceneEditSession`) over the
/// wallpaper's Wallpaper Editor draft (`WallpaperEditorDraft`), as the editor's window holds one,
/// with its own undo stack. Every change goes into the draft, which only the editor's canvas runs:
/// `announce` tells the Wallpaper Editor's process, whose open window of the wallpaper takes the
/// change as an undo step of its own. `save()` (`wallpaper_editor_save`) makes the draft the
/// wallpaper's, as File › Save does: the running instances draw a value change live or reload, a
/// particle document change rebuilds only its systems.
///
/// A draft changed by someone else since (an editor window, or its Undo) is adopted at the next
/// request with a fresh undo history (`refresh`), so an MCP Undo never undoes the user's work.
@MainActor
final class HeadlessSceneDocument {
    struct Dependencies {
        var store: SceneEditDraftStore
        /// This process's own notifications: the running instances listen there.
        var center: NotificationCenter
        /// Tells the Wallpaper Editor's process that the draft of the wallpaper in `folder` changed
        /// here, with the undo step's name and whether it was that step, or its Undo or Redo.
        var announce: @MainActor (_ folder: URL, _ actionName: String, _ step: AppProcessChannel.OverlayStep) -> Void
        /// Tells the app's change sync and the Wallpaper Editor's process that the draft of the
        /// wallpaper in `folder` was saved here, as `overlay`.
        var announceSave: @MainActor (_ folder: URL, _ overlay: SceneEditOverlay) -> Void
        var particleSchema: () throws -> ParticleEditorSchema
    }

    let wallpaper: ControlWallpaper
    let resources: SceneEditResources
    let timelineIndex: TimelineSceneIndex
    private(set) var session: SceneEditSession
    private let authoredOutline: SceneOutline
    private let dependencies: Dependencies
    /// The draft as last written here or adopted: a draft of anything else is someone else's.
    private var draftOverlay: SceneEditOverlay
    /// The name of the step being saved, for the editor window that takes it.
    private var pendingActionName: String?
    /// Whether the change being saved is a new step, or an Undo or Redo of one.
    private var pendingStep: AppProcessChannel.OverlayStep = .edit
    /// Depth maps generated but not applied yet, by layer (`sceneDepthKey` for the scene).
    private var depthModels: [Int: DepthMapSectionModel] = [:]
    static let sceneDepthKey = Int.min

    /// The name of an MCP client's change in an editor's Edit menu.
    nonisolated static var defaultActionName: String {
        String(localized: "MCP Edit", comment: "Undo menu: a change an MCP client made to the wallpaper (Undo MCP Edit)")
    }

    init(wallpaper: ControlWallpaper, resources: SceneEditResources, dependencies: Dependencies) throws {
        self.wallpaper = wallpaper
        self.resources = resources
        self.dependencies = dependencies
        do {
            authoredOutline = try SceneOutline(sceneData: resources.sceneData)
        } catch {
            throw ControlError(.failed, "The scene of \"\(wallpaper.title)\" can't be read: \(error.localizedDescription)")
        }
        timelineIndex = Self.timelineIndex(resources.sceneData, title: wallpaper.title)
        let overlay = try Self.storedOverlay(resources.identity, store: dependencies.store, title: wallpaper.title)
        draftOverlay = overlay
        session = Self.session(authoredOutline, overlay)
        attach(session)
    }

    private static func timelineIndex(_ scene: Data, title: String) -> TimelineSceneIndex {
        do {
            return try TimelineSceneIndex(sceneData: scene)
        } catch {
            OWELog.error(.scene, "MCP: the timelines of \(title) can't be read: \(error)")
            return .empty
        }
    }

    /// The wallpaper's draft, else its saved overlay.
    private static func storedOverlay(_ identity: WallpaperSettingsIdentity, store: SceneEditDraftStore,
                                      title: String) throws -> SceneEditOverlay {
        do {
            return try store.overlay(for: identity.rawValue)
        } catch {
            throw ControlError(.failed, "The edits of \"\(title)\" can't be read: \(error.localizedDescription)")
        }
    }

    /// A session whose undo steps are its commits: a request has no event loop turn of its own to
    /// group by, so each change (one request's list, a revert) is one step, as one control is in an editor.
    private static func session(_ outline: SceneOutline, _ overlay: SceneEditOverlay) -> SceneEditSession {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return SceneEditSession(outline: outline, overlay: overlay, undoManager: undoManager)
    }

    private func attach(_ session: SceneEditSession) {
        session.onChange = { [weak self] overlay in self?.write(overlay) }
    }

    // MARK: Someone else's edits

    /// Adopts a draft written elsewhere since this document last wrote or read it; its undo
    /// history starts again. True when there was one.
    @discardableResult
    func refresh() throws -> Bool {
        let stored = try Self.storedOverlay(resources.identity, store: dependencies.store, title: wallpaper.title)
        guard stored != draftOverlay else { return false }
        draftOverlay = stored
        depthModels = [:]
        session = Self.session(authoredOutline, stored)
        attach(session)
        return true
    }

    // MARK: Editing

    /// Applies `edits` in order, all or nothing, as one undo step named `actionName`: they run on a
    /// copy of the session first, through the same session calls the editor's controls make, and
    /// only a list that went through whole changes the wallpaper. Returns each edit's result.
    func apply(_ edits: [ControlParameters], actionName: String?) throws -> [JSONValue] {
        let scratch = SceneEditSession(outline: authoredOutline, overlay: session.overlay)
        let context = SceneEditOperationContext(session: scratch, resources: resources, timelineIndex: timelineIndex,
                                                particleSchema: dependencies.particleSchema)
        var results: [JSONValue] = []
        for (index, edit) in edits.enumerated() {
            // Optional: only names the edit in the message; a wrong type is reported by the edit itself.
            let op = try? edit.string("op")
            do {
                results.append(try SceneEditOperations.apply(edit, in: context))
            } catch let error as ControlError {
                throw ControlError(error.code, "edits[\(index)]" + (op.map { " (\($0))" } ?? "") + ": \(error.message) Nothing was changed.")
            }
        }
        let next = scratch.overlay
        guard next != session.overlay else { return results }
        let name = actionName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultActionName
        pendingActionName = name
        session.edit(actionName: name) { $0 = next }
        pendingActionName = nil
        return results
    }

    /// Runs `change` on the session itself (depth maps, which generate before they edit).
    func edit<Result>(actionName: String = HeadlessSceneDocument.defaultActionName,
                      _ change: (SceneEditSession) async throws -> Result) async rethrows -> Result {
        pendingActionName = actionName
        defer { pendingActionName = nil }
        return try await change(session)
    }

    /// Undoes the last step; an open editor window of the wallpaper undoes the same step (`announce`).
    func undo() -> Bool {
        guard session.canUndo else { return false }
        move(.undo, named: session.undoManager.undoActionName) { $0.undo() }
        return true
    }

    /// Redoes the last undone step, as an open editor window of the wallpaper does.
    func redo() -> Bool {
        guard session.canRedo else { return false }
        move(.redo, named: session.undoManager.redoActionName) { $0.redo() }
        return true
    }

    private func move(_ step: AppProcessChannel.OverlayStep, named name: String, _ change: (SceneEditSession) -> Void) {
        pendingStep = step
        pendingActionName = name.isEmpty ? nil : name
        defer {
            pendingStep = .edit
            pendingActionName = nil
        }
        change(session)
    }

    /// The draft back to the wallpaper as last saved, one undo step, as File › Revert to Saved
    /// does. False when there was nothing unsaved.
    func revertToSaved() -> Bool {
        let saved = draft.savedOverlay
        guard session.overlay != saved else { return false }
        pendingActionName = String(localized: "Revert to Saved", comment: "Wallpaper Editor: Undo menu name of going back to the last save")
        session.revert(to: saved, actionName: pendingActionName ?? "")
        pendingActionName = nil
        return true
    }

    // MARK: The draft

    /// The wallpaper's Wallpaper Editor draft: the overlay this document edits, and the user
    /// properties an open editor window's Details panel set.
    var draft: WallpaperEditorDraft {
        WallpaperEditorDraft(overlayIdentity: resources.identity, properties: resources.propertyTargets, store: dependencies.store)
    }

    /// Whether the draft has anything `save()` would save.
    var hasUnsavedChanges: Bool { draft.hasUnsavedChanges }

    /// File › Save (`wallpaper_editor_save`): the draft becomes the wallpaper's, the running
    /// instances apply it once, and the Wallpaper Editor's open window has nothing unsaved. False
    /// when there was nothing to save.
    func save() throws -> Bool {
        let draft = self.draft
        guard draft.hasUnsavedChanges else { return false }
        let previous = draft.savedOverlay
        let saved: SceneEditOverlay?
        do {
            saved = try draft.commit()
        } catch {
            throw ControlError(.failed, "The changes to \"\(wallpaper.title)\" couldn't be saved: \(error.localizedDescription)")
        }
        if let saved {
            SceneEditOverlayFiles.postSaved(saved, previous: previous, base: session.baseOutline,
                                            wallpaperDirectory: resources.folder, center: dependencies.center)
        }
        dependencies.announceSave(resources.folder, saved ?? previous)
        return true
    }

    /// The depth map section's model for `layer` (nil: the scene), kept until the next refresh so a
    /// depth map generated by one request is applied by the next.
    func depthModel(layer: Int?) -> DepthMapSectionModel? {
        let key = layer ?? Self.sceneDepthKey
        if let model = depthModels[key], model.session === session { return model }
        guard let services = resources.depthMapServices() else { return nil }
        let model = DepthMapSectionModel(session: session, layerID: layer, services: services)
        depthModels[key] = model
        return model
    }

    // MARK: Writing

    /// Writes the draft, as the editor window does with each change; then the Wallpaper Editor's
    /// process hears of it. Nothing that runs the wallpaper sees it until `save()`.
    private func write(_ overlay: SceneEditOverlay) {
        do {
            try dependencies.store.saveDraft(overlay, for: resources.identity.rawValue)
        } catch {
            OWELog.error(.scene, "MCP: can't keep the Wallpaper Editor's draft of \(wallpaper.title): \(error)")
            return
        }
        draftOverlay = overlay
        dependencies.announce(resources.folder, pendingActionName ?? Self.defaultActionName, pendingStep)
    }
}
