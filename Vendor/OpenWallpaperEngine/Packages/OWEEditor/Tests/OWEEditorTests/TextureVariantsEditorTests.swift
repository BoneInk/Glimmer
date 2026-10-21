import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The texture variants' inspector: the property a new condition makes, and the option files
/// (its catalog is checked by `CatalogCoverageTests`).
final class TextureVariantsEditorTests: XCTestCase {
    func testANewConditionMakesACheckboxOrAComboForTheGroup() {
        let hat = TextureVariantDocument.Option(name: "Hat", file: "a.png")
        let coat = TextureVariantDocument.Option(name: "Coat", file: "b.png", condition: .flag("other"))
        let scarf = TextureVariantDocument.Option(name: "Scarf", file: "c.png")
        let group = TextureVariantDocument.Group(name: "Clothes", options: [hat, coat, scarf])

        let checkbox = TextureVariantConditionSheet.newProperty(.bool, label: "Clothes", group: group, option: hat.id)
        XCTAssertEqual(checkbox.draft.kind, .bool)
        XCTAssertEqual(checkbox.conditions, [hat.id: .flag("Clothes")])

        let combo = TextureVariantConditionSheet.newProperty(.combo, label: "Clothes", group: group, option: coat.id)
        XCTAssertEqual(combo.draft.kind, .combo)
        XCTAssertEqual(combo.draft.options.map(\.value), ["0", "1", "2", "3"], "the base, then one value per option")
        XCTAssertEqual(combo.draft.options.dropFirst().map(\.label), ["Hat", "Coat", "Scarf"])
        XCTAssertEqual(combo.draft.value, .string("0"), "the base shows by default")
        // The option asked for, and the group's options without a condition.
        XCTAssertEqual(combo.conditions, [hat.id: .equals("Clothes", "1"), coat.id: .equals("Clothes", "2"),
                                          scarf.id: .equals("Clothes", "3")])
        XCTAssertEqual(TextureVariantDocument.Condition.equals("Clothes", "2").rekeyed("clothes"), .equals("clothes", "2"))
    }

    func testOptionFilesNameTheirTextures() {
        XCTAssertEqual(TextureVariantsSection.textureName(of: "materials/editor/variants/hat-1.png"), "editor/variants/hat-1")
    }
}
