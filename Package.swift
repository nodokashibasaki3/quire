// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quire",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "Quire",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Quire"
        )
    ]
)
