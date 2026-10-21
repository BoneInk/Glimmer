import XCTest
@testable import OpenWallpaperEngine

/// Settings WE applies per frame don't rebuild the content (test-risks LR19, LR24): the
/// reflection copy (render flag 0x80), the bloom gate short of HDR (flag 0x40), the render
/// resolution and the scene detail. HDR, shadows, volumetrics, the particle budget and the texture
/// reduction are what a content is built for.
final class SceneRenderSettingsContentTests: XCTestCase {
    func testOnlyWhatTheContentIsBuiltForRebuildsIt() throws {
        let directory = Fixtures.url("Scenes/hdr")
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/hdr/project.json"))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        model.setRenderSettings(settings)
        let start = model.metalRevision

        settings.reflection.toggle()
        model.setRenderSettings(settings)
        settings.postProcessing = .disabled
        model.setRenderSettings(settings)
        settings.postProcessing = .enabled
        model.setRenderSettings(settings)
        settings.renderResolution = settings.renderResolution == .yourDisplay ? .uhd4K : .yourDisplay
        settings.sceneDetail = settings.sceneDetail == .full ? .matchDisplay : .full
        model.setRenderSettings(settings)
        XCTAssertEqual(model.metalRevision, start, "reflection, the bloom gate, resolution and detail apply per frame")

        for change in [{ (s: inout SceneRenderSettings) in s.postProcessing = .ultra },
                       { $0.shadows = .high }, { $0.volumetrics = .ultra }, { $0.particleBudget = .unlimited },
                       { $0.textureReduction = 2 }] {
            let before = model.metalRevision
            change(&settings)
            model.setRenderSettings(settings)
            XCTAssertEqual(model.metalRevision, before + 1, "\(settings): the content is built for it")
        }
    }
}
