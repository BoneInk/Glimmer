import Foundation

/// One entry of a scene object's `dependencies`. On a particle object it links an operator to
/// another object: `{"id": <object id>, "type": "collisionmodel", "index": n}`, n the operator's
/// ordinal among the system's operators of that type (parsed at 0x14022b1f3, bound at
/// 0x14022cfa0; docs/models-plan.md §2.12). The library's model objects carry plain ids, which
/// the editor writes and the runtime doesn't read.
enum WEObjectDependency: Decodable, Equatable {
    case link(id: Int, type: String?, index: Int?)
    case id(Int)

    init(from decoder: Decoder) throws {
        switch try SceneJSON(from: decoder) {
        case .number(let id):
            self = .id(Int(SceneTimelineDocument.asInt(id)))
        case .object(let object):
            guard case .number(let id)? = object["id"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "dependency without a numeric id"))
            }
            let type: String? = if case .string(let name)? = object["type"] { name } else { nil }
            let index: Int? = if case .number(let n)? = object["index"] { Int(SceneTimelineDocument.asInt(n)) } else { nil }
            self = .link(id: Int(SceneTimelineDocument.asInt(id)), type: type, index: index)
        case let other:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unsupported dependency \(other)"))
        }
    }
}
