import SwiftUI

/// How a drop into a folder looks: the moved tiles shrink and fade out of the grid while the rest
/// close up, and the folder (a tile or a breadcrumb) pops once with a flash of the accent colour.
/// With Reduce Motion the tiles only fade and the folder only flashes.
enum InstalledDropAnimation {
    /// The animation the grid's change runs with.
    static func move(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.35, bounce: 0.15)
    }

    /// How a moved tile leaves the grid.
    static func removal(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity)
    }
}

extension View {
    /// The pop and flash of a folder that took a drop; runs each time `trigger` changes.
    func dropFeedback(trigger: Int, cornerRadius: CGFloat) -> some View {
        modifier(InstalledDropFeedback(trigger: trigger, cornerRadius: cornerRadius))
    }
}

private struct InstalledDropFeedback: ViewModifier {
    var trigger: Int
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Pulse {
        var scale: CGFloat = 1
        var flash: Double = 0
    }

    func body(content: Content) -> some View {
        let peak: CGFloat = reduceMotion ? 1 : 1.1
        let rebound: CGFloat = reduceMotion ? 1 : 0.97
        content.keyframeAnimator(initialValue: Pulse(), trigger: trigger) { view, pulse in
            view
                .scaleEffect(pulse.scale)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(pulse.flash))
                        .allowsHitTesting(false)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(peak, duration: 0.14)
                SpringKeyframe(rebound, duration: 0.12)
                SpringKeyframe(1, duration: 0.2)
            }
            KeyframeTrack(\.flash) {
                LinearKeyframe(0.35, duration: 0.1)
                LinearKeyframe(0, duration: 0.4)
            }
        }
    }
}
