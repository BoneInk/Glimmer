// swift-tools-version: 6.0
// Glimmer — 原生 macOS 视频壁纸应用
// 该 Package.swift 仅用于 IDE 索引与可选工具的 swift build；
// 正式 .app 由 scripts/build-app.sh 使用 swiftc CLI 直接编译打包，保证独立于 Xcode 工程。
import PackageDescription

let package = Package(
    name: "Glimmer",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "Vendor/OpenWallpaperEngine/Vendor/Sparkle")
    ],
    targets: [
        .executableTarget(
            name: "Glimmer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Glimmer"
        )
    ]
)
