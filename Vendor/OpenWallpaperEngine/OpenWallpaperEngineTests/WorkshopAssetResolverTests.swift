import AppKit
import XCTest
@testable import OpenWallpaperEngine

final class WorkshopAssetResolverTests: XCTestCase {
    private let library = Fixtures.url("Workshop/library")
    private let assets = Fixtures.url("Workshop/assets")

    private var resolver: WorkshopAssetResolver {
        WorkshopAssetResolver(roots: [FileManager.default.temporaryDirectory.appending(path: "owe-missing-root"), library])
    }

    func testParsesWorkshopReference() throws {
        let reference = try XCTUnwrap(WorkshopAssetResolver.reference(in: "fonts\\workshop\\2981960200\\Quicksand-Bold.otf"))
        XCTAssertEqual(reference.category, "fonts")
        XCTAssertEqual(reference.workshopId, "2981960200")
        XCTAssertEqual(reference.remainder, "Quicksand-Bold.otf")
        XCTAssertEqual(reference.candidatePaths.first, "fonts/Quicksand-Bold.otf")
        XCTAssertNil(WorkshopAssetResolver.reference(in: "fonts/Atami-Regular.otf"))
        XCTAssertNil(WorkshopAssetResolver.reference(in: "fonts/myworkshop/2981960200/x.ttf"))
    }

    func testResolvesInsideTheItemFolderOfAnyRoot() throws {
        let url = try XCTUnwrap(resolver.url(for: "fonts/workshop/2981960200/x.ttf"))
        XCTAssertEqual(url.standardizedFileURL, library.appending(path: "2981960200/fonts/x.ttf").standardizedFileURL)
        XCTAssertEqual(resolver.data(for: "fonts/workshop/2981960200/x.ttf"), Data("workshop-font".utf8))
        XCTAssertNil(resolver.url(for: "fonts/workshop/2981960200/missing.ttf"))
        XCTAssertNil(resolver.url(for: "fonts/workshop/9999999999/x.ttf"))
        XCTAssertTrue(resolver.isInstalled("1111111111"))
        XCTAssertFalse(resolver.isInstalled("9999999999"))
    }

    func testScansSceneMaterialsAndProjectDependency() {
        let ids = WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: Fixtures.url("Workshop/wallpaper"))
        XCTAssertEqual(ids, ["2981960200", "3333333333", "4444444444"])
    }

    // MARK: - Fonts

    private func fontResolver(own: [String: Data] = [:], families: [String] = []) -> SceneFontResolver {
        var resolver = SceneFontResolver(wallpaperData: { own[$0] }, assetDirectories: [assets], workshop: resolver)
        resolver.availableFamilies = { families }
        return resolver
    }

    func testWallpaperFontWinsOverWEAssets() {
        let resolution = fontResolver(own: ["fonts/Own.otf": Data("own".utf8)]).resolve("fonts/Own.otf")
        XCTAssertEqual(resolution, .data(Data("own".utf8), .wallpaper))
    }

    func testFallsBackToWEAssets() {
        XCTAssertEqual(fontResolver().resolve("fonts/Atami-Regular.otf"), .data(Data("assets-font".utf8), .weAssets))
    }

    func testWorkshopFontComesFromTheItem() {
        XCTAssertEqual(fontResolver().resolve("fonts/workshop/2981960200/x.ttf"), .data(Data("workshop-font".utf8), .workshop))
    }

    /// WE's eight `systemfont_*` names (0x140484cc0) resolve to their Windows family when it is
    /// installed, else to the macOS stand-in; any other name is Arial, WE's fallback (0x1401ad549).
    func testSystemFontsResolveAsWEsTable() {
        let mac = fontResolver(families: ["Arial", "Times New Roman", "Helvetica Neue", "Menlo", "Comic Sans MS",
                                          "Microsoft Sans Serif", "Verdana"])
        XCTAssertEqual(mac.resolve("systemfont_arial"), .system("Arial"))
        XCTAssertEqual(mac.resolve("systemfont_cambria"), .system("Times New Roman"))
        XCTAssertEqual(mac.resolve("systemfont_calibri"), .system("Helvetica Neue"))
        XCTAssertEqual(mac.resolve("systemfont_consolas"), .system("Menlo"))
        XCTAssertEqual(mac.resolve("systemfont_segoe"), .system("Helvetica Neue"))
        XCTAssertEqual(mac.resolve("systemfont_comicsans"), .system("Comic Sans MS"))
        XCTAssertEqual(mac.resolve("systemfont_sansserif"), .system("Microsoft Sans Serif"))
        XCTAssertEqual(mac.resolve("systemfont_verdana"), .system("Verdana"))
        XCTAssertEqual(mac.resolve("systemfont_timesnewroman"), .system("Arial"), "not in WE's table")
        let office = fontResolver(families: ["Arial", "Cambria", "Times New Roman"])
        XCTAssertEqual(office.resolve("systemfont_cambria"), .system("Cambria"), "an installed copy wins")
        XCTAssertNil(fontResolver(families: []).resolve("systemfont_cambria"))
    }

    /// The per-layer font setting is seeded with the scene's `systemfont_*` name; the loader
    /// registers the resolved family under it (3378346807's clock drew in the fallback face).
    func testASystemFontNameFindsItsFamily() throws {
        let installed = try XCTUnwrap(NSFontManager.shared.font(withFamily: "Times New Roman", traits: [], weight: 5, size: 12))
        SceneFontRegistry.register(postScriptName: installed.fontName, names: ["systemfont_test_cambria"])
        XCTAssertEqual(SceneFontRegistry.font(named: "systemfont_test_cambria", size: 33)?.familyName, "Times New Roman")
    }

    /// Every stand-in and every family that ships with macOS is installed here.
    func testSystemFontStandInsAreInstalled() {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for (name, entry) in SceneFontResolver.weSystemFonts {
            XCTAssertTrue(installed.contains(entry.standIn ?? entry.family), name)
        }
    }

    func testMissingFontResolvesToNothing() {
        XCTAssertNil(fontResolver().resolve("fonts/Nope.otf"))
    }
}
