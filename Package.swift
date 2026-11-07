// swift-tools-version: 6.2
// Glyph Time: a quiet count-up on the edge of the screen, every session saved as plain files.
// Shares GlyphCore's GlyphVault (the session format, TimeLog). Build: scripts/build.sh.
// Shared/ is History, the same files the iPhone app compiles (project.yml).
import PackageDescription

let package = Package(
    name: "GlyphTime",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "Packages/GlyphCore")],
    targets: [
        .executableTarget(
            name: "GlyphTime",
            dependencies: [.product(name: "GlyphVault", package: "GlyphCore"), .product(name: "GlyphCapture", package: "GlyphCore")],
            path: ".",
            exclude: ["assets", "build", "iPhone", "iPhoneUITests", "scripts", "README.md", "LICENSE", "TimeLogCheck.swift", "ActivityCheck.swift"],
            sources: ["Sources/GlyphTime", "Shared"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
