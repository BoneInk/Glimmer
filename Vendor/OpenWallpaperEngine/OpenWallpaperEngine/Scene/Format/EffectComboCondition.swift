import Foundation

/// What one combo must be for a condition to hold: WE's `{COMBO: value}` (equal to it), or the
/// comparison form `{COMBO: {"op": "ge", "value": 2}}` that WE 2.x effects author (fluid
/// simulation's and Workshop effects' gizmos). WE's effect loader has `op` with `ge`, `gt`, `le`
/// and `lt` among its effect.json strings (wallpaper64.exe); `eq`, or no `op`, compares equal.
struct EffectComboCondition: Decodable, Equatable, ExpressibleByIntegerLiteral {
    enum Operator: String { case eq, ge, gt, le, lt }

    /// nil for an `op` WE doesn't have: the requirement never holds (reported when decoded).
    var op: Operator?
    var value: Int

    init(_ op: Operator?, _ value: Int) {
        self.op = op
        self.value = value
    }

    init(integerLiteral value: Int) { self.init(.eq, value) }

    func holds(_ combo: Int) -> Bool {
        switch op {
        case .eq?: return combo == value
        case .ge?: return combo >= value
        case .gt?: return combo > value
        case .le?: return combo <= value
        case .lt?: return combo < value
        case nil: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case op, value }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = Self.integer(single) { // optional: else the object form
            self.init(.eq, value)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .op)
        guard let value = Self.integer(try c.superDecoder(forKey: .value).singleValueContainer()) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.value],
                                                    debugDescription: "condition value is not a number"))
        }
        let op = name.map { Operator(rawValue: $0.lowercased()) } ?? .eq
        if op == nil {
            reportSkippedElement(decoder.userInfo, path: c.codingPath + [CodingKeys.op],
                                 error: DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.op],
                                                                          debugDescription: "unknown condition op \(name ?? "")")))
        }
        self.init(op, value)
    }

    /// A combo value: an integer, or a whole number written as a decimal or a bool.
    private static func integer(_ container: SingleValueDecodingContainer) -> Int? {
        if let value = try? container.decode(Int.self) { return value } // optional: tried in turn
        if let value = try? container.decode(Double.self), value.isFinite, value.rounded() == value { return Int(value) } // optional
        if let value = try? container.decode(Bool.self) { return value ? 1 : 0 } // optional
        return nil
    }
}
