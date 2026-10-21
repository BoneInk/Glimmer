import Foundation

/// The effects made in the editor: created (New / Duplicate Effect), their files edited (the
/// shader editor, the material's options) and deleted, each one undo step.
extension SceneEditSession {
    /// Keeps `effect`'s files in the overlay.
    public func createCustomEffect(_ effect: CustomEffect, actionName: String) {
        editOverlay(actionName: actionName) { overlay in
            for (path, text) in effect.files { overlay.setEffectFile(path, text: text) }
        }
    }

    /// Writes `text` as the editor's file at `path` (a shader or material of an effect made here,
    /// or the wallpaper's own file of an effect it ships, which the overlay's copy then replaces).
    public func setEffectFile(_ path: String, text: String, actionName: String) {
        editOverlay(actionName: actionName) { $0.setEffectFile(path, text: text) }
    }

    /// Deletes the effect made here whose `effect.json` is `file`: every file of its folder. The
    /// layers that use it keep it, as in WE ("This will break all usages of that effect").
    public func deleteCustomEffect(_ file: String, actionName: String) {
        let folder = (file as NSString).deletingLastPathComponent + "/"
        editOverlay(actionName: actionName) { overlay in
            for path in (overlay.effectFiles ?? [:]).keys where path.hasPrefix(folder) {
                overlay.setEffectFile(path, text: nil)
            }
        }
    }
}
