import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// The library's sort menu names the selected method, in every language.
@MainActor
final class SortByMenuTests: XCTestCase {
    private var languages: [String] { Bundle.main.localizations.filter { $0 != "Base" } }

    private func localized(_ resource: LocalizedStringResource, _ language: String) -> String {
        var resource = resource
        resource.locale = Locale(identifier: language)
        return String(localized: resource)
    }

    func testEverySortMethodHasATitleInEveryLanguage() {
        XCTAssertFalse(languages.isEmpty)
        for method in WEWallpaperSortingMethod.allCases {
            for language in languages {
                let title = localized(method.displayName, language)
                XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty, "\(method) has no \(language) title")
            }
        }
    }

    func testTheMenuLabelShowsTheSelection() {
        for method in WEWallpaperSortingMethod.allCases {
            let menu = SortByMenu(selection: .constant(method))
            for language in languages {
                XCTAssertEqual(localized(menu.title, language), localized(method.displayName, language),
                               "\(method) in \(language)")
            }
        }
        let titles = WEWallpaperSortingMethod.allCases.map { localized(SortByMenu(selection: .constant($0)).title, "en") }
        XCTAssertEqual(Set(titles).count, titles.count, "two sort methods share a label")
    }
}
