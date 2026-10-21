import SwiftUI

/// WE's split dialog ("Split Monitor"): the direction of the divider and its position in points
/// from the left or the top, kept a point inside the display or region. A new direction starts at
/// the middle, as WE resets it.
struct DisplaySplitSheet: View {
    /// What the sheet splits or edits.
    struct Edit: Identifiable {
        /// The display or region to split, or the one whose split is edited.
        let id: String
        let name: String
        /// Its size in points.
        let size: CGSize
        /// The split being edited; nil for a new one.
        let split: DisplaySplit?

        var isNew: Bool { split == nil }
    }

    let edit: Edit
    let apply: (DisplaySplit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var direction: DisplaySplit.Direction
    @State private var position: Int

    init(edit: Edit, apply: @escaping (DisplaySplit) -> Void) {
        self.edit = edit
        self.apply = apply
        let split = edit.split ?? DisplaySplit()
        _direction = State(initialValue: split.direction)
        _position = State(initialValue: Int((split.position * Double(Self.extent(of: edit.size, split.direction))).rounded(.down)))
    }

    var body: some View {
        let extent = Self.extent(of: edit.size, direction)
        VStack(alignment: .leading, spacing: 16) {
            Text("Split Monitor: \(edit.name)")
                .font(.headline)
            Form {
                Picker("Direction", selection: $direction) {
                    Text("Vertical").tag(DisplaySplit.Direction.vertical)
                    Text("Horizontal").tag(DisplaySplit.Direction.horizontal)
                }
                .onChange(of: direction) { _, newValue in
                    position = Self.extent(of: edit.size, newValue) / 2
                }
                TextField("Position", value: $position, format: .number)
                    .monospacedDigit()
                    .help(Text(verbatim: "1–\(max(extent - 1, 1))"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButtonStyle()
                Button("OK") {
                    let points = min(max(position, 1), max(extent - 1, 1))
                    apply(DisplaySplit(direction: direction, position: Double(points) / Double(max(extent, 1))))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(.prominent)
                .disabled(extent < 2)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// The points along the split: the width for a vertical divider, the height for a horizontal one.
    private static func extent(of size: CGSize, _ direction: DisplaySplit.Direction) -> Int {
        Int((direction == .vertical ? size.width : size.height).rounded(.down))
    }
}
