import Foundation

/// A run of properties as WE's sidebar folds them: the properties before the first `group`
/// property stand alone (no header), and each group takes the properties after it up to the next
/// group (`wallpaperbrowserApp` details: a `group` property starts a new section, closed at first).
public struct UserPropertyGroup: Hashable, Sendable, Identifiable {
    /// The `group` property; nil for the properties before the first one.
    public var header: UserPropertyDraft?
    public var members: [UserPropertyDraft]

    public var id: String { header?.key ?? "" }

    /// `properties` (in WE's order) folded into groups; a leading run without a group comes first
    /// and is left out when empty.
    public static func groups(_ properties: [UserPropertyDraft]) -> [UserPropertyGroup] {
        var groups = [UserPropertyGroup(header: nil, members: [])]
        for property in properties {
            if property.kind == .group {
                groups.append(UserPropertyGroup(header: property, members: []))
            } else {
                groups[groups.count - 1].members.append(property)
            }
        }
        if groups[0].members.isEmpty { groups.removeFirst() }
        return groups
    }

    /// The key of the group `key` belongs to, nil when it stands alone (or is a group).
    public static func group(of key: String, in properties: [UserPropertyDraft]) -> String? {
        var current: String?
        for property in properties {
            if property.kind == .group {
                current = property.key
            } else if property.key == key {
                return current
            }
        }
        return nil
    }
}
