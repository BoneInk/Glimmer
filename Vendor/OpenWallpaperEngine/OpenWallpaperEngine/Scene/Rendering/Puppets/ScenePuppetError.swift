enum ScenePuppetError: Error, CustomStringConvertible {
    case unsupported(String)

    var description: String {
        switch self {
        case .unsupported(let reason): return "unsupported: \(reason)"
        }
    }
}
