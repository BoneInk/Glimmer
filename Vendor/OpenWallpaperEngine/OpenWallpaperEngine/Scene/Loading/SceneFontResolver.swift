//
//  SceneFontResolver.swift
//  Open Wallpaper Engine
//
//  Finds the font a text layer names, in the order WE looks for it:
//  1. the wallpaper's own package or folder,
//  2. WE's built-in assets (`fonts/Atami-Regular.otf`: a configured install, then the bundled copy),
//  3. another Workshop item (`fonts/workshop/<id>/Quicksand-Bold.otf`),
//  4. `systemfont_<name>`, an operating-system font.
//

import AppKit

struct SceneFontResolver {
    enum Source: Equatable {
        case wallpaper, weAssets, workshop
    }

    enum Resolution: Equatable {
        /// Font file bytes to register.
        case data(Data, Source)
        /// An installed macOS font family.
        case system(String)
    }

    static let systemFontPrefix = "systemfont_"

    /// WE's `systemfont_*` names: `wallpaper64.exe`'s table at 0x140484cc0 (editor name, scene
    /// name, file) holds these eight, and the text object loads `<Windows fonts folder>\<file>`
    /// (0x1401b05b6); any other name isn't in the table, and a face that fails to load falls back to
    /// `arial.ttf` (0x1401ad549). Each maps to the family its file holds and, where macOS doesn't
    /// ship that family, the installed family used in its place (an installed copy, from Office
    /// say, wins):
    ///
    /// | Name | File | Family | macOS stand-in |
    /// |---|---|---|---|
    /// | arial | arial.ttf | Arial | (ships) |
    /// | calibri | calibri.ttf | Calibri | Helvetica Neue [I: no capture to measure] |
    /// | cambria | cambria.ttc | Cambria | Times New Roman: measured against WE's capture of 3378346807 |
    /// | comicsans | comic.ttf | Comic Sans MS | (ships) |
    /// | consolas | consola.ttf | Consolas | Menlo (monospace) [I] |
    /// | sansserif | micross.ttf | Microsoft Sans Serif | (ships) |
    /// | segoe | segoeui.ttf | Segoe UI | Helvetica Neue [I] |
    /// | verdana | verdana.ttf | Verdana | (ships) |
    ///
    /// Cambria: WE's clock in 3378346807 (8 pt, three lines) measures a 32-unit ascender, a 39-unit
    /// line, a 23-unit cap height and line widths of 170, 179 and 120 units. Of the installed serifs,
    /// Times New Roman comes closest over all of these (30, 38, 22, and 168, 176, 115 with WE's
    /// floored advances); Georgia, the old stand-in, is 186, 195 and 129 wide.
    static let weSystemFonts: [String: (family: String, standIn: String?)] = [
        "arial": ("Arial", nil),
        "calibri": ("Calibri", "Helvetica Neue"),
        "cambria": ("Cambria", "Times New Roman"),
        "comicsans": ("Comic Sans MS", nil),
        "consolas": ("Consolas", "Menlo"),
        "sansserif": ("Microsoft Sans Serif", nil),
        "segoe": ("Segoe UI", "Helvetica Neue"),
        "verdana": ("Verdana", nil),
    ]

    /// Looks the path up in the wallpaper's own package or folder.
    let wallpaperData: (String) -> Data?
    /// WE asset roots, most preferred first (configured install, bundled copy).
    let assetDirectories: [URL]
    let workshop: WorkshopAssetResolver
    /// Installed font families; injectable for tests.
    var availableFamilies: () -> [String] = { NSFontManager.shared.availableFontFamilies }

    func resolve(_ path: String) -> Resolution? {
        if path.lowercased().hasPrefix(Self.systemFontPrefix) {
            return systemFont(for: String(path.dropFirst(Self.systemFontPrefix.count))).map(Resolution.system)
        }
        if let data = wallpaperData(path) { return .data(data, .wallpaper) }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if WorkshopAssetResolver.reference(in: normalized) == nil {
            for root in assetDirectories {
                do {
                    if let data = try AssetPathResolver.data(normalized, in: root) { return .data(data, .weAssets) }
                } catch {
                    OWELog.error(.scene, "Failed to read font \(normalized) in \(root.path): \(error)")
                }
            }
        } else if let data = workshop.data(for: normalized) {
            return .data(data, .workshop)
        }
        return nil
    }

    /// A `systemfont_*` name's family as WE resolves it (`weSystemFonts`): the file's family if it
    /// is installed, else its stand-in; a name outside WE's table is Arial, as WE's fallback is.
    func systemFont(for name: String) -> String? {
        let families = availableFamilies()
        let entry = Self.weSystemFonts[Self.key(name)] ?? Self.weSystemFonts["arial"]!
        for candidate in [entry.family, entry.standIn].compactMap({ $0 }) {
            if let family = families.first(where: { Self.key($0) == Self.key(candidate) }) { return family }
        }
        return nil
    }

    private static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
