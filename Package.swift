// swift-tools-version: 6.2
// Glyph Time: a quiet count-up on the edge of the screen, every session saved as plain files.
// Shares GlyphCore's GlyphVault (the session format, TimeLog). Build: scripts/build.sh.
import PackageDescription

let package = Package(
    name: "GlyphTime",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "Packages/GlyphCore")],
    targets: [
        .executableTarget(
            name: "GlyphTime",
            dependencies: [.product(name: "GlyphVault", package: "GlyphCore")],
            path: "Sources/GlyphTime"
        ),
    ],
    swiftLanguageModes: [.v5]
)
