import SwiftUI

/// A measured stroke around the existing action, independent of its disabled styling.
struct WorkshopDownloadProgressRing: View {
    let presentation: WorkshopDownloadProgressPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.windowGlassReduceTransparencyOverride) private var reviewReduceTransparency

    private var reduceTransparency: Bool { systemReduceTransparency || reviewReduceTransparency }
    private var isIndeterminate: Bool { presentation.ring == .indeterminate }

    var body: some View {
        if presentation.ring != .none {
            ZStack {
                Circle().stroke(.white.opacity(reduceTransparency ? 0.38 : 0.22), lineWidth: 2)
                if isIndeterminate && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        arc(rotation: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5 * 360)
                    }
                } else {
                    arc(rotation: 0)
                }
            }
            .padding(1)
        }
    }

    private func arc(rotation: Double) -> some View {
        Circle()
            .trim(from: 0, to: strokeFraction)
            .stroke(Color.white.opacity(presentation.ring == .waiting ? 0.6 : 1), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90 + rotation))
    }

    private var strokeFraction: Double {
        switch presentation.ring {
        case .none: 0
        case .waiting: 0.12
        case .determinate(let fraction): fraction
        case .indeterminate: 0.24
        }
    }
}
