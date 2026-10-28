// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnhancedFileManager",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "EnhancedFileManager", targets: ["EnhancedFileManager"]),
    ],
    dependencies: [
        // Émulateur de terminal (licence MIT) pour le terminal intégré.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Analyse et graphiques d'occupation du disque, partagés entre applications.
        .target(
            name: "DiskUsageKit",
            path: "Sources/DiskUsageKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EnhancedFileManager",
            dependencies: ["DiskUsageKit", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/EnhancedFileManager",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
