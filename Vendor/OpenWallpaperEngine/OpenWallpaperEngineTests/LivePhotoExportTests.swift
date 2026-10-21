import AppKit
import simd
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// The iPhone & iPad Export mode: the device table, the device combo box's search, the lock-screen
/// guide, the isolated session (edits there never reach the desktop) and the Export Settings
/// reaching the export's job.
final class LivePhotoExportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!

    private static let project = """
    {"file": "scene.json", "title": "Export Me", "type": "scene", "workshopid": "515151",
     "general": {"properties": {
       "speed": {"type": "slider", "text": "Speed", "value": 0.25, "min": 0, "max": 1}
     }}}
    """

    override func setUpWithError() throws {
        suite = "owe-livephoto-export-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.project.utf8).write(to: directory.appending(path: "project.json"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    private func wallpaper() throws -> WEWallpaper {
        WEWallpaper(using: try decodeTolerant(WEProject.self, from: Data(Self.project.utf8)), where: directory)
    }

    private func save(_ values: [String: String], _ scope: WallpaperPropertyScope, of wallpaper: WEWallpaper) {
        let identity = WallpaperSettingsIdentity.resolve(wallpaper)
        defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
        defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
    }

    private func stored(_ scope: WallpaperPropertyScope, of wallpaper: WEWallpaper) -> [String: String]? {
        defaults.dictionary(forKey: WallpaperSettingsIdentity.resolve(wallpaper).key(.userProperties, scope: scope)) as? [String: String]
    }

    // MARK: Device table

    func testDeviceTableIsUniqueValidAndNewestFirst() {
        let all = DeviceModel.all
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "device names repeat")
        for device in all {
            XCTAssertGreaterThan(device.pixelSize.x, 0, device.name)
            XCTAssertGreaterThan(device.pixelSize.y, device.pixelSize.x, "\(device.name) isn't portrait")
            XCTAssertGreaterThanOrEqual(device.year, 2017, device.name)
            XCTAssertTrue(device.name.hasPrefix(device.family.name), device.name)
        }
        for index in all.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(all[index - 1].year, all[index].year, "\(all[index].name) is out of order")
        }
        let iPhones = all.filter { $0.family == .iPhone }
        let iPads = all.filter { $0.family == .iPad }
        XCTAssertGreaterThanOrEqual(iPhones.count, 30)
        XCTAssertGreaterThanOrEqual(iPads.count, 25)
        // iOS 17's oldest iPhones and iPadOS 17's oldest iPads are in.
        for name in ["iPhone XR", "iPhone XS", "iPhone SE (2nd generation)", "iPad (6th generation)",
                     "iPad Pro 10.5-inch", "iPad Pro 12.9-inch (2nd generation)", "iPad mini (5th generation)"] {
            XCTAssertEqual(DeviceModel.model(id: name).name, name)
        }
    }

    func testOnlyIPadsTurnToLandscape() throws {
        let iPad = DeviceModel.model(id: "iPad Pro 13-inch (M5)")
        let portrait: SIMD2<Int> = SIMD2(2064, 2752)
        let landscape: SIMD2<Int> = SIMD2(2752, 2064)
        XCTAssertEqual(iPad.pixelSize, portrait)
        XCTAssertEqual(try XCTUnwrap(iPad.landscapePixelSize), landscape)
        XCTAssertNil(DeviceModel.model(id: "iPhone 17 Pro Max").landscapePixelSize)
    }

    // MARK: Combo box search

    func testSearchMatchesNameFamilyYearAndResolution() {
        let all = DeviceModel.all
        XCTAssertEqual(DeviceModelSearch.filter(all, query: ""), all)
        XCTAssertEqual(DeviceModelSearch.filter(all, query: "   "), all)
        XCTAssertTrue(DeviceModelSearch.filter(all, query: "ipad").allSatisfy { $0.family == .iPad })
        XCTAssertTrue(DeviceModelSearch.filter(all, query: "2025").allSatisfy { $0.year == 2025 })
        let byResolution = DeviceModelSearch.filter(all, query: "1320x2868").map(\.name)
        XCTAssertEqual(byResolution, ["iPhone 17 Pro Max", "iPhone 16 Pro Max"])
        XCTAssertEqual(DeviceModelSearch.filter(all, query: "1320 × 2868").map(\.name), byResolution)
        XCTAssertEqual(DeviceModelSearch.filter(all, query: "2868x1320").map(\.name), byResolution)
        XCTAssertEqual(DeviceModelSearch.filter(all, query: "Pro Max 2024").map(\.name), ["iPhone 16 Pro Max"])
        XCTAssertEqual(DeviceModelSearch.filter(all, query: "mini A17").map(\.name), ["iPad mini (A17 Pro)"])
        XCTAssertTrue(DeviceModelSearch.filter(all, query: "nokia").isEmpty)
    }

    func testSearchResultsAreGroupedIPhoneFirstInTableOrder() {
        let matches = DeviceModelSearch.filter(DeviceModel.all, query: "air")
        let groups = DeviceModelSearch.groups(matches)
        XCTAssertEqual(groups.map(\.family), [.iPhone, .iPad])
        XCTAssertEqual(groups[0].models.map(\.name), ["iPhone Air"])
        XCTAssertEqual(groups[1].models, matches.filter { $0.family == .iPad })
        XCTAssertEqual(DeviceModelSearch.groups(DeviceModelSearch.filter(DeviceModel.all, query: "ipad")).map(\.family), [.iPad])
        XCTAssertTrue(DeviceModelSearch.groups([]).isEmpty)
    }

    // MARK: Lock-screen guide

    func testGuideFollowsTheDeviceAndOrientation() {
        let phone = LockScreenLayout.layout(for: .iPhone, landscape: false)
        let padPortrait = LockScreenLayout.layout(for: .iPad, landscape: false)
        let padLandscape = LockScreenLayout.layout(for: .iPad, landscape: true)
        XCTAssertEqual(phone.alignment, .center)
        XCTAssertEqual(padPortrait.alignment, .center)
        XCTAssertEqual(padLandscape.alignment, .leading)
        XCTAssertLessThan(padPortrait.clockSize, phone.clockSize)
        XCTAssertEqual(LockScreenLayout.layout(for: .iPhone, landscape: true), phone)
    }

    // MARK: Isolation

    /// Edits in the export mode go to its isolated store and private instance only: the shared
    /// store's saved values and the shared running values stay as they were, no display regroups,
    /// and ending the session leaves nothing behind.
    @MainActor
    func testExportEditsLeaveTheSharedInstanceAndStoredPropertiesUnchanged() throws {
        let wallpaper = try wallpaper()
        let visibility = sceneObjectVisibilityKey(objectID: 3)
        let shared: [String: String] = ["speed": "0.25", visibility: "true"]
        save(shared, .shared, of: wallpaper)
        let sharedKey = WallpaperPropertyScope.shared.runtimeKey(directory: wallpaper.settingsDirectory)
        WallpaperServices.shared.setUserProperties(shared, wallpaper: sharedKey, replacing: true)

        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: LivePhotoExportModel.purpose,
                                               seededFrom: [.shared], defaults: defaults)
        XCTAssertEqual(session.values, shared)
        XCTAssertNotEqual(session.instanceKey, WallpaperInstanceKey(wallpaper))
        XCTAssertNotEqual(session.runtimeKey, sharedKey)

        let regrouped = expectation(forNotification: .wallpaperPropertiesDidSave, object: nil)
        regrouped.isInverted = true
        // A layer hidden and a property changed in the mode, as its panel does, and through the
        // stores the editor's models write (`WallpaperPropertyTargets` on the session's scope).
        session.setLayerVisible(false, objectID: 3)
        session.setValues(["speed": "0.9"])
        let editor = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [session.scope])
        var edited = session.values
        edited["_owe_scene_object_3_scale"] = "2 2 1"
        editor.publish(edited)
        editor.save(edited, defaults: defaults)
        wait(for: [regrouped], timeout: 0.3)

        XCTAssertEqual(stored(.shared, of: wallpaper), shared)
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: sharedKey), shared)
        let running = WallpaperServices.shared.userProperties(wallpaper: session.runtimeKey)
        XCTAssertEqual(running["speed"], "0.9")
        XCTAssertEqual(running[visibility], "false")
        XCTAssertEqual(session.layerEdits, [visibility: "false", "_owe_scene_object_3_scale": "2 2 1"])
        XCTAssertEqual(session.properties, ["speed": "0.9"])
        // The private instance runs in the session's own registry, never the displays'.
        XCTAssertNil(session.instances.instance(for: WallpaperInstanceKey(wallpaper)))

        // The export renders the isolated values.
        let model = LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults)
        XCTAssertEqual(model.exportProperties, session.values)

        session.end()
        XCTAssertNil(stored(session.scope, of: wallpaper))
        XCTAssertTrue(WallpaperServices.shared.userProperties(wallpaper: session.runtimeKey).isEmpty)
        XCTAssertEqual(stored(.shared, of: wallpaper), shared)
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: sharedKey), shared)
        session.setValues(["speed": "0.1"])
        XCTAssertNil(stored(session.scope, of: wallpaper), "an ended session writes nothing")
    }

    /// The copy starts from the store the editor showed: a display's own when it has one.
    @MainActor
    func testSessionIsSeededFromTheEditedDisplaysStore() throws {
        let wallpaper = try wallpaper()
        save(["speed": "0.25"], .shared, of: wallpaper)
        save(["speed": "0.6"], .display("2"), of: wallpaper)
        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: "seed-test", seededFrom: [.display("2")],
                                               defaults: defaults)
        XCTAssertEqual(session.values, ["speed": "0.6"])
        session.end()
        XCTAssertEqual(stored(.display("2"), of: wallpaper), ["speed": "0.6"])
    }

    // MARK: Export Settings into the export

    @MainActor
    func testExportSettingsReachTheExportJob() throws {
        let wallpaper = try wallpaper()
        save(["speed": "0.25"], .shared, of: wallpaper)
        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: "settings-test", seededFrom: [.shared],
                                               defaults: defaults)
        defer { session.end() }
        session.setValues(["speed": "0.75", sceneObjectVisibilityKey(objectID: 9): "false"])
        let model = LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults)
        let iPad = DeviceModel.model(id: "iPad Air 13-inch (M3)")
        model.device = iPad
        model.zoom = 2
        model.clipLength = 2
        model.clipStart = 3
        model.quality = .smaller
        model.pan(by: SIMD2(40, -20))
        model.setParallaxPosition(SIMD2(0.2, 0.75))

        let settings = model.settings
        XCTAssertEqual(settings.parallaxPosition, SIMD2(0.2, 0.75))
        let files = LivePhotoHelper.Files(directory: directory, still: directory.appending(path: "a.HEIC"),
                                          movie: directory.appending(path: "a.MOV"), identifier: "id")
        let job = LivePhotoHelper.exportJob(wallpaper, properties: model.exportProperties, settings: settings, files: files)
        let decoded = try JSONDecoder().decode(LivePhotoJob.self, from: JSONEncoder().encode(job))
        let crop = try XCTUnwrap(decoded.crop)
        XCTAssertEqual(crop.outputPixels, iPad.pixelSize)
        XCTAssertEqual(crop, settings.crop)
        XCTAssertEqual(crop.zoom, 2)
        XCTAssertEqual(decoded.clip.length, 2, accuracy: 1e-9)
        XCTAssertEqual(decoded.clip.start, 3, accuracy: 1e-9)
        XCTAssertEqual(decoded.qualityLevel, .smaller)
        XCTAssertEqual(decoded.pointer, SIMD2(0.2, 0.75))
        XCTAssertEqual(decoded.properties, session.values)
        XCTAssertEqual(decoded.properties["speed"], "0.75")
        XCTAssertEqual(decoded.still?.path(percentEncoded: false), files.still.path(percentEncoded: false))
        XCTAssertEqual(decoded.movie.path(percentEncoded: false), files.movie.path(percentEncoded: false))

        // The device chosen is the next model's too, and the wallpaper's parallax position.
        let next = LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults)
        XCTAssertEqual(next.device, iPad)
        XCTAssertEqual(next.parallaxPosition, SIMD2(0.2, 0.75))
        XCTAssertEqual(LivePhotoParallax.position(for: wallpaper, defaults: defaults), SIMD2(0.2, 0.75))
        // Held inside the scene; back at the centre, nothing is stored.
        next.setParallaxPosition(SIMD2(-1, 3))
        XCTAssertEqual(next.parallaxPosition, SIMD2(0, 1))
        next.setParallaxPosition(LivePhotoParallax.centre)
        XCTAssertNil(defaults.object(forKey: LivePhotoParallax.positionKey(next.identity)))
        XCTAssertEqual(LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults).parallaxPosition,
                       LivePhotoParallax.centre)
    }

    /// The preview's private instance and the export's renderer hold the same pointer: the panel's
    /// parallax position, through the export job.
    @MainActor
    func testPreviewAndExportJobGetTheSamePointer() throws {
        let wallpaper = try wallpaper()
        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: "pointer-test", seededFrom: [.shared],
                                               defaults: defaults)
        defer { session.end() }
        let model = LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults)
        XCTAssertEqual(model.presentation, LivePhotoRenderer.presentation())
        model.setParallaxPosition(SIMD2(0.3, 0.9))

        let files = LivePhotoHelper.Files(directory: directory, still: directory.appending(path: "a.HEIC"),
                                          movie: directory.appending(path: "a.MOV"), identifier: "id")
        let job = LivePhotoHelper.exportJob(wallpaper, properties: model.exportProperties, settings: model.settings, files: files)
        let decoded = try JSONDecoder().decode(LivePhotoJob.self, from: JSONEncoder().encode(job))
        let previewRenderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm))
        let exportRenderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm))
        model.presentation.apply(to: previewRenderer)
        LivePhotoRenderer.configure(exportRenderer, pointer: decoded.pointer)
        XCTAssertEqual(previewRenderer.fixedPointer, SIMD2<Float>(0.3, 0.9))
        XCTAssertEqual(exportRenderer.fixedPointer, previewRenderer.fixedPointer)
        XCTAssertEqual(model.presentation, LivePhotoRenderer.presentation(pointer: decoded.pointer))
    }

    @MainActor
    func testExportIsConfirmedInTheSettingsSheet() throws {
        let session = IsolatedSceneEditSession(wallpaper: try wallpaper(), purpose: "sheet-test", seededFrom: [.shared],
                                               defaults: defaults)
        defer { session.end() }
        let model = LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults)
        model.requestExport(.save)
        XCTAssertEqual(model.sheet, .confirm(.save))
        model.sheet = nil
        model.showSettings()
        XCTAssertEqual(model.sheet, .settings)
    }

    // MARK: What the preview shows is what is exported

    /// A test card through both paths, for an iPhone and an iPad, zoomed and panned: the preview
    /// (the lock-screen view's geometry, `LockScreenPreview.layout`, over the private instance's
    /// renderer drawn as `LivePhotoRenderer.presentation(pointer:)` says, at a Retina view's pixels, with
    /// the mouse in a corner) and the export (`LivePhotoRenderer.viewport` cut by
    /// `LivePhotoCrop.outputImage`) put the marker at the same place, within 1% of the picture,
    /// with camera parallax off and on, and on with the pointer held away from the centre
    /// (Parallax Position).
    @MainActor
    func testPreviewAndExportFrameTheSameWithAndWithoutParallax() throws {
        let sceneSize = SIMD2<Double>(1600, 900)
        let marker = SIMD2<Double>(1150, 600)  // Scene units, origin top-left.
        let moved = SIMD2<Double>(0.15, 0.8)
        for (parallax, pointer) in [(false, LivePhotoParallax.centre), (true, LivePhotoParallax.centre), (true, moved)] {
            let content = try Self.testCard(sceneSize: sceneSize, marker: marker, parallax: parallax)
            XCTAssertEqual(LivePhotoParallax.followsPointer(content), parallax)
            for name in ["iPhone 17 Pro", "iPad Pro 11-inch (M5)"] {
                let device = DeviceModel.model(id: name)
                XCTAssertEqual(device.name, name)
                var crop = LivePhotoCrop(sceneSize: sceneSize, outputPixels: device.pixelSize)
                crop.setZoom(1.6)
                crop.setCenter(SIMD2(1080, 520))

                let exported = try XCTUnwrap(crop.outputImage(from: try render(content, LivePhotoRenderer.viewport(for: crop),
                                                                                  pixels: crop.renderPixelSize) {
                    LivePhotoRenderer.configure($0, pointer: pointer)
                }))
                XCTAssertEqual(exported.width, device.pixelSize.x)
                XCTAssertEqual(exported.height, device.pixelSize.y)
                let previewed = try preview(content, crop: crop, fixed: true, pointer: pointer)
                let exportMarker = try XCTUnwrap(Self.markerCentre(in: exported), "\(name): marker in the export")
                let previewMarker = try XCTUnwrap(Self.markerCentre(in: previewed), "\(name): marker in the preview")
                let label = "\(name), parallax \(parallax), pointer \(pointer)"
                XCTAssertEqual(previewMarker.x, exportMarker.x, accuracy: 0.01, label)
                XCTAssertEqual(previewMarker.y, exportMarker.y, accuracy: 0.01, label)
                if !parallax {
                    // Where the crop says (the parallax moves an off-centre layer even at the centre).
                    let window = crop.cropRect
                    let expected = SIMD2((marker.x - window.minX) / window.width, (marker.y - window.minY) / window.height)
                    XCTAssertEqual(exportMarker.x, expected.x, accuracy: 0.01, label)
                    XCTAssertEqual(exportMarker.y, expected.y, accuracy: 0.01, label)
                } else if pointer == LivePhotoParallax.centre {
                    // Following the mouse instead, the preview would move the marker away.
                    let following = try XCTUnwrap(Self.markerCentre(in: try preview(content, crop: crop, fixed: false)))
                    XCTAssertGreaterThan(simd_length(following - exportMarker), 0.02, label)
                } else {
                    // The moved pointer moves the marker away from where the centre puts it.
                    let centred = try XCTUnwrap(Self.markerCentre(in: try preview(content, crop: crop, fixed: true)))
                    XCTAssertGreaterThan(simd_length(centred - exportMarker), 0.02, label)
                }
            }
        }
    }

    // MARK: The crop reaches every edge

    /// A tall iPhone, an iPad and the same iPad turned.
    private static let edgeDevices: [(name: String, landscape: Bool)] = [
        ("iPhone 17 Pro Max", false), ("iPad Pro 13-inch (M5)", false), ("iPad Pro 13-inch (M5)", true),
    ]

    /// Panned as far as it goes each way, at zoom 1 and 2, in a landscape and a portrait scene,
    /// the window's edge is the scene's.
    func testPanReachesEachEdgeOfTheScene() {
        for scene in [SIMD2<Double>(1600, 900), SIMD2(900, 1600)] {
            for (name, landscape) in Self.edgeDevices {
                for zoom in [1.0, 2.0] {
                    let label = "\(name)\(landscape ? " landscape" : ""), zoom \(zoom), scene \(scene)"
                    var crop = LivePhotoCrop(sceneSize: scene, outputPixels: DeviceModel.model(id: name).pixelSize, zoom: zoom)
                    func window() -> CGRect { landscape ? crop.landscapeRect : crop.cropRect }
                    crop.pan(by: SIMD2(-100_000, 0))
                    XCTAssertEqual(window().minX, 0, accuracy: 1e-9, label)
                    crop.pan(by: SIMD2(100_000, 0))
                    XCTAssertEqual(window().maxX, scene.x, accuracy: 1e-9, label)
                    // The portrait window reaches the top and bottom; turned, an iPad shows its middle band.
                    crop.pan(by: SIMD2(0, -100_000))
                    XCTAssertEqual(crop.cropRect.minY, 0, accuracy: 1e-9, label)
                    XCTAssertEqual(window().midY, crop.cropRect.midY, accuracy: 1e-9, label)
                    crop.pan(by: SIMD2(0, 100_000))
                    XCTAssertEqual(crop.cropRect.maxY, scene.y, accuracy: 1e-9, label)
                    XCTAssertEqual(window().midY, crop.cropRect.midY, accuracy: 1e-9, label)
                }
            }
        }
    }

    /// Panned as far as it goes each way, the lock-screen view shows the scene's edge at the
    /// screen's: a card with a coloured stripe on each side, placed in the screen as the view
    /// places the scene (`LockScreenPreview.pinned`), has the left stripe in the screen's first
    /// column when panned far left, and so on.
    @MainActor
    func testPreviewShowsTheScenesEdgeAtEachEnd() throws {
        let scene = SIMD2<Double>(1600, 900)
        let stripes: [(edge: Edge, color: SIMD3<Int>)] = [
            (.leading, SIMD3(255, 0, 0)), (.trailing, SIMD3(0, 0, 255)), (.top, SIMD3(0, 255, 0)), (.bottom, SIMD3(255, 255, 0)),
        ]
        func stripe(_ edge: Edge) -> some View {
            let color = stripes.first { $0.edge == edge }!.color
            let across = edge == .leading || edge == .trailing
            return Color(.sRGB, red: Double(color.x) / 255, green: Double(color.y) / 255, blue: Double(color.z) / 255)
                .frame(width: across ? 3 : nil, height: across ? nil : 3)
                .padding(across ? .vertical : .horizontal, 6)
        }
        let card = Color.gray
            .overlay(alignment: .leading) { stripe(.leading) }
            .overlay(alignment: .trailing) { stripe(.trailing) }
            .overlay(alignment: .top) { stripe(.top) }
            .overlay(alignment: .bottom) { stripe(.bottom) }
        for (name, landscape) in Self.edgeDevices {
            for zoom in [1.0, 2.0] {
                var crop = LivePhotoCrop(sceneSize: scene, outputPixels: DeviceModel.model(id: name).pixelSize, zoom: zoom)
                // Turned, an iPad shows the portrait window's middle band, never its top or bottom.
                for (edge, color) in stripes where !landscape || edge == .leading || edge == .trailing {
                    switch edge {
                    case .leading: crop.pan(by: SIMD2(-100_000, 0))
                    case .trailing: crop.pan(by: SIMD2(100_000, 0))
                    case .top: crop.pan(by: SIMD2(0, -100_000))
                    case .bottom: crop.pan(by: SIMD2(0, 100_000))
                    }
                    let window = landscape ? crop.landscapeRect : crop.cropRect
                    let space = landscape ? CGSize(width: 640, height: 420) : CGSize(width: 420, height: 640)
                    let layout = LockScreenPreview.layout(window: window, sceneSize: scene, in: space)
                    let screen = ZStack(alignment: .topLeading) {
                        Color.black
                        LockScreenPreview.pinned(card, size: layout.sceneViewSize, at: layout.sceneViewOffset, in: layout.frame)
                    }
                    .frame(width: layout.frame.width, height: layout.frame.height)
                    .clipped()
                    let renderer = ImageRenderer(content: screen)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    let point: SIMD2<Int> = switch edge {
                    case .leading: SIMD2(0, image.height / 2)
                    case .trailing: SIMD2(image.width - 1, image.height / 2)
                    case .top: SIMD2(image.width / 2, 0)
                    case .bottom: SIMD2(image.width / 2, image.height - 1)
                    }
                    let pixel = try XCTUnwrap(Self.pixel(in: image, at: point))
                    let label = "\(name)\(landscape ? " landscape" : ""), zoom \(zoom), \(edge): \(pixel)"
                    let difference = pixel &- color
                    XCTAssertLessThanOrEqual(max(abs(difference.x), abs(difference.y), abs(difference.z)), 40, label)
                }
            }
        }
    }

    /// Panned as far as it goes left (right), the export's first (last) column is the scene's: a
    /// marker centred on the scene's left (right) edge shows in it.
    @MainActor
    func testExportOfAnEdgeCropContainsTheScenesEdgeColumn() throws {
        let scene = SIMD2<Double>(1600, 900)
        for left in [true, false] {
            let content = try Self.testCard(sceneSize: scene, marker: SIMD2(left ? 0 : scene.x, 450), parallax: false)
            for name in ["iPhone 17 Pro Max", "iPad Pro 13-inch (M5)"] {
                for zoom in [1.0, 2.0] {
                    var crop = LivePhotoCrop(sceneSize: scene, outputPixels: DeviceModel.model(id: name).pixelSize, zoom: zoom)
                    crop.pan(by: SIMD2(left ? -100_000 : 100_000, 0))
                    let exported = try XCTUnwrap(crop.outputImage(from: try render(content, LivePhotoRenderer.viewport(for: crop),
                                                                                      pixels: crop.renderPixelSize) {
                        LivePhotoRenderer.configure($0)
                    }))
                    let row = Int((450 - crop.cropRect.minY) / crop.cropRect.height * Double(exported.height))
                    let pixel = try XCTUnwrap(Self.pixel(in: exported, at: SIMD2(left ? 0 : exported.width - 1, row)))
                    let label = "\(name), zoom \(zoom), \(left ? "left" : "right"): \(pixel)"
                    XCTAssertGreaterThan(pixel.x, 180, label)
                    XCTAssertLessThan(pixel.y, 90, label)
                    XCTAssertLessThan(pixel.z, 90, label)
                }
            }
        }
    }

    /// The sRGB red, green and blue of `image` at `point` (pixels, origin top-left).
    private static func pixel(in image: CGImage, at point: SIMD2<Int>) -> SIMD3<Int>? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -point.x, y: point.y - image.height + 1, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return SIMD3(Int(data[0]), Int(data[1]), Int(data[2]))
    }

    /// The preview's picture: the scene drawn into the lock-screen view's scene view (2 pixels a
    /// point, the mouse at its bottom-left corner) and the screen's frame cut out of it.
    @MainActor
    private func preview(_ content: SceneMetalContent, crop: LivePhotoCrop, fixed: Bool,
                         pointer: SIMD2<Double> = LivePhotoParallax.centre) throws -> CGImage {
        let layout = LockScreenPreview.layout(window: crop.cropRect, sceneSize: crop.sceneSize,
                                              in: CGSize(width: 420, height: 640))
        let points = SIMD2(Float(layout.sceneViewSize.width), Float(layout.sceneViewSize.height))
        let pixels = SIMD2(Int((points.x * 2).rounded()), Int((points.y * 2).rounded()))
        let viewport = SceneViewport(drawableSize: SIMD2(Float(pixels.x), Float(pixels.y)), pointSize: points,
                                     cursor: SIMD2(4, 4), frameRateLimit: 30)
        let frame = try render(content, viewport, pixels: pixels) { renderer in
            LivePhotoRenderer.presentation(pointer: pointer).apply(to: renderer)
            if !fixed { renderer.fixedPointer = nil }
        }
        let rect = CGRect(x: -layout.sceneViewOffset.x * 2, y: -layout.sceneViewOffset.y * 2,
                          width: layout.frame.width * 2, height: layout.frame.height * 2).integral
        return try XCTUnwrap(frame.cropping(to: rect))
    }

    @MainActor
    private func render(_ content: SceneMetalContent, _ viewport: SceneViewport, pixels: SIMD2<Int>,
                        configure: (SceneMetalRenderer) -> Void) throws -> CGImage {
        let renderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm))
        defer { renderer.releaseContent() }
        configure(renderer)
        renderer.wallTime = { 1000 }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(10)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent)
        for step in 1...6 {
            renderer.wallTime = { 1000 + Double(step) / 30 }
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        let captured = expectation(description: "captured")
        nonisolated(unsafe) var image: CGImage?  // Written once by the completion, read after the wait.
        XCTAssertTrue(renderer.captureSharedFrame(pixelSize: pixels, pixelsPerPoint: viewport.pixelsPerPoint) {
            image = $0
            captured.fulfill()
        })
        wait(for: [captured], timeout: 10)
        return try XCTUnwrap(image)
    }

    /// A grey scene with a red square centred on `marker` (scene units, origin top-left), parallax
    /// depth 1 on the square.
    private static func testCard(sceneSize: SIMD2<Double>, marker: SIMD2<Double>, parallax: Bool) throws -> SceneMetalContent {
        let size = SIMD2(Float(sceneSize.x), Float(sceneSize.y))
        func layer(_ id: String, _ image: NSImage, position: SIMD2<Float>, size: SIMD2<Float>, depth: SIMD3<Float>,
                   order: Int) -> SceneMetalLayer {
            var layer = SceneMetalLayer(
                id: id, name: id, source: .image(image), position: position, size: size, scale: SIMD2(1, 1), opacity: 1,
                brightness: 1, color: SIMD4(repeating: 1), text: nil, parallaxDepth: depth, perspective: false, rotation: 0)
            layer.order = order
            return layer
        }
        // Layer positions are scene units with y up.
        let square = SIMD2(Float(marker.x), size.y - Float(marker.y))
        var content = SceneMetalContent(
            size: size,
            layers: [layer("1", try solid(128, 128, 128), position: size / 2, size: size, depth: .zero, order: 0),
                     layer("2", try solid(255, 0, 0), position: square, size: SIMD2(40, 40), depth: SIMD3(1, 1, 0), order: 1)],
            particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        content.camera.parallax = parallax
        content.camera.parallaxAmount = 0.05
        content.camera.parallaxMouseInfluence = 1
        content.camera.parallaxDelay = 0
        return content
    }

    private static func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) throws -> NSImage {
        let pixel: [UInt8] = [red, green, blue, 255]
        let bytes: [UInt8] = Array(repeating: pixel, count: 16).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 4, height: 4))
    }

    /// The red square's centre in `image`, as a fraction of its size from the top-left.
    private static func markerCentre(in image: CGImage) -> SIMD2<Double>? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var sum = SIMD2<Double>(0, 0), count = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if data[i] > 180, data[i + 1] < 90, data[i + 2] < 90 {
                    sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        return SIMD2(sum.x / count / Double(width), sum.y / count / Double(height))
    }
}
