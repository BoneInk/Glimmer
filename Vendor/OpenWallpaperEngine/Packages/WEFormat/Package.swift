// swift-tools-version:5.9
// Wallpaper Engine's file formats, the one home for reading and writing them (docs/architecture.md):
// tolerant JSON (WE's byte order mark, comments and trailing commas) and the hex spelling of
// digests. Foundation only, with no logging, threads or images of its own: callers get errors back.
// The app's framework and the editor package (OWESceneEditing) both link it.
import PackageDescription

let package = Package(
    name: "WEFormat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WEFormat", targets: ["WEFormat"]),
    ],
    targets: [
        .target(name: "WEFormat"),
        .testTarget(name: "WEFormatTests", dependencies: ["WEFormat"]),
    ]
)
