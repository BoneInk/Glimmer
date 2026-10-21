import XCTest
@testable import OWEEditor

/// `sparkles` stands for particle systems, so no effect group shows it.
final class EffectGroupSymbolTests: XCTestCase {
    func testNoGroupUsesTheParticleSymbol() {
        let groups = ["animate", "blur", "distort", "enhance", "simulate", "adjust", "color",
                      "interactive", "mask", "", "unknown"]
        for group in groups {
            XCTAssertNotEqual(EffectGroupSymbol.symbol(group), "sparkles", group)
        }
        XCTAssertEqual(EffectGroupSymbol.symbol("unknown"), "slider.horizontal.3")
    }
}
