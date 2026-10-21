import XCTest
@testable import OpenWallpaperEngine

final class UserPropertyHTMLTests: XCTestCase {
    func testStripsTagsAndKeepsBreaks() {
        let html = "<big><font color=#FFFFFF><h5>Thanks for subscribing!<br/>If you like it<br>leave a like"
        XCTAssertEqual(UserPropertyHTML.plainText(html), "Thanks for subscribing!\nIf you like it\nleave a like")
    }

    func testDecodesEntities() {
        XCTAssertEqual(UserPropertyHTML.plainText("a &amp; b &lt;c&gt; &#65;&#x42;"), "a & b <c> AB")
    }

    func testLinksBecomeSegments() {
        let segments = UserPropertyHTML.segments("Join <a href='https://discord.gg/x'>Discord</a> now")
        XCTAssertEqual(segments, [
            .init(text: "Join ", link: nil),
            .init(text: "Discord", link: URL(string: "https://discord.gg/x")),
            .init(text: " now", link: nil)
        ])
    }

    func testImageOnlyLinkGetsHostText() {
        let segments = UserPropertyHTML.segments("<a href='https://discord.gg/x'><img src='https://a/b.gif'></a>")
        XCTAssertEqual(segments, [.init(text: "discord.gg", link: URL(string: "https://discord.gg/x"))])
    }

    func testImageOnlyRowIsEmpty() {
        XCTAssertEqual(UserPropertyHTML.plainText("<img src='https://x/y.png' width='276'>"), "")
    }

    func testJavascriptLinksAreDropped() {
        let segments = UserPropertyHTML.segments("<a href='javascript:alert(1)'>x</a>")
        XCTAssertEqual(segments, [.init(text: "x", link: nil)])
    }

    func testParagraphsAddLineBreaks() {
        XCTAssertEqual(UserPropertyHTML.plainText("<p>One</p><p>Two</p>"), "One\nTwo")
    }

    func testContainsMarkup() {
        XCTAssertTrue(UserPropertyHTML.containsMarkup("<b>x</b>"))
        XCTAssertFalse(UserPropertyHTML.containsMarkup("a < b"))
    }
}

final class UserPropertySliderFormatTests: XCTestCase {
    func testIntegerSlider() {
        let format = UserPropertySliderFormat(minimum: 5, maximum: 60, fraction: false)
        XCTAssertEqual(format.fractionDigits, 0)
        XCTAssertEqual(format.storedString(30.4), "30")
        XCTAssertEqual(format.storedString(30.6), "31")
        XCTAssertEqual(format.storedString(100), "60")
    }

    func testStepSnapsAndCleansNoise() {
        let format = UserPropertySliderFormat(minimum: 0, maximum: 10, fraction: true, step: 0.1, precision: 2)
        XCTAssertEqual(format.fractionDigits, 1, "WE saves precision as decimals + 1")
        XCTAssertEqual(format.storedString(0.3049), "0.3")
        XCTAssertEqual(format.snap(-1), 0)
    }

    /// WE's slider without `step`/`precision` uses `step || 1` and `precision || 1`.
    func testDefaultStepAndFractionDigits() {
        XCTAssertEqual(UserPropertySliderFormat(minimum: 0, maximum: 1).fractionDigits, 0)
        XCTAssertEqual(UserPropertySliderFormat(minimum: 0, maximum: 1).effectiveStep, 1)
        XCTAssertEqual(UserPropertySliderFormat(minimum: 0, maximum: 1, precision: 4).fractionDigits, 3)
    }
}
