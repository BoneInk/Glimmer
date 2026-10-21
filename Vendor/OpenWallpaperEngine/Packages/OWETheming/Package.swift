// swift-tools-version:5.9
// Theming macOS with the wallpaper's scheme colour (docs/theming.md), kept out of the app target:
// the colour (WE's "r g b" scheme colour, OKLab, the accent palette, a snapshot's main colour), the
// menu bar strip drawn into the desktop picture, and the system preferences it writes. Every write
// goes through `SystemAppearanceWriter`, so the tests never touch the Mac's settings. Foundation,
// CoreGraphics and ImageIO only; the app supplies the screens, the wallpaper and the settings UI.
import PackageDescription

let package = Package(
    name: "OWETheming",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OWETheming", targets: ["OWETheming"]),
    ],
    targets: [
        .target(name: "OWETheming"),
        .testTarget(name: "OWEThemingTests", dependencies: ["OWETheming"]),
    ]
)
