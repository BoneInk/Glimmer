import SwiftUI

/// Opens the user-property editor from the scene's inspector.
struct EditUserPropertiesButton: View {
    @EnvironmentObject private var authoring: EditorAuthoringModel

    var body: some View {
        Button(L("Edit…")) { authoring.isEditingProperties = true }
            .buttonStyle(.borderless)
            .help(L("Add, edit and arrange the wallpaper’s user properties"))
    }
}
