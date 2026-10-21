import CoreGraphics
import XCTest
@testable import OWESceneEditing

/// WE's Character Sheet Creation: which picture each limb is cut from, which pictures go on the
/// sheet, how they are laid out, and how OK replaces the layer.
final class CharacterSheetTests: XCTestCase {
    /// The guide's samurai: Body; Arm (with Sword under it), Shield, Head.
    private let depths = [0, 1, 2, 1, 1]

    func testEachLimbIsCutFromWhatItsParentOrSiblingLeaves() {
        XCTAssertEqual(CharacterSheet.sources(depths: depths), [
            .picture,
            .foreground(of: 0), // Arm: from the Body.
            .foreground(of: 1), // Sword: from the Arm.
            .background(of: 1), // Shield: from what the Arm left.
            .background(of: 3), // Head: from what the Shield left.
        ])
        XCTAssertEqual(CharacterSheet.parents(depths: depths), [nil, 0, 1, 0, 0])
    }

    private func piece(_ tag: UInt8, width: Int = 4, height: Int = 3) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for index in 0..<(width * height) {
            image.pixels[index * 4] = tag
            image.pixels[index * 4 + 3] = 255
        }
        return image
    }

    /// A 512 × 512 picture cut into a piece at (x, y) of `width` × `height` in tag `tag`.
    private func limb(_ tag: UInt8, x: Int, y: Int, width: Int, height: Int) -> RGBAImage {
        var image = RGBAImage(width: 512, height: 512)
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                image.pixels[(row * 512 + column) * 4] = tag
                image.pixels[(row * 512 + column) * 4 + 3] = 255
            }
        }
        return image
    }

    /// WE 2.8.0.42 capture 545, run 2: a 512 × 512 figure (Body, then Head and Arm under it). WE's
    /// sheet, 492 × 509, put the body (224 × 216) at (64, 64), the arm's piece (78 wide, its
    /// leftovers) at (350, 64) beside it and the head (100 × 102) at (64, 343) below: a 64 px
    /// margin and gaps of an eighth of the 512 px picture, in the squarest rows, tallest first.
    func testTheCaptureSheetsLayout() {
        let pieces = [limb(1, x: 216, y: 180, width: 224, height: 216), limb(2, x: 300, y: 100, width: 78, height: 212),
                      limb(3, x: 206, y: 80, width: 100, height: 102)]
        XCTAssertEqual(CharacterSheet.spacing(for: pieces), 64)
        let sheet = CharacterSheet.sheet(pieces)
        XCTAssertEqual(Double(sheet.width), 492, accuracy: 2)
        XCTAssertEqual(Double(sheet.height), 509, accuracy: 2)
        func origin(of tag: UInt8) -> SIMD2<Int>? {
            for y in 0..<sheet.height {
                for x in 0..<sheet.width where sheet.pixels[(y * sheet.width + x) * 4] == tag { return SIMD2(x, y) }
            }
            return nil
        }
        XCTAssertEqual(origin(of: 1), SIMD2(64, 64))
        let arm = origin(of: 2), head = origin(of: 3)
        XCTAssertEqual(Double(arm?.x ?? 0), 350, accuracy: 2)
        XCTAssertEqual(arm?.y, 64)
        XCTAssertEqual(head?.x, 64)
        XCTAssertEqual(Double(head?.y ?? 0), 343, accuracy: 1)
    }

    func testTheSheetHoldsWhatIsLeftOfEachParentAndEveryLeaf() {
        let limbs = [
            CharacterSheet.Limb(depth: 0),
            CharacterSheet.Limb(depth: 1, foreground: piece(1), background: piece(11)),
            CharacterSheet.Limb(depth: 2, foreground: piece(2), background: piece(12)),
            CharacterSheet.Limb(depth: 1, foreground: piece(3), background: piece(13)),
            CharacterSheet.Limb(depth: 1, foreground: piece(4), background: piece(14)),
        ]
        let tags = CharacterSheet.pieces(limbs, body: piece(99)).map { $0.pixels[0] }
        // The Body's remainder (after the Head, its last limb), the Arm's remainder (after the
        // Sword), the Sword, the Shield and the Head; not the Arm itself.
        XCTAssertEqual(tags, [14, 12, 2, 3, 4])
        XCTAssertEqual(CharacterSheet.pieces([CharacterSheet.Limb(depth: 0)], body: piece(99)).map { $0.pixels[0] }, [99])
    }

    func testSpacingIsAnEighthOfTheMeanSideWithinWEsBounds() {
        XCTAssertEqual(CharacterSheet.spacing(for: [piece(1, width: 100, height: 100)]), 30)
        XCTAssertEqual(CharacterSheet.spacing(for: [piece(1, width: 800, height: 400)]), 75)
        XCTAssertEqual(CharacterSheet.spacing(for: [piece(1, width: 4000, height: 4000)]), 200)
    }

    func testPiecesAreCutToTheirContentAndLaidOutWithoutOverlapping() {
        var sparse = RGBAImage(width: 200, height: 200)
        for y in 50..<90 { for x in 20..<60 { sparse.pixels[(y * 200 + x) * 4] = 7; sparse.pixels[(y * 200 + x) * 4 + 3] = 255 } }
        XCTAssertEqual(CharacterSheet.croppedToContent(sparse).map { [$0.width, $0.height] }, [40, 40])
        XCTAssertNil(CharacterSheet.croppedToContent(RGBAImage(width: 3, height: 3)))

        var pieces: [RGBAImage] = []
        for index in 0..<6 {
            let value = UInt8(10 + index)
            let width: Int = 40 + index * 10
            let height: Int = 30 + index * 5
            pieces.append(piece(value, width: width, height: height))
        }
        let sheet = CharacterSheet.sheet(pieces)
        let gap = CharacterSheet.spacing(for: pieces)
        // Every piece's pixels are on the sheet once.
        var counts: [UInt8: Int] = [:]
        for index in 0..<(sheet.width * sheet.height) where sheet.pixels[index * 4 + 3] == 255 {
            counts[sheet.pixels[index * 4], default: 0] += 1
        }
        for (offset, piece) in pieces.enumerated() { XCTAssertEqual(counts[UInt8(10 + offset)], piece.width * piece.height) }
        // Square rather than one row: no side more than twice the other.
        XCTAssertLessThanOrEqual(max(sheet.width, sheet.height), 2 * min(sheet.width, sheet.height))
        // The border is clear.
        for x in 0..<sheet.width { XCTAssertEqual(sheet.pixels[x * 4 + 3], 0) }
        XCTAssertGreaterThanOrEqual(gap, 30)
    }

    @MainActor
    func testOKReplacesTheLayerWithTheSheet() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorAssetStore(directory: directory)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: UndoManager())
        let files: [String: Data] = [
            "models/logo.json": Data(#"{"autosize": true, "material": "materials/logo.json"}"#.utf8),
            "materials/logo.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["logo"]}]}"#.utf8),
        ]
        let readFile: (String) -> Data? = { path in files[path] ?? store.url(for: path).flatMap { try? Data(contentsOf: $0) } }
        let before = session.outline.layers.map(\.id)
        let position = try XCTUnwrap(before.firstIndex(of: 13))
        let sheet = try XCTUnwrap(piece(5, width: 64, height: 32).cgImage)

        let id = try session.replaceWithCharacterSheet(sheet, layerID: 13, store: store, readFile: readFile, actionName: "Character Sheet")

        let order = session.outline.layers.map(\.id)
        XCTAssertNil(session.outline.layer(13), "WE removes the layer")
        XCTAssertEqual(order.firstIndex(of: id), position, "the sheet takes its place")
        let layer = try XCTUnwrap(session.outline.layer(id))
        XCTAssertEqual(layer.name, "logo_sheet")
        XCTAssertEqual(layer.fields["size"]?.stringValue, "64 32")
        XCTAssertEqual(layer.fields["origin"]?.stringValue, "960 540 0", "WE puts the sheet at the scene's centre")
        let material = try XCTUnwrap(ImageLayerMaterial(layer: layer, readFile: readFile))
        XCTAssertTrue(try XCTUnwrap(material.texture).hasPrefix("editor/logo_sheet-"))
        XCTAssertEqual(session.selection, id)

        session.undo()
        XCTAssertEqual(session.outline.layers.map(\.id), before)
    }
}
