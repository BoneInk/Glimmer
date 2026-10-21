import SwiftUI

/// One choice of a picker Scene Edit / Export and the editor show (a `// [COMBO]` option, a blend
/// mode), with the editor group WE files it under.
public struct InspectorOption: Hashable, Sendable {
    public let title: String
    public let value: Int
    /// WE's group heading ("Native (fast)" / "Emulated (slow)" for blend modes); nil for none.
    public let group: String?

    public init(title: String, value: Int, group: String? = nil) {
        self.title = title
        self.value = value
        self.group = group
    }
}

public enum InspectorOptionGroups {
    public struct Group: Identifiable, Hashable, Sendable {
        /// Its position, so two runs under one heading stay apart.
        public let id: Int
        public let heading: String?
        public let options: [InspectorOption]
    }

    /// The options in runs of one group, in order; one run without a heading when none has a group.
    public static func groups(_ options: [InspectorOption]) -> [Group] {
        var groups: [Group] = []
        for option in options {
            if let last = groups.last, last.heading == option.group {
                groups[groups.count - 1] = Group(id: last.id, heading: last.heading, options: last.options + [option])
            } else {
                groups.append(Group(id: groups.count, heading: option.group, options: [option]))
            }
        }
        return groups
    }
}

/// A picker of `options` under their group headings, as Scene Edit / Export lists WE's blend
/// modes and combos.
public struct InspectorOptionPicker<Label: View>: View {
    private let options: [InspectorOption]
    @Binding private var selection: Int
    private let label: Label

    public init(options: [InspectorOption], selection: Binding<Int>, @ViewBuilder label: () -> Label) {
        self.options = options
        _selection = selection
        self.label = label()
    }

    public var body: some View {
        Picker(selection: $selection) {
            ForEach(InspectorOptionGroups.groups(options)) { group in
                if let heading = group.heading {
                    Section(heading) {
                        ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                    }
                } else {
                    ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                }
            }
        } label: {
            label
        }
    }
}
