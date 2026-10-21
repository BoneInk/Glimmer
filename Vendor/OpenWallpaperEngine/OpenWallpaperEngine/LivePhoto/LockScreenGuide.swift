import SwiftUI

/// Where the lock screen draws the date and the clock, in proportions of the screen: centred at
/// the top on an iPhone and on an iPad in portrait; on an iPad in landscape at the top left, as
/// iPadOS lays it out with its widgets under it.
struct LockScreenLayout: Equatable {
    enum Alignment: Equatable { case center, leading }

    let alignment: Alignment
    /// The clock's type size over the screen's shorter side.
    let clockSize: Double
    /// The date's type size over the screen's shorter side.
    let dateSize: Double
    /// The date's top over the screen's height.
    let top: Double
    /// The text's leading inset over the screen's width (leading alignment only).
    let leading: Double

    static func layout(for family: DeviceFamily, landscape: Bool) -> LockScreenLayout {
        switch (family, landscape) {
        case (.iPhone, _):
            return LockScreenLayout(alignment: .center, clockSize: 0.24, dateSize: 0.048, top: 0.07, leading: 0)
        case (.iPad, false):
            return LockScreenLayout(alignment: .center, clockSize: 0.16, dateSize: 0.03, top: 0.06, leading: 0)
        case (.iPad, true):
            return LockScreenLayout(alignment: .leading, clockSize: 0.15, dateSize: 0.03, top: 0.08, leading: 0.06)
        }
    }
}

/// A faint lock screen over the preview: where the date and the clock go.
struct LockScreenGuide: View {
    let layout: LockScreenLayout
    let size: CGSize

    var body: some View {
        let shorter = min(size.width, size.height)
        let leading = layout.alignment == .leading
        VStack(alignment: leading ? .leading : .center, spacing: 0) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: max(shorter * layout.dateSize, 1), weight: .semibold))
            Text(Date.now, format: .dateTime.hour().minute())
                .font(.system(size: max(shorter * layout.clockSize, 1), weight: .bold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.top, size.height * layout.top)
        .padding(.leading, leading ? size.width * layout.leading : 0)
        .frame(width: size.width, height: size.height, alignment: leading ? .topLeading : .top)
        .foregroundStyle(.white.opacity(0.55))
        .shadow(color: .black.opacity(0.3), radius: 2)
        // The lock screen's layout doesn't mirror.
        .environment(\.layoutDirection, .leftToRight)
    }
}
