// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iExplorer",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "iExplorer", targets: ["iExplorer"]),
    ],
    dependencies: [
        // Émulateur de terminal (licence MIT) pour le terminal intégré.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // Bibliothèques communes avec iBaobab : occupation du disque et mise à jour automatique.
        .package(url: "https://github.com/blegal/iBaobab", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "iExplorer",
            dependencies: [
                .product(name: "DiskUsageKit", package: "iBaobab"),
                .product(name: "UpdateKit", package: "iBaobab"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/iExplorer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
