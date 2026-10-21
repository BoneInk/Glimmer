import AppKit
import SwiftUI
import OWESceneEditing

/// A layer and the layers parented to it, as the list nests them (`SceneOutline.tree()`).
typealias LayerNode = SceneOutline.Node

extension SceneOutline.Node {
    static func tree(_ outline: SceneOutline) -> [SceneOutline.Node] { outline.tree() }
}

/// The sidebar: the layer hierarchy (scene.json's objects and their parents) with visibility and
/// lock, reordered by dragging (onto a row: above it; with Option: into it), or the asset browser.
struct LayerListView: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices

    private var actions: LayerActions { LayerActions(session: session, services: services, tools: tools) }

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $tools.sidebarTab) {
                Text(L("Layers")).tag(EditorTools.SidebarTab.layers)
                Text(L("Assets")).tag(EditorTools.SidebarTab.assets)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            switch tools.sidebarTab {
            case .layers: layers
            case .assets: AssetBrowserView(session: session, tools: tools, services: services)
            }
        }
    }

    private var layers: some View {
        let tree = LayerNode.tree(session.outline)
        // Several rows select with Shift and ⌘ (`SceneEditSession.selectedLayers`); the inspector
        // shows the one clicked last.
        return List(selection: Binding<Set<Int>>(
            get: { session.selectedLayers.isEmpty ? Set(session.selection.map { [$0] } ?? []) : session.selectedLayers },
            set: { (rows: Set<Int>) in
                let added = rows.subtracting(session.selectedLayers)
                session.select(rows, primary: added.count == 1 ? added.first : nil)
            })) {
            Section {
                OutlineGroup(tree, children: \.children) { node in
                    LayerRow(session: session, tools: tools, services: services, layer: node.layer, actions: actions)
                        .tag(node.id)
                        .contextMenu { LayerContextMenu(session: session, layer: node.layer, actions: actions) }
                        .draggable(LayerDrag.token(node.id))
                        .dropDestination(for: String.self) { items, _ in
                            drop(items.compactMap(LayerDrag.id), onto: node.id)
                        }
                }
            } header: {
                Text(L("Layers"))
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if tree.isEmpty {
                Text(L("This scene has no layers."))
                    .foregroundStyle(.secondary)
            }
        }
        .onDeleteCommand {
            if let selected = session.selection { actions.deleteSelection(selected) }
        }
        .sheet(isPresented: Binding(get: { tools.choosingListPosition != nil },
                                    set: { if !$0 { tools.choosingListPosition = nil } })) {
            if let layer = tools.choosingListPosition {
                ListPositionSheet(session: session, tools: tools, layerID: layer)
            }
        }
    }

    /// A drop on a row puts the layers just above it (drawn after it), beside it under its parent;
    /// with Option held, into it.
    private func drop(_ ids: [Int], onto target: Int) -> Bool {
        let moving = ids.filter { $0 != target && session.outline.layer($0) != nil }
        guard !moving.isEmpty else { return false }
        if NSEvent.modifierFlags.contains(.option) {
            let into = moving.filter { session.canParent($0, to: target) }
            guard !into.isEmpty else { return false }
            session.setParent(into, to: target, actionName: L("Move Into Group"))
            return true
        }
        let parent = session.outline.layer(target)?.parentID.flatMap { session.outline.layer($0) != nil ? $0 : nil }
        let reparent = moving.filter { session.outline.layer($0)?.parentID != parent && session.canParent($0, to: parent) }
        if !reparent.isEmpty { session.setParent(reparent, to: parent, actionName: L("Move Layer")) }
        session.move(moving, relativeTo: target, above: true, actionName: L("Reorder Layers"))
        return true
    }
}

/// A layer dragged in the list, as text naming it (a drag within the window).
enum LayerDrag {
    static let prefix = "owe-editor-layer:"

    static func token(_ id: Int) -> String { prefix + String(id) }

    static func id(_ token: String) -> Int? {
        guard token.hasPrefix(prefix) else { return nil }
        return Int(token.dropFirst(prefix.count))
    }
}

private struct LayerRow: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let layer: SceneLayer
    let actions: LayerActions
    @State private var isHovering = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let visible = session.isVisible(layer.id)
        // Shown only when it and its groups are: a hidden group dims everything in it.
        let shown = visible && !session.isHiddenByParent(layer.id)
        let locked = session.isLocked(layer.id)
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .opacity(shown ? 1 : 0.5)
                .frame(width: 18)
                .accessibilityLabel(layer.kind.title)
            if tools.renaming == layer.id {
                TextField(L("Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onExitCommand { tools.renaming = nil }
                    .onAppear {
                        name = layer.name ?? ""
                        nameFocused = true
                    }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            } else {
                Text(layer.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(shown ? .primary : .secondary)
                    .onTapGesture(count: 2) {
                        if session.isEditable("name", of: layer.id) { tools.renaming = layer.id }
                    }
            }
            if session.isEdited(layer.id) {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .help(L("Edited"))
                    .accessibilityLabel(L("Edited"))
            }
            Spacer(minLength: 4)
            Button {
                session.setLocked(!locked, layer.id, actionName: locked ? L("Unlock Layer") : L("Lock Layer"))
            } label: {
                Label(locked ? L("Unlock Layer") : L("Lock Layer"), systemImage: locked ? "lock.fill" : "lock.open")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .opacity(locked || isHovering ? 1 : 0)
            .help(locked ? L("Unlock Layer") : L("Lock Layer"))
            visibilityButton(visible: visible)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// The kind's symbol; solid, composition and fullscreen layers have their own.
    private var symbol: String { layer.listSymbol }

    private func commitName() {
        guard tools.renaming == layer.id else { return }
        tools.renaming = nil
        if name != (layer.name ?? "") { session.rename(layer.id, to: name, actionName: L("Rename Layer")) }
    }

    /// The eye. On a layer a user property shows, it hides the layer whatever the property says,
    /// and shows it again by handing it back to the property (`SceneEditSession.setVisible`).
    @ViewBuilder private func visibilityButton(visible: Bool) -> some View {
        let property = session.visibilityProperty(of: layer.id)
        let on = property == nil ? visible : !session.isHiddenOverProperty(layer.id)
        Button {
            session.setVisible(!on, layer.id, actionName: on ? L("Hide Layer") : L("Show Layer"))
        } label: {
            Label(on ? L("Hide Layer") : L("Show Layer"), systemImage: on ? "eye" : "eye.slash")
                .labelStyle(.iconOnly)
                .foregroundStyle(on ? .primary : .secondary)
        }
        .buttonStyle(.borderless)
        .help(help(on: on, property: property))
    }

    private func help(on: Bool, property: String?) -> String {
        guard let key = property else { return on ? L("Hide Layer") : L("Show Layer") }
        let property = services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
        return on ? L("Hide this layer; “\(property)” sets it again when you show it")
            : L("Show this layer; “\(property)” sets it again")
    }
}
