// swift-tools-version:5.9
// ufbx, the single-file FBX and OBJ loader, built from its pinned upstream release (see README.md).
// The Wallpaper Editor's model import (Packages/OWEEditor, OWEModelImport) is its only user.
import PackageDescription

let package = Package(
    name: "CUfbx",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CUfbx", targets: ["CUfbx"]),
    ],
    targets: [
        .target(
            name: "CUfbx",
            path: "Sources/CUfbx",
            publicHeadersPath: "include",
            cSettings: [
                // Release semantics: an upstream assert must not abort the app.
                .define("NDEBUG"),
            ]
        ),
    ]
)
