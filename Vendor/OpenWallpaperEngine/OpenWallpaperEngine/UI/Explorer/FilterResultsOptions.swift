//
//  FilterResultsOptions.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

/// One checkbox of a filter. `key` is the option's stored spelling: WE's tag, matched against the
/// wallpapers' tags and never shown; `label` is what the sidebar shows, in the user's language.
/// Option `i` of a filter is bit `1 << i` of its stored value, so the order of a filter's options
/// is part of what is saved.
struct FilterOption: Equatable, ExpressibleByStringLiteral {
    let key: String
    /// The symbol shown before the label, if any.
    var systemImage: String?

    init(key: String, systemImage: String? = nil) {
        self.key = key
        self.systemImage = systemImage
    }

    init(stringLiteral key: String) {
        self.init(key: key)
    }

    var label: LocalizedStringResource { LocalizedLabels.filterOption(key) }
}

/// A filter of the Installed tab's sidebar: one bit per option of `options`.
protocol FilterResultsModel: OptionSet where Element == Self, RawValue == Int {
    static var options: [FilterOption] { get }
    static var all: Self { get }
    static var none: Self { get }
}

extension FilterResultsModel {
    /// The options' keys, in bit order.
    static var optionKeys: [String] { options.map(\.key) }
}

struct FRShowOnly: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        FilterOption(key: "Approved", systemImage: "trophy.fill"),
        FilterOption(key: "My Favourites", systemImage: "heart.fill"),
        FilterOption(key: "Mobile Compatible", systemImage: "iphone.gen3"),
        FilterOption(key: "Audio Responsive", systemImage: "waveform"),
        FilterOption(key: "Customizable", systemImage: "slider.horizontal.3")
    ]
    
    static let approved             = FRShowOnly(rawValue: 1 << 0)
    static let myFavourites         = FRShowOnly(rawValue: 1 << 1)
    static let mobileCompatible     = FRShowOnly(rawValue: 1 << 2)
    static let audioResponsive      = FRShowOnly(rawValue: 1 << 3)
    static let customizable         = FRShowOnly(rawValue: 1 << 4)
    
    static let all: FRShowOnly = [.approved, myFavourites, mobileCompatible, .audioResponsive, .customizable]
    static let none: FRShowOnly = []
}

struct FRType: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Scene",
        "Video",
        "Web",
        "Application"
    ]
    static let scene            = FRType(rawValue: 1 << 0)
    static let video            = FRType(rawValue: 1 << 1)
    static let web              = FRType(rawValue: 1 << 2)
    static let application      = FRType(rawValue: 1 << 3)
    
    static let all: FRType      = [.scene, .video, .web, .application]
    static let none: FRType     = []
}

/// WE's Category filter (`getWallpaperCategoryTags`): an ordinary wallpaper, or a Workshop preset
/// item (`WorkshopPresetItem`), which plays its base (`dependency`) with its own values. The
/// Workshop tab filters the same way through the items' `Wallpaper` and `Preset` tags.
struct FRCategory: FilterResultsModel {
    let rawValue: Int

    static let options = WorkshopTags.categories.map { FilterOption(key: $0) }

    static let wallpaper        = FRCategory(rawValue: 1 << 0)
    static let preset           = FRCategory(rawValue: 1 << 1)

    static let all: FRCategory  = [.wallpaper, .preset]
    static let none: FRCategory = []

    /// The category `wallpaper` belongs to.
    static func of(_ wallpaper: WEWallpaper) -> FRCategory {
        wallpaper.isWorkshopPreset ? .preset : .wallpaper
    }
}

struct FRAgeRating: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Everyone",
        "Partial Nudity",
        "Mature"
    ]
    
    static let everyone             = FRAgeRating(rawValue: 1 << 0)
    static let partialNudity        = FRAgeRating(rawValue: 1 << 1)
    static let mature               = FRAgeRating(rawValue: 1 << 2)
    
    static let all: FRAgeRating     = [.everyone, .partialNudity, .mature]
    static let none: FRAgeRating    = []
}

struct FRWidescreenResolution: FilterResultsModel {
    let rawValue: Int
    
    /// WE's tags (`WEResolutionTags`), in bit order; 1366 x 768 came last so stored bits keep
    /// their meaning.
    static let options: [FilterOption] = [
        "Standard Definition",
        "1280 x 720",
        "1920 x 1080",
        "2560 x 1440",
        "3840 x 2160",
        "1366 x 768"
    ]
    
    static let standardDefinition   = Self.init(rawValue: 1 << 0)
    static let resolution1280x720   = Self.init(rawValue: 1 << 1)
    static let resolution1920x1080  = Self.init(rawValue: 1 << 2)
    static let resolution2560x1440  = Self.init(rawValue: 1 << 3)
    static let resolution3840x2160  = Self.init(rawValue: 1 << 4)
    static let resolution1366x768   = Self.init(rawValue: 1 << 5)
    
    static let all: Self            = [.standardDefinition, resolution1280x720, resolution1920x1080, .resolution2560x1440, .resolution3840x2160, .resolution1366x768]
    static let none: Self           = []
}

struct FRUltraWidescreenResolution: FilterResultsModel {
    let rawValue: Int
    
    
    static let options: [FilterOption] = [
        "Ultrawide Standard Definition",
        "Ultrawide 2560 x 1080",
        "Ultrawide 3440 x 1440",
    ]
    
    static let ultrawideStandard    = FRUltraWidescreenResolution(rawValue: 1 << 0)
    static let resolution2560x1080  = FRUltraWidescreenResolution(rawValue: 1 << 1)
    static let resolution3440x1440  = FRUltraWidescreenResolution(rawValue: 1 << 2)
    
    static let all: FRUltraWidescreenResolution = [.ultrawideStandard, resolution2560x1080, .resolution3440x1440]
    static let none: FRUltraWidescreenResolution = []
}

struct FRDualscreenResolution: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Dual Standard Definition",
        "Dual 3840 x 1080",
        "Dual 5120 x 1440",
        "Dual 7680 x 2160"
    ]
    
    static let dualStandard         = Self.init(rawValue: 1 << 0)
    static let resolution3840x1080  = Self.init(rawValue: 1 << 1)
    static let resolution5120x1440  = Self.init(rawValue: 1 << 2)
    static let resolution7680x2160  = Self.init(rawValue: 1 << 3)
    
    static let all: Self = [.dualStandard, .resolution3840x1080, .resolution5120x1440, .resolution7680x2160]
    static let none: Self = []
}

struct FRTriplescreenResolution: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
            "Triple Standard Definition",
            "Triple 4096 x 768",
            "Triple 5760 x 1080",
            "Triple 7680 x 1440",
            "Triple 11520 x 2160"
        ]
    
    static let tripleStandard        = FRTriplescreenResolution(rawValue: 1 << 0)
    static let resolution4096x768    = FRTriplescreenResolution(rawValue: 1 << 1)
    static let resolution5760x1080   = FRTriplescreenResolution(rawValue: 1 << 2)
    static let resolution7680x1440   = FRTriplescreenResolution(rawValue: 1 << 3)
    static let resolution11520x2160  = FRTriplescreenResolution(rawValue: 1 << 4)
    
    static let all: FRTriplescreenResolution = [.tripleStandard, resolution4096x768, resolution5760x1080, resolution7680x1440, resolution11520x2160]
    static let none: FRTriplescreenResolution = []
}

struct FRPortraitScreenResolution: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Portrait Standard Definition",
        "Portrait 720 x 1280",
        "Portrait 1080 x 1920",
        "Portrait 1440 x 2560",
        "Portrait 2160 x 3840"
    ]
    
    static let portraitStandard     = Self.init(rawValue: 1 << 0)
    static let resolution720x1280   = Self.init(rawValue: 1 << 1)
    static let resolution1080x1920  = Self.init(rawValue: 1 << 2)
    static let resolution1440x2560  = Self.init(rawValue: 1 << 3)
    static let resolution2160x3840  = Self.init(rawValue: 1 << 4)
    
    static let all: Self            = [.portraitStandard, .resolution720x1280, .resolution1080x1920, .resolution1440x2560, .resolution2160x3840]
    static let none: Self           = []
}

struct FRMiscResolution: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Other resolution",
        "Dynamic resolution"
    ]
    
    static let otherResolution     = Self.init(rawValue: 1 << 0)
    static let dynamicResolution   = Self.init(rawValue: 1 << 1)
    
    static let all: Self           = [.otherResolution, .dynamicResolution]
    static let none: Self          = []
}

struct FRSource: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Official",
        "Workshop",
        "MyWallpapers"
    ]
    
    static let official        = Self.init(rawValue: 1 << 0)
    static let workshop        = Self.init(rawValue: 1 << 1)
    static let myWallpapers    = Self.init(rawValue: 1 << 2)
    
    static let all: Self       = [.official, .workshop, .myWallpapers]
    static let none: Self      = []
}

struct FRTag: FilterResultsModel {
    let rawValue: Int
    
    static let options: [FilterOption] = [
        "Abstract",
        "Animal",
        "Anime",
        "Cartoon",
        "CGI",
        "Cyberpunk",
        "Fantasy",
        "Game",
        "Girls",
        "Guys",
        "Landscape",
        "Medieval",
        "Memes",
        "MMD",
        "Music",
        "Nature",
        "PixelArt",
        "Relaxing",
        "Retro",
        "Sci-Fi",
        "Sports",
        "Technology",
        "Television",
        "Vehicle",
        "UnspecifiedGenre"
    ]
    
    static let abstract             = FRTag(rawValue: 1 << 0)
    static let animal               = FRTag(rawValue: 1 << 1)
    static let anime                = FRTag(rawValue: 1 << 2)
    static let cartoon              = FRTag(rawValue: 1 << 3)
    static let cgi                  = FRTag(rawValue: 1 << 4)
    static let cyberpunk            = FRTag(rawValue: 1 << 5)
    static let fantasy              = FRTag(rawValue: 1 << 6)
    static let game                 = FRTag(rawValue: 1 << 7)
    static let girls                = FRTag(rawValue: 1 << 8)
    static let guys                 = FRTag(rawValue: 1 << 9)
    static let landscape            = FRTag(rawValue: 1 << 10)
    static let medieval             = FRTag(rawValue: 1 << 11)
    static let memes                = FRTag(rawValue: 1 << 12)
    static let mmd                  = FRTag(rawValue: 1 << 13)
    static let music                = FRTag(rawValue: 1 << 14)
    static let nature               = FRTag(rawValue: 1 << 15)
    static let pixelArt             = FRTag(rawValue: 1 << 16)
    static let relaxing             = FRTag(rawValue: 1 << 17)
    static let retro                = FRTag(rawValue: 1 << 18)
    static let sciFi                = FRTag(rawValue: 1 << 19)
    static let sports               = FRTag(rawValue: 1 << 20)
    static let technology           = FRTag(rawValue: 1 << 21)
    static let television           = FRTag(rawValue: 1 << 22)
    static let vehicle              = FRTag(rawValue: 1 << 23)
    static let unspecifiedGenre     = FRTag(rawValue: 1 << 24)
    
    static let all: FRTag = [
        .abstract, .animal, .anime, .cartoon, .cgi, .cyberpunk, .fantasy, .game, .girls,
        .guys, .landscape, .medieval, .memes, .mmd, .music, .nature, .pixelArt, .relaxing,
        .retro, .sciFi, .sports, .technology, .television, .vehicle, .unspecifiedGenre
    ]
    static let none: FRTag = []
}
