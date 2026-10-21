// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Sparkle", platforms: [.macOS(.v12)], products: [.library(name:"Sparkle",targets:["Sparkle"])], targets:[.binaryTarget(name:"Sparkle",path:"Sparkle.xcframework")])
