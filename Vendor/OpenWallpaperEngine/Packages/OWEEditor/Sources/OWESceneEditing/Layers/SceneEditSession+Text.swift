import Foundation

/// A text layer's own fields: its text and the script that writes it (a clock), its font, size,
/// alignment and padding.
extension SceneEditSession {
    /// The text the layer shows before any script runs.
    public func textContent(of layerID: Int) -> String? {
        guard let text = value("text", of: layerID) else { return nil }
        return text.stringValue ?? text["value"]?.stringValue
    }

    /// The script writing the layer's text each frame, if it has one.
    public func textScript(of layerID: Int) -> String? {
        if let edit = overlay.field("text", of: layerID) {
            if case .object = edit { return edit["script"]?.stringValue }
            // A plain text edit keeps the scene's script (it is the script's starting value).
        }
        return baseOutline.layer(layerID)?.fields["text"]?["script"]?.stringValue
    }

    /// The script's options (`scriptproperties`).
    public func textScriptProperties(of layerID: Int) -> [String: SceneJSONValue] {
        let source = overlay.field("text", of: layerID).flatMap { edit -> SceneJSONValue? in
            if case .object = edit { return edit }
            return nil
        } ?? baseOutline.layer(layerID)?.fields["text"]
        if case .object(let properties)? = source?["scriptproperties"] { return properties }
        return [:]
    }

    /// Sets the text. A layer whose text a script writes keeps its script; the text is where it
    /// starts. Typing in a row is one undo step.
    public func setText(_ text: String, of layerID: Int, actionName: String, coalescing: Bool = true) {
        if let script = textScript(of: layerID) {
            setTextFields(value: text, script: script, properties: textScriptProperties(of: layerID), of: layerID,
                          actionName: actionName, coalescing: coalescing)
        } else {
            setValue(.string(text), for: "text", of: layerID, actionName: actionName, coalescing: coalescing)
        }
    }

    /// Gives the layer a script that writes its text (nil takes it away).
    public func setTextScript(_ script: SceneLayerFactory.TextScript?, of layerID: Int, actionName: String) {
        let text = textContent(of: layerID) ?? ""
        if let script {
            setTextFields(value: script.placeholder, script: script.source, properties: script.properties, of: layerID,
                          actionName: actionName, coalescing: false)
        } else {
            setTextFields(value: text, script: nil, properties: nil, of: layerID, actionName: actionName, coalescing: false)
        }
    }

    /// Sets one of the text script's options.
    public func setTextScriptProperty(_ name: String, to value: SceneJSONValue, of layerID: Int, actionName: String) {
        guard let script = textScript(of: layerID) else { return }
        var properties = textScriptProperties(of: layerID)
        properties[name] = value
        setTextFields(value: textContent(of: layerID) ?? "", script: script, properties: properties, of: layerID,
                      actionName: actionName, coalescing: true)
    }

    /// The `text` field whole: a script edit replaces the scene's (`SceneEditOverlay.merged`); a
    /// null script drops it.
    private func setTextFields(value: String, script: String?, properties: [String: SceneJSONValue]?, of layerID: Int,
                               actionName: String, coalescing: Bool) {
        guard isEditable("text", of: layerID) else { return }
        var fields: [String: SceneJSONValue] = ["value": .string(value), "script": script.map(SceneJSONValue.string) ?? .null]
        if let properties, !properties.isEmpty { fields["scriptproperties"] = .object(properties) }
        var next = overlay
        let edit: SceneJSONValue = .object(fields)
        let base = baseOutline.layer(layerID)?.fields["text"]
        let isAuthored = script == base?["script"]?.stringValue && value == SceneFieldBinding.literal(of: base)?.stringValue
            && (properties ?? [:]) == textScriptPropertiesOf(base)
        next.setField("text", to: isAuthored ? nil : edit, of: layerID)
        commit(next, actionName: actionName, coalescingKey: coalescing ? "\(layerID):text" : nil)
    }

    private func textScriptPropertiesOf(_ text: SceneJSONValue?) -> [String: SceneJSONValue] {
        if case .object(let properties)? = text?["scriptproperties"] { return properties }
        return [:]
    }
}
