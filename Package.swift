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
        // Compression zstd (licence BSD) pour les archives .tar.zst.
        .package(url: "https://github.com/facebook/zstd", exact: "1.5.7"),
    ],
    targets: [
        .executableTarget(
            name: "iExplorer",
            dependencies: [
                .product(name: "DiskUsageKit", package: "iBaobab"),
                .product(name: "UpdateKit", package: "iBaobab"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "libzstd", package: "zstd"),
                "CLZ4",
            ],
            path: "Sources/iExplorer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Sources officielles de LZ4 1.10.0 (licence BSD-2, voir Sources/CLZ4/LICENSE) pour les archives .tar.lz4.
        .target(
            name: "CLZ4",
            path: "Sources/CLZ4",
            cSettings: [.define("XXH_NAMESPACE", to: "LZ4_")]
        ),
    ]
)
