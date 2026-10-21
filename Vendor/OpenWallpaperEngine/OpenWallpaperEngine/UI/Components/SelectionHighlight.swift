//
//  SelectionHighlight.swift
//  Open Wallpaper Engine
//

import AppKit
import OWETheming
import SwiftUI

/// Redraws its observers when the system accent colour changes, so a selection drawn in the
/// accent never stays in the old colour. It also holds Theming's tint of this process's windows
/// (`themeTint`), which `AppAccentTint` applies at each window's root.
final class SystemAccentColor: ObservableObject {
    static let shared = SystemAccentColor()

    /// Bumped on each change; the colour itself is read from `controlAccentColor` when drawn.
    @Published private(set) var revision = 0
    /// Theming's exact colour for Open Wallpaper Engine's own controls, selection and links
    /// (`ThemingSettings.appTint`); nil follows the system accent. Set by `ThemeTintSync`.
    @Published var themeTint: ThemeColor?
    private let center: NotificationCenter
    private let distributedCenter: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    /// Posted by System Settings (and the Theming settings) when the accent or highlight
    /// colour changes; AppKit refreshes `controlAccentColor` on it.
    static let colorPreferencesChanged = Notification.Name("AppleColorPreferencesChangedNotification")

    init(center: NotificationCenter = .default,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
        self.distributedCenter = distributedCenter
        let bump: (Notification) -> Void = { [weak self] _ in
            // A later main-queue turn, after AppKit has read the new preference.
            DispatchQueue.main.async { self?.revision &+= 1 }
        }
        tokens.append(center.addObserver(forName: NSColor.systemColorsDidChangeNotification,
                                         object: nil, queue: nil, using: bump))
        tokens.append(distributedCenter.addObserver(forName: Self.colorPreferencesChanged,
                                                    object: nil, queue: nil, using: bump))
    }

    deinit {
        tokens.prefix(1).forEach(center.removeObserver)
        tokens.dropFirst().forEach(distributedCenter.removeObserver)
    }
}

/// The one selection indicator of a tile: an accent stroke inside the tile's rounded shape over a
/// faint accent tint, in Theming's tint when it has one. It never uses the highlight colour.
struct SelectionHighlight: ViewModifier {
    var isSelected: Bool
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 3
    @ObservedObject private var accent = SystemAccentColor.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let color = accent.themeTint.map(Color.init(themeColor:)) ?? Color(nsColor: .controlAccentColor)
        content
            .overlay {
                if isSelected {
                    shape.fill(color.opacity(0.12))
                        .overlay(shape.strokeBorder(color, lineWidth: lineWidth))
                        .allowsHitTesting(false)
                        // Keyed on the revision so an accent change redraws it.
                        .id(accent.revision)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// Marks the selected tile; see `SelectionHighlight`.
    func selectionHighlight(_ isSelected: Bool, cornerRadius: CGFloat, lineWidth: CGFloat = 3) -> some View {
        modifier(SelectionHighlight(isSelected: isSelected, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

#Preview("Selection highlight") { // l10n-ignore: Xcode preview name, not UI text
    HStack(spacing: 8) {
        ForEach([true, false], id: \.self) { selected in
            Rectangle()
                .fill(.linearGradient(colors: [.indigo, .orange], startPoint: .top, endPoint: .bottom))
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .selectionHighlight(selected, cornerRadius: 8)
        }
    }
    .padding()
}
