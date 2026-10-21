import Foundation
import SwiftUI
import OWESceneEditing

/// The canvas's view options, Wallpaper Engine's editor View menu and toolbar (its UI's
/// `editorSettings` and `editorTemp`): the grid, the selection box, the particle systems'
/// collision shapes, the preview aspect ratio and Desktop and Phone Preview, and Low FPS
/// Simulation. The settings WE keeps between sessions are kept in `defaults`; the previews last
/// only while the window is open, as WE's do.
@MainActor
public final class EditorViewOptions: ObservableObject {
    /// The aspect ratios Desktop Preview frames (WE's `previewratio`).
    public enum PreviewRatio: String, CaseIterable, Sendable, Identifiable {
        case fourThree = "4x3", sixteenTen = "16x10", sixteenNine = "16x9", twentyOneNine = "21x9"

        public var id: String { rawValue }

        /// Width over height.
        public var aspect: Double {
            switch self {
            case .fourThree: return 4.0 / 3.0
            case .sixteenTen: return 16.0 / 10.0
            case .sixteenNine: return 16.0 / 9.0
            case .twentyOneNine: return 21.0 / 9.0
            }
        }

        /// As WE lists it: "16 : 9".
        public var title: String {
            switch self {
            case .fourThree: return "4 : 3"
            case .sixteenTen: return "16 : 10"
            case .sixteenNine: return "16 : 9"
            case .twentyOneNine: return "21 : 9"
            }
        }
    }

    /// Desktop Preview frames a display of `previewRatio`; Phone Preview a phone held upright
    /// (WE's "9 x 16").
    public enum Preview: String, Sendable {
        case desktop, phone
    }

    /// WE's Low FPS Simulation cap (wallpaperui.exe 0x140088b6e sets the preview's limit to 22).
    public static let lowFrameRate = 22

    @Published public var showsGrid: Bool { didSet { store(showsGrid, Keys.grid) } }
    @Published public var showsSelectionBox: Bool { didSet { store(showsSelectionBox, Keys.selectionBox) } }
    @Published public var showsParticleCollision: Bool { didSet { store(showsParticleCollision, Keys.particleCollision) } }
    @Published public var showsHitboxes: Bool { didSet { store(showsHitboxes, Keys.hitboxes) } }
    @Published public var previewRatio: PreviewRatio { didSet { defaults?.set(previewRatio.rawValue, forKey: Keys.previewRatio) } }
    @Published public var simulatesLowFrameRate: Bool { didSet { store(simulatesLowFrameRate, Keys.lowFrameRate) } }
    /// Desktop or Phone Preview, while one is on.
    @Published public var preview: Preview?
    /// Reset Camera's count: the canvas fits the scene again each time it changes.
    @Published public var resetCount = 0

    private let defaults: UserDefaults?

    private enum Keys {
        static let grid = "WallpaperEditorShowGrid"
        static let selectionBox = "WallpaperEditorShowSelectionBox"
        static let particleCollision = "WallpaperEditorShowParticleCollision"
        static let hitboxes = "WallpaperEditorShowHitboxes"
        static let previewRatio = "WallpaperEditorPreviewRatio"
        static let lowFrameRate = "WallpaperEditorLowFPSSimulation"
    }

    /// `defaults` keeps the settings between windows and launches (the app's own store); nil
    /// keeps them for the window only.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        showsGrid = defaults?.object(forKey: Keys.grid) as? Bool ?? false
        showsSelectionBox = defaults?.object(forKey: Keys.selectionBox) as? Bool ?? true
        showsParticleCollision = defaults?.object(forKey: Keys.particleCollision) as? Bool ?? false
        showsHitboxes = defaults?.object(forKey: Keys.hitboxes) as? Bool ?? false
        previewRatio = (defaults?.string(forKey: Keys.previewRatio)).flatMap(PreviewRatio.init(rawValue:)) ?? .sixteenNine
        simulatesLowFrameRate = defaults?.object(forKey: Keys.lowFrameRate) as? Bool ?? false
    }

    private func store(_ value: Bool, _ key: String) { defaults?.set(value, forKey: key) }

    /// The width over height the canvas frames while a preview is on.
    public var previewAspect: Double? {
        switch preview {
        case .desktop: return previewRatio.aspect
        case .phone: return 9.0 / 16.0
        case nil: return nil
        }
    }

    /// Turns `preview` on, or off when it is on already; one preview at a time (WE's
    /// `toggleDesktopPreview` and `togglePhonePreview`).
    public func toggle(_ preview: Preview) {
        self.preview = self.preview == preview ? nil : preview
    }

    /// The part of a `sceneSize` scene a display of `aspect` shows, as the wallpaper fills it:
    /// the largest centred rectangle of that shape (scene units, y up from the bottom-left).
    public static func visibleRect(sceneSize: SIMD2<Double>, aspect: Double) -> SceneRect {
        let sceneAspect = sceneSize.x / max(sceneSize.y, 1e-9)
        var size = sceneSize
        if aspect > sceneAspect { size.y = sceneSize.x / aspect } else { size.x = sceneSize.y * aspect }
        let origin = (sceneSize - size) / 2
        return SceneRect(minimum: origin, maximum: origin + size)
    }

    /// The grid's spacing in scene units at `pointsPerUnit`: the smallest of 10, 25, 50, 100,
    /// 250, 500 and 1000 units at least `minimumPoints` apart on the canvas.
    public static func gridSpacing(pointsPerUnit: Double, minimumPoints: Double = 24) -> Double {
        let steps: [Double] = [10, 25, 50, 100, 250, 500, 1000]
        return steps.first { $0 * pointsPerUnit >= minimumPoints } ?? steps[steps.count - 1]
    }
}
