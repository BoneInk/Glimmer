import XCTest
@testable import OWESceneEditing

/// The condition evaluator the app's property sidebar and the editor's preview share.
final class UserPropertyConditionExpressionTests: XCTestCase {
    private func eval(_ source: String, _ values: [String: String]) -> Bool {
        UserPropertyConditionExpression(source).evaluate(values)
    }

    func testEmptyConditionHolds() {
        XCTAssertTrue(eval("", [:]))
        XCTAssertTrue(eval("   ", [:]))
        XCTAssertFalse(UserPropertyConditionExpression("   ").isUnderstood)
    }

    func testBoolEqualsNumberLikeJavaScript() {
        XCTAssertTrue(eval("clock.value == 1", ["clock": "true"]))
        XCTAssertFalse(eval("clock.value == 1", ["clock": "false"]))
        XCTAssertTrue(eval("hyperdrive.value == true", ["hyperdrive": "true"]))
        XCTAssertTrue(eval("animation.value === true", ["animation": "true"]))
    }

    func testStringsAndLogic() {
        let values = ["style_big": "cycle", "mode_combo": "stretched"]
        XCTAssertTrue(eval("style_big.value == \"cycle\" && mode_combo.value == \"stretched\"", values))
        XCTAssertFalse(eval("style_big.value == \"cycle\" && mode_combo.value == 'dual'", values))
        XCTAssertTrue(eval("mode_combo.value == 'dual' || style_big.value != 'x'", values))
        XCTAssertTrue(eval("!(mode_combo.value == 'dual')", values))
    }

    func testNumericComparisons() {
        XCTAssertTrue(eval("count.value > 2", ["count": "10"]))
        XCTAssertFalse(eval("count.value > 2", ["count": "2"]))
        XCTAssertTrue(eval("count.value <= 2.5", ["count": "2"]))
        XCTAssertTrue(eval("count.value != 3", ["count": "3.5"]))
    }

    func testBareTruthiness() {
        XCTAssertTrue(eval("flag.value", ["flag": "true"]))
        XCTAssertFalse(eval("!flag.value", ["flag": "true"]))
        XCTAssertFalse(eval("missing.value", [:]))
    }

    func testUnparseableConditionShows() {
        XCTAssertTrue(eval("a.value == (", [:]))
        XCTAssertTrue(eval("a.value ~ 3", [:]))
    }

    /// The app's former copy read `!` on the right of a comparison and the editor's didn't (the
    /// condition was unreadable, so it held); JavaScript reads it, as this does.
    func testNegatedRightHandSide() {
        XCTAssertTrue(UserPropertyConditionExpression("a.value == !b.value").isUnderstood)
        XCTAssertTrue(eval("a.value == !b.value", ["a": "true", "b": "false"]))
        XCTAssertFalse(eval("a.value == !b.value", ["a": "true", "b": "true"]))
    }

    /// `!` binds tighter than `==` in JavaScript: `!a.value == 1` is `(!a.value) == 1`, not
    /// `!(a.value == 1)`. Both former copies read the latter, which differs when `a` is 2.
    func testNegationBindsTighterThanComparison() {
        XCTAssertFalse(eval("!a.value == 1", ["a": "2"]))
        XCTAssertTrue(eval("!a.value == 1", ["a": "0"]))
        XCTAssertFalse(eval("!a.value == 1", ["a": "1"]))
        XCTAssertTrue(eval("!!a.value", ["a": "1"]))
    }

    // MARK: - Scripts

    /// The label trick: the condition rewrites the checkbox's own label as it's ticked.
    func testScriptRewritesItsLabel() {
        let condition = UserPropertyConditionExpression("clock_enable.value ? clock_enable.text = clock_enable.text.replace('Disabled','Enabled').replace('ugcDanger','ugcSuccess') : clock_enable.text = clock_enable.text.replace('Enabled','Disabled').replace('ugcSuccess','ugcDanger')")
        XCTAssertFalse(condition.isUnderstood)
        let label = "<span class='ugcDanger'>Clock : Disabled</span>"
        let on = UserPropertyConditionScope(values: ["clock_enable": "true"], texts: ["clock_enable": label])
        XCTAssertTrue(on.evaluate(condition))
        XCTAssertEqual(on.texts["clock_enable"], "<span class='ugcSuccess'>Clock : Enabled</span>")
        let off = UserPropertyConditionScope(values: ["clock_enable": "false"], texts: ["clock_enable": label])
        XCTAssertTrue(off.evaluate(condition))
        XCTAssertEqual(off.texts["clock_enable"], label)
    }

    func testScriptTernaryHides() {
        let source = "background_enable.value && !(background_type.value == 1) ? background_effect.text = 'x' : false"
        XCTAssertFalse(eval(source, ["background_enable": "false", "background_type": "0", "background_effect": "false"]))
        XCTAssertTrue(eval(source, ["background_enable": "true", "background_type": "0", "background_effect": "false"]))
        XCTAssertFalse(eval(source, ["background_enable": "true", "background_type": "1", "background_effect": "false"]))
    }

    func testLabelsCarryAcrossConditions() {
        let scope = UserPropertyConditionScope(values: ["a": "true", "b": "true"], texts: ["a": "A off", "b": ""])
        XCTAssertTrue(scope.evaluate(UserPropertyConditionExpression("a.value ? a.text = a.text.replace('off','on') : false")))
        XCTAssertTrue(scope.evaluate(UserPropertyConditionExpression("b.value ? b.text = a.text : false")))
        XCTAssertEqual(scope.texts["b"], "A on")
    }

    func testScriptThatCouldLoopOrThrowHolds() {
        XCTAssertTrue(eval("(function(){ while(true){} })()", [:]))
        XCTAssertTrue(eval("missing.value.trim() == 'x'", [:]))
    }
}
