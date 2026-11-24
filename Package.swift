// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Veda",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Veda", targets: ["Veda"])
    ],
    targets: [
        .executableTarget(
            name: "Veda",
            path: "Sources/Veda"
        )
    ]
)
