import AppKit
import SwiftUI

/// The settings window's tabs, in toolbar order. The raw value is the tab's position, which
/// `UpdateRelaunchState` saves across an update relaunch.
enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, performance, optimizations, assets, updates, privacy, permissions, diagnostics, plugins, about

    var id: Self { self }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(rawValue: String(describing: self))
    }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        guard let tab = Self.allCases.first(where: { $0.toolbarIdentifier == toolbarIdentifier }) else { return nil }
        self = tab
    }

    var title: LocalizedStringResource {
        switch self {
        case .general: return "General"
        case .performance: return "Performance"
        case .optimizations: return "Optimizations"
        case .assets: return "Assets"
        case .updates: return "Updates"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        case .diagnostics: return "Diagnostics"
        case .plugins: return "Plugins"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .performance: return "speedometer"
        case .optimizations: return "slider.horizontal.3"
        case .assets: return "shippingbox"
        case .updates: return "arrow.down.circle"
        case .privacy: return "hand.raised"
        case .permissions: return "lock.shield"
        case .diagnostics: return "stethoscope"
        case .plugins: return "puzzlepiece.extension"
        case .about: return "person.3"
        }
    }

    /// The width of this tab's item in the preference-style toolbar: its label plus the item's
    /// padding, and never narrower than the item's minimum. Items sit edge to edge.
    static func toolbarItemWidth(label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        return max(width + toolbarItemPadding, toolbarItemMinimumWidth)
    }

    /// The labels the toolbar shows, in the app's current language.
    static var toolbarLabels: [String] { allCases.map { String(localized: $0.title) } }

    /// The narrowest window at which every tab's toolbar item shows with no overflow chevron in
    /// the current language: the items' widths plus the toolbar's leading and trailing margins
    /// (which include the room the toolbar keeps before it overflows).
    static func toolbarFittingWidth(labels: [String] = toolbarLabels) -> CGFloat {
        ceil(labels.reduce(0) { $0 + toolbarItemWidth(label: $1) } + toolbarMargins)
    }

    /// The settings window's size when it first opens, with no saved frame: just wide enough
    /// for the toolbar (capped at the screen) and 80% of the screen's visible height.
    static func initialWindowSize(visibleFrame: NSRect, labels: [String] = toolbarLabels) -> NSSize {
        NSSize(width: min(toolbarFittingWidth(labels: labels), visibleFrame.width),
               height: visibleFrame.height * 0.8)
    }

    // Measured on the preference-style toolbar: an item is its label plus 12.5 pt, at least 55 pt.
    private static let toolbarItemPadding: CGFloat = 12.5
    private static let toolbarItemMinimumWidth: CGFloat = 55
    private static let toolbarMargins: CGFloat = 41

    /// The global settings this tab shows, for "Restore Defaults" and the changed-from-default dots.
    /// A setting belongs to one tab. Settings stored outside `GlobalSettings` (Sparkle's, the
    /// plugins') are reset by `SettingsTabReset`.
    var fields: [SettingField] {
        switch self {
        case .general:
            return [SettingField(\.autoStart), SettingField(\.language), SettingField(\.appearance),
                    SettingField(\.showInDock), SettingField(\.showInMenuBar),
                    SettingField(\.adjustMenuBarTint), SettingField(\.lockScreenPicture), SettingField(\.theming),
                    SettingField(\.screenshotResolution), SettingField(\.screenshotFolder),
                    SettingField(\.browseTransition)]
        case .performance:
            return [SettingField(\.otherApplicationFocused), SettingField(\.otherApplicationMaximized),
                    SettingField(\.otherApplicationFullscreen), SettingField(\.otherApplicationPlayingAudio),
                    SettingField(\.displayAsleep), SettingField(\.laptopOnBattery), SettingField(\.applicationRules),
                    SettingField(\.batteryQuality), SettingField(\.batteryQualityPreset), SettingField(\.batteryFrameRateCap),
                    SettingField(\.antiAliasing), SettingField(\.postProcessing), SettingField(\.textureResolution),
                    SettingField(\.sceneDetail), SettingField(\.renderResolution), SettingField(\.upscaling),
                    SettingField(\.renderScale), SettingField(\.shadows),
                    SettingField(\.volumetrics), SettingField(\.fps), SettingField(\.fpsSetByUser), SettingField(\.qualityEfficiency),
                    SettingField(\.particleBudget),
                    SettingField(\.reflections)]
        case .optimizations:
            return [SettingField(\.syncPropertiesAcrossDisplays), SettingField(\.videoFramework),
                    SettingField(\.videoReadMode),
                    SettingField(\.audioOutput), SettingField(\.reloadWhenChangingOutputDevice),
                    SettingField(\.audioRecordingThreshold), SettingField(\.audioRecordingDevice),
                    SettingField(\.audioRecordingVolume),
                    SettingField(\.mediaIntegration), SettingField(\.mediaBlocklist), SettingField(\.processPiority),
                    SettingField(\.pauseOnVRAMExhausted), SettingField(\.restartAfterCrashing),
                    SettingField(\.optimiseTextures), SettingField(\.cheaperShadows),
                    SettingField(\.webStandardResolution),
                    SettingField(\.reducedResolutionParticles)]
        case .diagnostics:
            return [SettingField(\.logLevel)]
        case .plugins:
            return [SettingField(\.screenSaver)]
        case .assets, .updates, .privacy, .permissions, .about:
            return []
        }
    }

    /// Whether the tab has anything "Restore Defaults" can reset.
    var isResettable: Bool {
        !fields.isEmpty || !SettingsTabReset.preferenceKeys(of: self).isEmpty
    }

    /// `settings` with this tab's settings back at their defaults and every other setting kept.
    func resetting(_ settings: GlobalSettings) -> GlobalSettings {
        var reset = settings
        let defaults = GlobalSettings()
        for field in fields { field.reset(&reset, defaults) }
        return reset
    }
}

/// One setting of `GlobalSettings`: whether it differs from its default, and how to put it back.
struct SettingField {
    let isChanged: (GlobalSettings) -> Bool
    let reset: (inout GlobalSettings, GlobalSettings) -> Void

    init<Value: Equatable>(_ keyPath: WritableKeyPath<GlobalSettings, Value>) {
        isChanged = { $0[keyPath: keyPath] != GlobalSettings()[keyPath: keyPath] }
        reset = { settings, defaults in settings[keyPath: keyPath] = defaults[keyPath: keyPath] }
    }
}
