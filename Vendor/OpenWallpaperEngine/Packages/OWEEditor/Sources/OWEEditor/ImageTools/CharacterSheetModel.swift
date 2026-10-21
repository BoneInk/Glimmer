import OWESceneEditing
import SwiftUI

/// WE's Character Sheet Creation for one cut-out image layer: the limb hierarchy (the Body, then
/// limbs added under the selected one), each limb a separation of the picture its parent or the
/// sibling before it leaves (`CharacterSheet.sources`), and OK, which lays the pieces out on one
/// texture and replaces the layer with it.
@MainActor
final class CharacterSheetModel: ObservableObject {
    struct Limb: Identifiable {
        let id = UUID()
        var name: String
        var depth: Int
        /// Nil for the Body, which isn't separated.
        var editor: SeparationEditor?
    }

    let session: SceneEditSession
    let layerID: Int
    let services: WallpaperEditorServices
    let picture: RGBAImage?

    @Published private(set) var limbs: [Limb]
    @Published var selection: UUID
    @Published private(set) var isGenerating = false
    @Published var problem: String?

    init(session: SceneEditSession, layerID: Int, services: WallpaperEditorServices, bodyName: String) {
        self.session = session
        self.layerID = layerID
        self.services = services
        picture = ImageToolPicture.load(layerID: layerID, session: session, services: services)
        let body = Limb(name: bodyName, depth: 0, editor: nil)
        limbs = [body]
        selection = body.id
    }

    var selectedIndex: Int? { limbs.firstIndex { $0.id == selection } }
    var selected: Limb? { selectedIndex.map { limbs[$0] } }

    /// OK needs a separated limb.
    var canFinish: Bool { limbs.contains { $0.editor?.result != nil } && !limbs.contains { $0.editor?.isComputing == true } }

    /// The tree lines before a limb's name (WE's `├`, `└`, `│`).
    func treePrefix(_ index: Int) -> String {
        let depth = limbs[index].depth
        guard depth > 0 else { return "" }
        func continues(_ level: Int) -> Bool {
            for later in limbs[(index + 1)...] {
                if later.depth < level { return false }
                if later.depth == level { return true }
            }
            return false
        }
        var prefix = ""
        for level in 1..<depth { prefix += continues(level) ? "│" : " " }
        return prefix + (continues(depth) ? "├" : "└")
    }

    // MARK: Hierarchy

    /// Add Limb: a child of the selected limb, after the selected limb's own children, selected.
    func addLimb(named name: String) {
        guard let picture, let parentIndex = selectedIndex else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let depth = limbs[parentIndex].depth + 1
        var insertAt = parentIndex + 1
        while insertAt < limbs.count && limbs[insertAt].depth >= depth { insertAt += 1 }
        let editor = SeparationEditor(picture: picture, settings: .sheet)
        let limb = Limb(name: trimmed.isEmpty ? "limb" : trimmed, depth: depth, editor: editor)
        limbs.insert(limb, at: insertAt)
        selection = limb.id
        refreshSources()
    }

    /// Removes a limb; its children move up under its parent (WE's), which is selected.
    func removeLimb(_ id: UUID) {
        guard let index = limbs.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let parent = CharacterSheet.parents(depths: limbs.map(\.depth))[index].map { limbs[$0].id }
        let depth = limbs[index].depth
        limbs.remove(at: index)
        var child = index
        while child < limbs.count && limbs[child].depth > depth {
            limbs[child].depth -= 1
            child += 1
        }
        selection = parent ?? limbs[0].id
        refreshSources()
    }

    /// Gives each limb the picture it is cut from now.
    func refreshSources() {
        guard let picture else { return }
        let sources = CharacterSheet.sources(depths: limbs.map(\.depth))
        for (index, source) in sources.enumerated() {
            guard let editor = limbs[index].editor else { continue }
            let image: RGBAImage
            switch source {
            case .picture: image = picture
            case .foreground(let of): image = of == 0 ? picture : (limbs[of].editor?.result?.foreground ?? picture)
            case .background(let of): image = limbs[of].editor?.result?.background ?? picture
            }
            editor.setPicture(image)
        }
        objectWillChange.send()
    }

    // MARK: Finishing

    /// OK: the pieces as WE collects them, laid out in a sheet that replaces the layer; returns
    /// the new layer's id.
    func finish() async -> Int? {
        guard let store = services.assetStore else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        let limbs = limbs.map { (limb: Limb) -> CharacterSheet.Limb in
            CharacterSheet.Limb(depth: limb.depth, foreground: limb.editor?.result?.foreground, background: limb.editor?.result?.background)
        }
        guard let picture else { return nil }
        let sheet = await Task.detached(priority: .userInitiated) {
            CharacterSheet.sheet(CharacterSheet.pieces(limbs, body: picture)).cgImage
        }.value
        guard let sheet else {
            problem = IL("Failed to pack texture sheet.")
            return nil
        }
        do {
            return try session.replaceWithCharacterSheet(sheet, layerID: layerID, store: store, readFile: services.readFile,
                                                         actionName: IL("Character Sheet Creation"))
        } catch {
            problem = IL("The character sheet couldn’t be saved: \(error.localizedDescription)")
            return nil
        }
    }
}
