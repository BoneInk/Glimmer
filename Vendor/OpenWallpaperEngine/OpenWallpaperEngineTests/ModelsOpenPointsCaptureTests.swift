import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// docs/models-plan.md §5.13, 5.14, 5.15, 5.16, 5.17 and 5.19 against WE 2.8.0.42's captures
/// (we-test-wp-images 4e82eed, tools/peer/requests/owe-beta3/models-open: a README per point and
/// the stills in `shots/`, built by `build_variants.py`). Every project is a 1920×1080
/// orthographic scene whose image is 1024 px square at scale 0.85; the Windows taskbar covers
/// the bottom 48 rows of each still.
///
/// The geometry is checked against the numbers measured off the stills. With `OWE_WE_REFERENCE`
/// pointing at the captures' `tools/peer` folder, the stills themselves are measured too.
final class ModelsOpenPointsCaptureTests: XCTestCase {
    private static let screen = SIMD2<Float>(1920, 1080)
    private static let taskbar = 48
    private static let imageSize = SIMD2<Float>(1024, 1024)

    /// Inclusive pixel bounds on the screen, from the top-left, as the stills are measured.
    struct PixelBox: Equatable, CustomStringConvertible {
        var minX: Int, maxX: Int, minY: Int, maxY: Int

        var description: String { "x \(minX)–\(maxX), y \(minY)–\(maxY)" }
    }

    // MARK: - 5.13 A root without `origin`

    /// The control (`origin` "960 540 0") spans x 525–1394, y 105–974; without `origin` the image
    /// is centred on scene (0, 0), the bottom-left corner, and only its upper-right quarter shows:
    /// x 0–434, y 645 down to the taskbar.
    func testRootWithoutOriginIsCentredOnTheBottomLeftCorner() throws {
        let control = try box(imageObjects(#"{"id": 10, "origin": "960 540 0", "scale": "0.85 0.85 1"}"#), id: "10")
        assertBox(control, PixelBox(minX: 525, maxX: 1394, minY: 105, maxY: 974), "control")
        let noOrigin = try box(imageObjects(#"{"id": 10, "scale": "0.85 0.85 1"}"#), id: "10")
        assertBox(noOrigin, PixelBox(minX: 0, maxX: 434, minY: 645, maxY: 1031), "no origin")
        try assertStill("mo_513_control", control)
        try assertStill("mo_513_noorigin", noOrigin)
    }

    /// What §5.13 moves: every root object without `origin` in the repository's fixture scenes,
    /// which sat at the scene's centre before and sits at 0 now, as in WE's capture. None of the
    /// tests reading these scenes checks where those objects are drawn (the lights, the
    /// composelayer and the label are decoded or counted, not placed). A change to the list shows
    /// here first. With the library present (`LibrarySweepTests.libraryRoot`), its orthographic
    /// scenes' such objects are listed too, as an attachment and in the log, for the impact.
    func testRootsWithoutOriginInTheFixtureScenes() throws {
        let found = try Self.rootsWithoutOrigin(under: Fixtures.root, relativeTo: Fixtures.root, orthographicOnly: false)
        XCTAssertEqual(found, [
            "Library/installed/3000000003/scene.json #- [none]",
            "Models/OpenPoints/510-text-depth-disabled/scene.json #17 rootmotion_box [model]",
            "Models/OpenPoints/510-text-depth-enabled/scene.json #17 rootmotion_box [model]",
            "Models/OpenPoints/511-missing-attribute/scene.json #17 rootmotion_box [model]",
            "Models/OpenPoints/518-alpha/scene.json #17 rootmotion_box [model]",
            "SceneScript/replay/failures/scene.json #3 Label [text]",
            "Scenes/lights/scene.json #900 [light]",
            "Scenes/lights/scene.json #901 [light]",
            "Scenes/multipass/scene.json #1 Layer [image]",
            "Scenes/scripted-objects/scene.json #2 Tone [sound]",
            "Scenes/start-frame/scene.json #9 Motion blur [image]",
            "Timeline/animation-set-scene.json #- Sparks [particle]",
            "Timeline/animation-set-scene.json #12 Thumbnail [image]",
            "Workshop/wallpaper/scene.json #- [none]",
        ], found.joined(separator: "\n"))

        let library = LibrarySweepTests.libraryRoot
        guard FileManager.default.fileExists(atPath: library.path) else { return }
        let inLibrary = try Self.rootsWithoutOrigin(under: library, relativeTo: library, orthographicOnly: true)
        let report = "Orthographic library scenes' roots without origin (now at 0, §5.13): \(inLibrary.count)\n"
            + inLibrary.joined(separator: "\n")
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// "path #id name [kinds]" of every root object without `origin` in the `scene.json`-like
    /// files under `folder` (any JSON with an `objects` array), sorted.
    private static func rootsWithoutOrigin(under folder: URL, relativeTo base: URL,
                                           orthographicOnly: Bool) throws -> [String] {
        let kinds = ["image", "particle", "text", "sound", "light", "model", "shape"]
        var found: [String] = []
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "json", !orthographicOnly || url.lastPathComponent == "scene.json",
                  let data = try? Data(contentsOf: url),
                  let scene = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let objects = scene["objects"] as? [[String: Any]] else { continue }
            if orthographicOnly {
                let general = scene["general"] as? [String: Any]
                guard general?["orthogonalprojection"] != nil, (general?["cameraperspective"] as? Bool) != true else { continue }
            }
            let path = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
            for object in objects where object["parent"] == nil && object["origin"] == nil {
                let id = (object["id"] as? Int).map(String.init) ?? "-"
                let name = (object["name"] as? String).map { " \($0)" } ?? ""
                let kind = kinds.filter { object[$0] != nil }
                found.append("\(path) #\(id)\(name) [\(kind.isEmpty ? "none" : kind.joined(separator: ","))]")
            }
        }
        return found.sorted()
    }

    // MARK: - 5.14 Vectors with fewer than three numbers

    /// A missing component is 0, on both paths: a model's `scale` "0.02 0.02" is its "0.02 0.02 0"
    /// (WE's stills of the two are pixel-identical, the box flattened), not "0.02 0.02 1" nor the
    /// default; an image's "0.5 0.5" draws as "0.5 0.5 1" (x 704–1215, y 284–795 both).
    func testAMissingVectorComponentIsZero() throws {
        let two = try SceneLocalTransform3D(object: object(#"{"id": 1, "scale": "0.02 0.02"}"#))
        let zero = try SceneLocalTransform3D(object: object(#"{"id": 1, "scale": "0.02 0.02 0"}"#))
        let one = try SceneLocalTransform3D(object: object(#"{"id": 1, "scale": "0.02 0.02 1"}"#))
        XCTAssertEqual(two.scale, SIMD3(0.02, 0.02, 0))
        XCTAssertEqual(two.matrix, zero.matrix, "flattened like the explicit 0")
        XCTAssertNotEqual(two.matrix, one.matrix)
        XCTAssertEqual(two.matrix.columns.2, .zero, "the model's z collapses")
        let origin = try SceneLocalTransform3D(object: object(#"{"id": 1, "origin": "5 6"}"#))
        XCTAssertEqual(origin.origin, SIMD3(5, 6, 0))
        XCTAssertEqual(try SceneLocalTransform(object: object(#"{"id": 1, "scale": "0.02 0.02"}"#)), two.planar,
                       "the 2D path reads the same vector")

        let image2 = try box(imageObjects(#"{"id": 10, "origin": "960 540 0", "scale": "0.5 0.5"}"#), id: "10")
        let image3 = try box(imageObjects(#"{"id": 10, "origin": "960 540 0", "scale": "0.5 0.5 1"}"#), id: "10")
        XCTAssertEqual(image2, image3)
        assertBox(image2, PixelBox(minX: 704, maxX: 1215, minY: 284, maxY: 795), "image 0.5 0.5")
        try assertStill("mo_514_img_scale2", image2)

        guard let stills = Self.stills else { return }
        XCTAssertEqual(try image(stills, "mo_514_box_scale2").pixels, try image(stills, "mo_514_box_scale3z0").pixels,
                       "WE draws \"0.02 0.02\" as \"0.02 0.02 0\"")
        XCTAssertNotEqual(try image(stills, "mo_514_box_scale2").pixels, try image(stills, "mo_514_box_scale3").pixels)
        XCTAssertEqual(try image(stills, "mo_514_img_scale2").pixels, try image(stills, "mo_514_img_scale3").pixels)
    }

    // MARK: - 5.15 Attachment depth

    /// WE 2.8.42's capture (models-open/515-attachment-depth, the scene in
    /// `Tests/Fixtures/Models/OpenPoints`): an image hung from the rope puppet's `tail` at depth 1,
    /// then plain children at depths 2–4, each 1100 local units along x. All four draw, a row of
    /// 61 px tiles from (960, 540) 66 px apart (x 929–1188, y 509–570): no cut-off past 3. The rope's
    /// `.mdl` has no attachment points (no `MDAT`), so the tail resolves to the parent's origin,
    /// which is also where the tail joint sits.
    func testAttachedChainsResolveAtEveryDepth() throws {
        let data = try Fixtures.data("Models/OpenPoints/515-attachment-depth/scene.json")
        let scene = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let objects = try JSONDecoder().decode([WESceneObject].self,
                                               from: JSONSerialization.data(withJSONObject: try XCTUnwrap(scene["objects"])))
        let hierarchy = SceneTransformHierarchy(objects: objects)
        var asked: [String] = []
        let attachments: SceneTransformHierarchy.Attachments = { child, parent, name in
            asked.append("\(child)<-\(parent):\(name)")
            return nil
        }
        var tiles: [PixelBox] = []
        for (depth, id) in ["601", "602", "603", "604"].enumerated() {
            let tile = box(hierarchy.world(of: id, attachments: attachments))
            let left = 929 + 66 * depth
            assertBox(tile, PixelBox(minX: left, maxX: left + 61, minY: 509, maxY: 570), "depth \(depth + 1)")
            tiles.append(tile)
        }
        XCTAssertEqual(Set(asked), ["601<-10:tail"], "only depth 1 hangs from the rig")
        let deep = SceneTransformHierarchy3D(objects: objects).world(of: "604")
        XCTAssertEqual(deep.columns.3.x, 960 + 3 * 66, accuracy: 1e-3, "the 3D hierarchy agrees")

        guard let folder = Self.capture("515-attachment-depth") else { return }
        // The tiles right of the rope (depths 2–4; the rope covers depth 1's columns), across row 540
        // and down depth 3's centre column, against the clear colour; the bloom's glow is fainter.
        let still = try image(folder, "mo2_515_attach_chain")
        func strong(_ x: Int, _ y: Int) -> Bool {
            let index = (y * still.width + x) * 4
            return (0..<3).reduce(0) { $0 + abs(Int(still.pixels[index + $1]) - Int(still.pixels[$1])) } > 120
        }
        let xs = (993..<1400).filter { strong($0, 540) }, ys = (480..<600).filter { strong(1092, $0) }
        let row = PixelBox(minX: xs.first ?? -1, maxX: xs.last ?? -1, minY: ys.first ?? -1, maxY: ys.last ?? -1)
        assertBox(row, PixelBox(minX: tiles[1].minX, maxX: tiles[3].maxX, minY: 509, maxY: 570), "WE's tiles", accuracy: 3)
    }

    // MARK: - 5.16 Nested tilts in an orthographic scene

    /// The parent at (700, 540) tilted `angles` "30 0 0" (radians) is foreshortened to y 473–606;
    /// its child (`origin` "500 0 200", `angles` "0 30 0", scale 0.5) is a near edge-on sliver from
    /// (1091, 622) to (1158, 62): the 3D product, whose parent tilt turns the child's depth and
    /// tilt into the plane. The product of each level's 2D view would leave it centred at y 540.
    func testNestedTiltsComposeThroughTheParentChain() throws {
        let objects = try imageObjects(#"{"id": 10, "origin": "700 540 0", "angles": "30 0 0", "scale": "0.85 0.85 1"}"#,
                                       #"{"id": 11, "parent": 10, "origin": "500 0 200", "angles": "0 30 0", "scale": "0.5 0.5 1"}"#)
        let hierarchy = SceneTransformHierarchy(objects: objects)
        XCTAssertTrue(hierarchy.composesInDepth)
        let parent = box(hierarchy.world(of: "10"))
        assertBox(parent, PixelBox(minX: 265, maxX: 1134, minY: 473, maxY: 606), "the tilted parent")
        // The sliver's tips are a few pixels wide: WE's anti-aliased ends fade there.
        let child = box(hierarchy.world(of: "11"))
        assertBox(child, PixelBox(minX: 1091, maxX: 1158, minY: 62, maxY: 622), "the child", accuracy: 4)

        // Agrees with the 3D hierarchy's orthographic view.
        let deep = SceneWorldMatrix.orthographic(SceneTransformHierarchy3D(objects: objects).world(of: "11"))
        XCTAssertEqual(box(deep), child)

        // The flat control: no tilt, z 0, and the 2D product stands.
        let flat = SceneTransformHierarchy(objects: try imageObjects(
            #"{"id": 10, "origin": "700 540 0", "scale": "0.85 0.85 1"}"#,
            #"{"id": 11, "parent": 10, "origin": "500 0 0", "scale": "0.5 0.5 1"}"#))
        XCTAssertFalse(flat.composesInDepth)
        assertBox(box(flat.world(of: "10")), PixelBox(minX: 265, maxX: 1134, minY: 105, maxY: 974), "flat parent")
        assertBox(box(flat.world(of: "11")), PixelBox(minX: 907, maxX: 1342, minY: 323, maxY: 757), "flat child")

        if let stills = Self.stills {
            let tilt = try XCTUnwrap(Self.measure(try image(stills, "mo_516_nested_tilt")))
            assertBox(PixelBox(minX: parent.minX, maxX: max(parent.maxX, child.maxX),
                               minY: min(parent.minY, child.minY), maxY: max(parent.maxY, child.maxY)),
                      tilt, "the tilted still", accuracy: 4)
            try assertStill("mo_516_nested_flat", PixelBox(minX: 265, maxX: 1342, minY: 105, maxY: 974))
        }
    }

    /// A tilted parent alone (its child without depth) keeps the 2D product, as does a child with
    /// depth under an untilted parent.
    func testOnlyATiltedAncestorOverADepthComposesInDepth() throws {
        XCTAssertFalse(SceneTransformHierarchy(objects: try imageObjects(
            #"{"id": 1, "angles": "0.3 0 0"}"#, #"{"id": 2, "parent": 1, "origin": "5 0 0"}"#)).composesInDepth)
        XCTAssertFalse(SceneTransformHierarchy(objects: try imageObjects(
            #"{"id": 1}"#, #"{"id": 2, "parent": 1, "origin": "5 0 9", "angles": "0.2 0 0"}"#)).composesInDepth)
        XCTAssertTrue(SceneTransformHierarchy(objects: try imageObjects(
            #"{"id": 1, "angles": "0 0.3 0"}"#, #"{"id": 2, "parent": 1}"#,
            #"{"id": 3, "parent": 2, "origin": "0 0 4"}"#)).composesInDepth, "a grandparent's tilt counts")
    }

    /// The switch follows the effective tilts: a timeline or script tilting the parent of a child
    /// with depth turns it on, and back off when the tilt returns to 0 or is scripted away; the
    /// child's world then follows the capture's composition.
    func testTheDepthCompositionFollowsLiveTilts() throws {
        var hierarchy = SceneTransformHierarchy(objects: try imageObjects(
            #"{"id": 10, "origin": "700 540 0", "scale": "0.85 0.85 1"}"#,
            #"{"id": 11, "parent": 10, "origin": "500 0 200", "angles": "0 30 0", "scale": "0.5 0.5 1"}"#))
        XCTAssertFalse(hierarchy.composesInDepth, "untilted as authored")
        let parent = try XCTUnwrap(hierarchy.nodes["10"]?.local)
        var tilted = parent
        tilted.tilt = SIMD2(30, 0)
        let live: (String) -> SceneLocalTransform? = { $0 == "10" ? tilted : nil }
        hierarchy.updateComposition(live: live)
        XCTAssertTrue(hierarchy.composesInDepth, "a live tilt on the ancestor")
        let child = box(hierarchy.world(of: "11", live: live))
        assertBox(child, PixelBox(minX: 1091, maxX: 1158, minY: 62, maxY: 622), "the child under the live tilt", accuracy: 4)
        hierarchy.updateComposition { _ in nil }
        XCTAssertFalse(hierarchy.composesInDepth, "back to the authored angles")

        // Authored tilted, scripted flat: off.
        var authored = SceneTransformHierarchy(objects: try imageObjects(
            #"{"id": 10, "origin": "700 540 0", "angles": "30 0 0", "scale": "0.85 0.85 1"}"#,
            #"{"id": 11, "parent": 10, "origin": "500 0 200"}"#))
        XCTAssertTrue(authored.composesInDepth)
        authored.updateComposition { $0 == "10" ? parent : nil }
        XCTAssertFalse(authored.composesInDepth)
    }

    // MARK: - 5.17 A mirrored puppet with `cullmode` "normal"

    /// The rope puppet at (960, 540) draws at scale 1 1 1 and disappears at −1 1 1: the flip
    /// reverses the winding, and WE culls without compensating. The mesh drawn into the image
    /// then culls the other winding.
    func testAMirroredNormalCullPuppetIsCulled() throws {
        let upright = try SceneTransformHierarchy(objects: imageObjects(#"{"id": 1, "origin": "960 540 0", "scale": "1 1 1"}"#))
        let flipped = try SceneTransformHierarchy(objects: imageObjects(#"{"id": 1, "origin": "960 540 0", "scale": "-1 1 1"}"#))
        func mirrored(_ hierarchy: SceneTransformHierarchy) -> Bool {
            let linear = hierarchy.world(of: "1").linear
            return ScenePuppetRenderer.isMirrored(axisX: linear.columns.0, axisY: linear.columns.1)
        }
        XCTAssertFalse(mirrored(upright))
        XCTAssertTrue(mirrored(flipped))
        XCTAssertEqual(ScenePuppetRenderer.frontFacing(mirrored: false), .counterClockwise,
                       "the editor's counter-clockwise rig faces the viewer, as a model's faces do")
        XCTAssertEqual(ScenePuppetRenderer.frontFacing(mirrored: false), SceneModelRenderer.frontFacing)
        XCTAssertEqual(ScenePuppetRenderer.frontFacing(mirrored: true), .clockwise,
                       "a mirrored layer's mesh shows its back faces, which `normal` culls")
        // A half turn about z isn't a mirror; a tilt past a quarter turn is.
        XCTAssertFalse(ScenePuppetRenderer.isMirrored(axisX: SIMD2(-1, 0), axisY: SIMD2(0, -1)))
        let turned = SceneAffineTransform(SceneLocalTransform(origin: .zero, scale: SIMD2(1, 1), angle: 0,
                                                              tilt: SIMD2(0, Float.pi * 0.75))).linear
        XCTAssertTrue(ScenePuppetRenderer.isMirrored(axisX: turned.columns.0, axisY: turned.columns.1))

        // Through a camera: WE's orthographic projection of the scene, and a world scaled −1 in x.
        let viewProjection = SceneCamera.orthographic(size: Self.screen)
        let flip = SceneLocalTransform3D(origin: SIMD3(960, 540, 0), scale: SIMD3(-1, 1, 1), angles: .zero).matrix
        XCTAssertTrue(ScenePuppetRenderer.isMirrored(world: flip, viewProjection: viewProjection))
        let plain = SceneLocalTransform3D(origin: SIMD3(960, 540, 0), scale: SIMD3(1, 1, 1), angles: .zero).matrix
        XCTAssertFalse(ScenePuppetRenderer.isMirrored(world: plain, viewProjection: viewProjection))

        guard let stills = Self.stills else { return }
        XCTAssertNotNil(Self.measure(try image(stills, "mo_517_cull_normal")), "WE draws the upright rope")
        XCTAssertNil(Self.measure(try image(stills, "mo_517_cull_normal_flipx")), "WE draws nothing of the flipped one")
    }

    // MARK: - 5.19 Orthographic `zoom`

    /// `general.zoom` 2 is a 2× zoom about the screen's centre: the control's 870 px image is
    /// 1742 px wide, x 89–1830, and runs off the top and bottom.
    func testOrthographicZoomScalesAboutTheScreenCentre() throws {
        let hierarchy = try SceneTransformHierarchy(objects: imageObjects(#"{"id": 10, "origin": "960 540 0", "scale": "0.85 0.85 1"}"#))
        let zoom = SceneOrthographicZoom(factor: 2, sceneSize: Self.screen)
        let zoomed = box(zoom.plane * hierarchy.world(of: "10"))
        assertBox(zoomed, PixelBox(minX: 89, maxX: 1830, minY: 0, maxY: 1031), "zoom 2")
        try assertStill("mo_519_orthozoom2", zoomed)
        XCTAssertEqual(SceneOrthographicZoom(factor: 1, sceneSize: Self.screen).plane, .identity)
        XCTAssertTrue(SceneOrthographicZoom(factor: 0, sceneSize: Self.screen).isNone, "no zoom of 0")

        // The models' camera sees the drawn space: a world point lands where WE's zoomed projection
        // puts it, at the depth it has without the zoom, and the cursor over a drawn point
        // unprojects to the world point.
        let input = SceneCameraRigInput(sceneSize: Self.screen, aspect: Self.screen.x / Self.screen.y, time: 0, deltaTime: 0)
        let camera = SceneOrthographicCameraRig(zoom: 2).frameCamera(input)
        let weZoomed = zoom.projection(SceneCamera.orthographic(size: Self.screen))
        for point in [SIMD3<Float>(1395.2, 540, 0), SIMD3(524.8, 104.8, 300), SIMD3(960, 540, -900), SIMD3(100, 900, 50)] {
            let world: SIMD4<Float> = SIMD4<Float>(point, 1)
            let drawnSpace: simd_float4x4 = camera.viewProjection * zoom.space
            let ours: SIMD4<Float> = drawnSpace * world
            let we: SIMD4<Float> = weZoomed * world
            XCTAssertEqual(ours.x / ours.w, we.x / we.w, accuracy: 1e-5)
            XCTAssertEqual(ours.y / ours.w, we.y / we.w, accuracy: 1e-5)
            XCTAssertEqual(ours.z / ours.w, we.z / we.w, accuracy: 1e-5)
            let drawn = zoom.plane.apply(SIMD2(point.x, point.y))
            let pixel = (SIMD2(we.x, we.y) / we.w + 1) / 2 * Self.screen
            XCTAssertEqual(pixel.x, drawn.x, accuracy: 1e-2)
            XCTAssertEqual(pixel.y, drawn.y, accuracy: 1e-2)
            let back = zoom.worldPoint(drawn: drawn)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-3)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-3)
        }
        XCTAssertEqual(camera.eye.z, 2 * SceneCamera.orthographicDepth)
        XCTAssertEqual(SceneOrthographicCameraRig().frameCamera(input).projection, SceneCamera.orthographic(size: Self.screen))
        // The camera's own zoom, as a script set it, multiplies `general.zoom`.
        var scripted = input
        scripted.scriptCamera = SceneCameraPose(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), zoom: 1.5)
        XCTAssertEqual(SceneOrthographicCameraRig.frameZoom(general: 2, input: scripted).factor, 3)
        XCTAssertEqual(SceneOrthographicCameraRig(zoom: 2).frameCamera(scripted).eye.z, 3 * SceneCamera.orthographicDepth)

        // A click lands on what is drawn under it: `input.cursorWorldPosition` over the zoomed
        // image's drawn right edge (x 1830 of 1920) is the image's own right edge in the world.
        var environment = SceneScriptEngineEnvironment(screenResolution: SIMD2(1920, 1080), canvasSize: SIMD2(1920, 1080))
        environment.zoom = zoom
        let world = SceneScriptInput(cursorScreenPosition: SIMD2(1830.4, 540)).cursorWorldPosition(in: environment)
        XCTAssertEqual(world.x, 1395.2, accuracy: 1e-2)
        XCTAssertEqual(world.y, 540, accuracy: 1e-2)

        // The lights are placed in the drawn space and their distances grow with it.
        var light = SceneLight(kind: .point)
        light.radius = 300
        light.lightSourceSize = 10
        let scaled = zoom.scaled(light)
        XCTAssertEqual(scaled.radius, 600)
        XCTAssertEqual(scaled.lightSourceSize, 20)
        XCTAssertEqual(scaled.cascadeDistances, light.cascadeDistances * 2)
        XCTAssertEqual(SceneOrthographicZoom.none.scaled(light), light)
    }

    // MARK: - Helpers

    private func object(_ json: String) throws -> WESceneObject {
        try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
    }

    private func imageObjects(_ objects: String...) throws -> [WESceneObject] {
        try JSONDecoder().decode([WESceneObject].self, from: Data("[\(objects.joined(separator: ","))]".utf8))
    }

    private func box(_ objects: [WESceneObject], id: String) -> PixelBox {
        box(SceneTransformHierarchy(objects: objects).world(of: id))
    }

    /// The pixels an image of `imageSize` under `world` covers on the screen: the scene's y is up,
    /// the still's down; clipped to the screen above the taskbar.
    private func box(_ world: SceneAffineTransform) -> PixelBox {
        let bounds = SceneQuadGeometry(world: world, size: Self.imageSize, alignment: nil).boundingBox
        let lastRow = Int(Self.screen.y) - Self.taskbar - 1
        return PixelBox(minX: max(0, Int(bounds.min.x.rounded())),
                        maxX: min(Int(Self.screen.x) - 1, Int(bounds.max.x.rounded()) - 1),
                        minY: max(0, Int((Self.screen.y - bounds.max.y).rounded())),
                        maxY: min(lastRow, Int((Self.screen.y - bounds.min.y).rounded()) - 1))
    }

    private func assertBox(_ box: PixelBox, _ expected: PixelBox, _ message: String, accuracy: Int = 1,
                           file: StaticString = #filePath, line: UInt = #line) {
        let close = abs(box.minX - expected.minX) <= accuracy && abs(box.maxX - expected.maxX) <= accuracy
            && abs(box.minY - expected.minY) <= accuracy && abs(box.maxY - expected.maxY) <= accuracy
        XCTAssertTrue(close, "\(message): \(box), WE \(expected)", file: file, line: line)
    }

    /// `name`'s drawn bounds against `box`, when the stills are present.
    private func assertStill(_ name: String, _ box: PixelBox, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let stills = Self.stills else { return }
        let measured = try XCTUnwrap(Self.measure(try image(stills, name)), "\(name) draws nothing", file: file, line: line)
        assertBox(box, measured, name, file: file, line: line)
    }

    /// The captures' `shots` folder under `OWE_WE_REFERENCE`; nil without it.
    private static var stills: URL? {
        guard let root = ProcessInfo.processInfo.environment["OWE_WE_REFERENCE"], !root.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: root, isDirectory: true).appending(path: "requests/owe-beta3/models-open/shots")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// A round-2 capture's folder (`requests/owe-beta3/models-open/<name>`, stills beside the
    /// projects) under `OWE_WE_REFERENCE`; nil without it.
    static func capture(_ name: String) -> URL? {
        guard let root = ProcessInfo.processInfo.environment["OWE_WE_REFERENCE"], !root.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: root, isDirectory: true).appending(path: "requests/owe-beta3/models-open/\(name)")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private func image(_ folder: URL, _ name: String) throws -> WEReferenceImage {
        try WEReferenceImage.load(folder.appending(path: "\(name).png"))
    }

    /// The bounds of what differs from the background (the top-left pixel) above the taskbar;
    /// nil when nothing does.
    static func measure(_ image: WEReferenceImage, in region: PixelBox? = nil) -> PixelBox? {
        let pixels = image.pixels
        var box: PixelBox?
        let region = region ?? PixelBox(minX: 0, maxX: image.width - 1, minY: 0, maxY: image.height - taskbar - 1)
        for y in region.minY...region.maxY {
            for x in region.minX...region.maxX {
                let index = (y * image.width + x) * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(pixels[index + $1]) - Int(pixels[$1])) }
                guard difference > 24 else { continue }
                if var found = box {
                    found.minX = min(found.minX, x)
                    found.maxX = max(found.maxX, x)
                    found.maxY = y
                    box = found
                } else {
                    box = PixelBox(minX: x, maxX: x, minY: y, maxY: y)
                }
            }
        }
        return box
    }
}
