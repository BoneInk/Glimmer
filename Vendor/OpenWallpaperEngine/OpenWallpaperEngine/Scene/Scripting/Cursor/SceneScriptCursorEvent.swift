import simd

extension SceneScriptEvent.Kind {
    /// `cursorEnter`, `cursorLeave`, `cursorDown`, `cursorUp` or `cursorClick` of one object:
    /// discrete, never merged.
    static let cursor = Self(rawValue: "cursor")
    /// `cursorMove` of one object: a state, so a stalled inbox keeps the newest per object.
    static let cursorMove = Self(rawValue: "cursorMove")
}

/// One cursor callback for the scripts of one object, as the cursor pass produced it.
struct SceneScriptCursorEvent: Equatable {
    /// WE's cursor callbacks and their indices in scenescript64.dll's callback table (0x1819a3ee0).
    enum Callback: String, CaseIterable {
        case cursorEnter, cursorLeave, cursorMove, cursorClick, cursorDown, cursorUp

        var index: Int {
            switch self {
            case .cursorEnter: return 8
            case .cursorLeave: return 9
            case .cursorMove: return 10
            case .cursorClick: return 11
            case .cursorDown: return 12
            case .cursorUp: return 13
            }
        }
    }

    var callback: Callback
    var slot: Int
    var worldPosition: SIMD3<Float>
    /// From the hit test: the quad's x and y (z 0), or where the ray enters a model's box or
    /// named hit box.
    var localPosition: SIMD3<Float>
    /// `CursorEvent.hitBox`: the name of the hit box under the cursor, when the pass asked for one.
    var hitBox: String?

    init(callback: Callback, slot: Int, worldPosition: SIMD3<Float>, localPosition: SIMD3<Float>, hitBox: String? = nil) {
        self.callback = callback
        self.slot = slot
        self.worldPosition = worldPosition
        self.localPosition = localPosition
        self.hitBox = hitBox
    }

    /// The inbox event `sceneScriptCursor.js` turns into WE's `CursorEvent`.
    var inboxEvent: SceneScriptEvent {
        var payload: [String: Any] = [
            "callback": callback.rawValue,
            "worldPosition": [Double(worldPosition.x), Double(worldPosition.y), Double(worldPosition.z)],
            "localPosition": [Double(localPosition.x), Double(localPosition.y), Double(localPosition.z)],
        ]
        if let hitBox { payload["hitBox"] = hitBox }
        let isMove = callback == .cursorMove
        return SceneScriptEvent(kind: isMove ? .cursorMove : .cursor, payload: payload, target: slot,
                                coalescing: isMove ? .latest : .keep)
    }
}
