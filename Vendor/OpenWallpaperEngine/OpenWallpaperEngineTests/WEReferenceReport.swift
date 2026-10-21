import Foundation
import simd

/// The Markdown `WEReferenceComparisonTests` writes: a summary table, then per wallpaper the
/// metrics of each still, its worst cells and the item's own checks.
struct WEReferenceReport {
    private var summary: [String] = []
    private var sections: [String] = []
    private var lines: [String] = []

    mutating func begin(_ item: WEReferenceConfig.Item, masks: [WEReferenceConfig.Mask]) {
        flush()
        lines.append("## \(item.id) — \(item.title)")
        lines.append("")
        lines.append(item.focus)
        lines.append("")
        if !masks.isEmpty {
            let described = masks.map { "\($0.rect.description) (\($0.reason))" }
            lines.append("Masked: " + described.joined(separator: "; ") + ".")
            lines.append("")
        }
        lines.append("| capture | still | mean abs Δ | luma WE → ours | SSIM | edge corr. (0 → best) | whole-frame edge shift |")
        lines.append("|---|---|---|---|---|---|---|")
    }

    mutating func missing(_ item: WEReferenceConfig.Item, reason: String) {
        flush()
        lines.append("## \(item.id) — \(item.title)")
        lines.append("")
        lines.append("Not compared: \(reason).")
        summary.append("| \(item.id) | — | — | — | — | not compared: \(reason) |")
    }

    mutating func add(_ item: WEReferenceConfig.Item, capture: WEReferenceConfig.Capture, still: String,
                      metrics: WEReferenceMetrics, unreliable: Bool) {
        let mark = unreliable ? " (unreliable)" : ""
        let luma = String(format: "%.1f → %.1f", metrics.weLuma, metrics.oursLuma)
        let edges = String(format: "%.3f → %.3f", metrics.edgeCorrelation, metrics.edgeBestCorrelation)
        let shift = "\(metrics.edgeShift.x), \(metrics.edgeShift.y)"
        let row = String(format: "| %@ | %@%@ | %.1f | %@ | %.3f | %@ | %@ |", capture.folder, still, mark, metrics.meanAbs,
                         luma, metrics.ssim, edges, shift)
        lines.append(row)
        let worst = metrics.cells.filter { $0.coverage > 0.5 }.sorted { $0.score > $1.score }.prefix(3)
        let names = worst.map(Self.describe).joined(separator: "; ")
        summary.append(String(format: "| %@ | %@/%@%@ | %.1f | %.3f | %@ | %@ |", item.id, capture.folder, still, mark,
                              metrics.meanAbs, metrics.ssim, shift, names))
        pendingWorst.append("- \(capture.folder)/\(still): " + names)
    }

    private var pendingWorst: [String] = []

    private static func describe(_ cell: WEReferenceCell) -> String {
        let shift = cell.edgeShift.map { " edges \($0.x),\($0.y)" } ?? ""
        let place = "x\(cell.rect.x)–\(cell.rect.x + cell.rect.z) y\(cell.rect.y)–\(cell.rect.y + cell.rect.w)"
        return String(format: "%@ WE(%@) ours(%@) Δ%.0f SSIM %.2f%@", place, rgb(cell.we), rgb(cell.ours),
                      cell.meanAbs, cell.ssim, shift)
    }

    private static func rgb(_ value: SIMD3<Double>) -> String {
        String(format: "%.0f,%.0f,%.0f", value.x, value.y, value.z)
    }

    mutating func note(_ text: String) {
        closeTable()
        lines.append(text)
    }

    private mutating func closeTable() {
        guard !pendingWorst.isEmpty else { return }
        lines.append("")
        lines.append("Worst cells (colour Δ + 50·(1 − SSIM)):")
        lines.append("")
        lines += pendingWorst
        lines.append("")
        pendingWorst = []
    }

    private mutating func flush() {
        closeTable()
        guard !lines.isEmpty else { return }
        sections.append(lines.joined(separator: "\n"))
        lines = []
    }

    mutating func markdown(header: String) -> String {
        flush()
        var text = header + "\n\n"
        text += "| item | still | mean abs Δ | SSIM | edge shift | worst cells |\n|---|---|---|---|---|---|\n"
        text += summary.joined(separator: "\n") + "\n\n"
        text += sections.joined(separator: "\n\n") + "\n"
        return text
    }
}
