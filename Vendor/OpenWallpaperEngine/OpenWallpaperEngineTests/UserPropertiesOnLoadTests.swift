import XCTest
@testable import OpenWallpaperEngine

/// A fresh load starts with the values the user stored, as WE does: scripts' `init()` sees them in
/// `engine.userProperties` and `applyUserProperties` gets them all once, text bound to a property
/// shows the stored value from the first frame, and a web page gets them with every other
/// property. Every load reads them through `WallpaperSettingsIdentity.userSetValues(scope:)`.
final class UserPropertiesOnLoadTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let identity = WallpaperSettingsIdentity(rawValue: "workshop-1")

    override func setUpWithError() throws {
        suite = "owe-properties-on-load-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func store(_ values: [String: String], scope: WallpaperPropertyScope = .shared, explicit: Bool = true) {
        defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
        if explicit { defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope)) }
    }

    // MARK: - Lookup and keying

    func testLoadReadsTheValuesTheUserSet() {
        XCTAssertEqual(identity.userSetValues(scope: .shared, defaults: defaults), [:], "nothing stored: defaults apply")
        store(["datesize": "9"], explicit: false)
        XCTAssertEqual(identity.userSetValues(scope: .shared, defaults: defaults), [:],
                       "values a load wrote back from project.json are not the user's")
        store(["datesize": "96.0"])
        XCTAssertEqual(identity.userSetValues(scope: .shared, defaults: defaults), ["datesize": "96.0"])
    }

    /// A display seeded while the shared store held only written-back defaults kept that copy with
    /// no flag; once the user sets the shared values, that display loads them, as its sidebar shows.
    func testDisplayWithoutItsOwnValuesLoadsTheSharedOnes() {
        store(["datesize": "9"], explicit: false)
        identity.seed(.display("2"), defaults: defaults)
        store(["datesize": "96.0"])
        XCTAssertEqual(identity.userSetValues(scope: .display("2"), defaults: defaults), ["datesize": "96.0"])
        store(["datesize": "40"], scope: .display("2"))
        XCTAssertEqual(identity.userSetValues(scope: .display("2"), defaults: defaults), ["datesize": "40"],
                       "a display's own values win")
        XCTAssertEqual(identity.userSetValues(scope: .shared, defaults: defaults), ["datesize": "96.0"])
    }

    // MARK: - Scripts

    func testScriptsStartWithTheStoredValuesOfEveryProperty() throws {
        let project = try decodeTolerant(SceneJSON.self, from: Data(#"""
        {"general": {"properties": {
          "clx": {"type": "slider", "value": 0, "min": -2, "max": 2},
          "clock": {"type": "bool", "value": true},
          "schemecolor": {"type": "color", "value": "0 0 0"}}}}
        """#.utf8))
        store(["clx": "1.5", "clock": "false"])
        var properties = SceneScriptUserProperties(project: project)
        properties.setStoredValues(identity.userSetValues(scope: .display("2"), defaults: defaults))

        XCTAssertEqual(properties.value(of: "clx"), .number(1.5), "init() sees the stored slider")
        XCTAssertEqual(properties.value(of: "clock"), .bool(false))
        XCTAssertEqual(properties.value(of: "schemecolor"), .string("0 0 0"), "unset ones keep project.json's")
        let payload = properties.payload()
        XCTAssertEqual(Set(payload.keys), ["clx", "clock", "schemecolor"],
                       "the load's single applyUserProperties gets every property")
        XCTAssertEqual((payload["clx"] as? [String: Any])?["value"] as? Double, 1.5)
    }

    // MARK: - Text

    func testBoundTextStartsWithTheStoredValue() throws {
        let scene = Data(#"""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"}, "general": {},
         "objects": [{"id": 207, "text": {"value": "date"}, "font": "systemfont_arial",
                      "pointsize": {"user": "datesize", "value": 9}}]}
        """#.utf8)
        store(["datesize": "96.0"])
        let decoded = try BoundDocument.decode(WEScene.self, from: scene,
                                               properties: identity.userSetValues(scope: .display("2"), defaults: defaults))
        XCTAssertEqual(decoded.objects.first?.pointsize, 96)
    }

    // MARK: - Web

    func testWebPageGetsTheStoredValuesWithEveryProperty() {
        let properties: [String: WebWallpaperPropertyBridge.Property] = [
            "clock_type": .init(type: "combo", defaultValue: "2"),
            "visual_bar2_enabled": .init(type: "bool", defaultValue: "false")
        ]
        store(["clock_type": "1"])
        let values = WebWallpaperPropertyBridge.currentValues(
            properties: properties, stored: identity.userSetValues(scope: .display("2"), defaults: defaults))
        XCTAssertEqual(values, ["clock_type": "1", "visual_bar2_enabled": "false"])
        let payload = WebWallpaperPropertyBridge.payload(properties: properties, values: values)
        XCTAssertEqual(Set(payload.keys), ["clock_type", "visual_bar2_enabled"])
    }
}
