import Foundation

/// A layer's string members. They live on the JS objects (they change rarely) and reach the
/// renderer as `SceneScriptObjectCommand.setString`, coalesced to the last write per frame.
enum SceneScriptStringField: String, CaseIterable {
    case name, text, font, horizontalalign, verticalalign, anchor, alignment
}
