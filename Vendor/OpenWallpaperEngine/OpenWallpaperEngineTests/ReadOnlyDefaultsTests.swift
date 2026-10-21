import XCTest
@testable import OpenWallpaperEngine

/// A helper run (shader prewarm) reads the user's defaults and never writes them.
final class ReadOnlyDefaultsTests: XCTestCase {
    /// A read-only view puts the domain it reads into the registration domain, which every
    /// defaults object of the process searches: right in a helper run, which only reads, but in
    /// the test host it would hand the isolated store's keys (the settings identity registry,
    /// say) to every other test's own suite. Each test puts it back as it was.
    private var registered: [String: Any] = [:]

    override func setUp() {
        registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
    }

    func testReadOnlyViewReadsButNeverWritesTheDomain() throws {
        let domain = "app.openwallpaperengine.isolated.tests.readonly-base-\(UUID().uuidString)"
        let scratch = domain + ".scratch"
        let base = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            base.removePersistentDomain(forName: domain)
            UserDefaults(suiteName: scratch)?.removePersistentDomain(forName: scratch)
        }
        base.set("user value", forKey: "Setting")
        let view = AppStorageLocation.readOnlyView(of: base, domain: domain, scratchSuite: scratch)
        XCTAssertEqual(view.string(forKey: "Setting"), "user value")
        view.set("changed", forKey: "Setting")
        view.set(1, forKey: "New")
        view.removeObject(forKey: "Setting")
        XCTAssertEqual(base.persistentDomain(forName: domain) as NSDictionary?, ["Setting": "user value"] as NSDictionary)
        view.removePersistentDomain(forName: scratch)
        XCTAssertNil(view.persistentDomain(forName: scratch)?["New"])
    }

    func testHelperRunsUseReadOnlyDefaults() {
        XCTAssertTrue(HelperRunCommand.isHelperRun(arguments: ["app", "--prewarm-shaders"]))
        XCTAssertTrue(HelperRunCommand.isHelperRun(arguments: ["app", "--print-shader-cache-key"]))
        XCTAssertFalse(HelperRunCommand.isHelperRun(arguments: ["app", "-OWEIsolatedState", "x"]))
        let location = AppStorageLocation(isolationTag: "tests", readOnlyDefaults: true)
        defer { location.discardReadOnlyScratch() }
        XCTAssertNotNil(location.readOnlyScratchSuite)
        XCTAssertNotEqual(location.defaults, AppStorageLocation.current.defaults)
    }
}
