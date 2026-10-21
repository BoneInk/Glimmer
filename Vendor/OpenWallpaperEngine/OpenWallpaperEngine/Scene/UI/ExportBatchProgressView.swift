import SwiftUI

/// One wallpaper of a batch export as its progress shows it.
struct ExportBatchRow: Identifiable {
    let id: String
    let title: String
    let status: ExportItemStatus
    let progress: Double
}

/// A batch export's progress: the whole batch, then each wallpaper with its state and progress,
/// and an accessory (a finished Live Photo's AirDrop button); then the wallpapers left out, with why.
struct ExportBatchProgressView<Accessory: View>: View {
    let progress: Double
    let isRunning: Bool
    let rows: [ExportBatchRow]
    let skipped: [(title: String, reason: String)]
    @ViewBuilder let accessory: (ExportBatchRow) -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progress) {
                Text(isRunning ? "Exporting…" : "Finished")
            }
            List {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: row.title).lineLimit(1)
                            Spacer()
                            accessory(row)
                            status(row.status)
                        }
                        if row.status == .running { ProgressView(value: row.progress) }
                    }
                }
                ForEach(Array(skipped.enumerated()), id: \.offset) { _, skipped in
                    HStack {
                        Text(verbatim: skipped.title).lineLimit(1)
                        Spacer()
                        Label(skipped.reason, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private func status(_ status: ExportItemStatus) -> some View {
        switch status {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting")
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done")
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption).lineLimit(2)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Cancelled")
        }
    }
}
