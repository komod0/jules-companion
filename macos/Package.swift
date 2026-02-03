// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jules",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "JulesLib", targets: ["JulesLib"])
    ],
    dependencies: [
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", branch: "main"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.8.0"),
        .package(url: "https://github.com/ra1028/DifferenceKit.git", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "JulesLib",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "DifferenceKit", package: "DifferenceKit"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "jules",
            exclude: [
                "julesApp.swift",
                "Assets.xcassets",
                "Info.plist"
            ]
        )
    ]
)
