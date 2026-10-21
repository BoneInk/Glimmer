import SwiftUI

/// WE's transition controls, for a playlist and for wallpapers chosen by hand: the transition,
/// its time and, for Random, the kinds it picks from (WE's pool, with Enable all and Disable all).
/// Goes inside a `Form` section.
struct WallpaperTransitionEditor: View {
    @Binding var settings: WallpaperTransitionSettings
    let label: LocalizedStringKey

    private typealias Choice = WallpaperTransitionSettings.Choice

    private static let sliderRange: ClosedRange<Double> =
        Double(WallpaperTransitionSettings.millisecondRange.lowerBound)...Double(WallpaperTransitionSettings.millisecondRange.upperBound)

    private static let poolColumns = [GridItem(.adaptive(minimum: 150), alignment: .leading)]

    var body: some View {
        Picker(label, selection: $settings.choice) {
            Text("None (reduce flicker)").tag(Choice.noneReducingFlicker)
            Text("None").tag(Choice.none)
            Text("Random").tag(Choice.random)
            Divider()
            ForEach(WallpaperTransitionKind.menuOrder) { kind in
                Text(kind.title).tag(Choice.kind(kind))
            }
        }
        LabeledContent("Transition time") {
            HStack {
                // No `step:` (AppKit would draw a tick per step); the binding snaps instead.
                Slider(value: milliseconds, in: Self.sliderRange)
                Text(Self.label(milliseconds: settings.milliseconds))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
                    .fixedSize()
            }
        }
        if settings.choice == .random {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Self.poolColumns, alignment: .leading, spacing: 6) {
                    ForEach(WallpaperTransitionKind.menuOrder) { kind in
                        Toggle(isOn: Binding(get: { settings.isInPool(kind) },
                                             set: { _ in settings.togglePool(kind) })) {
                            Text(kind.title)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Button("Enable all") { settings.setWholePool(true) }
                    Button("Disable all") { settings.setWholePool(false) }
                }
            }
        }
    }

    private var milliseconds: Binding<Double> {
        Binding(get: { Double(settings.milliseconds) },
                set: { settings.milliseconds = WallpaperTransitionSettings.snapped(Int($0.rounded())) })
    }

    /// The time in seconds, as "1.5 s" in English.
    static func label(milliseconds: Int, locale: Locale = .current) -> String {
        Measurement(value: Double(milliseconds) / 1000, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0...2)))
                .locale(locale))
    }
}
