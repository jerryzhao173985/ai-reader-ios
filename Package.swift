// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIReaderApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AIReaderApp",
            targets: ["AIReaderApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/witekbobrowski/EPUBKit.git", from: "1.0.0"),
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "AIReaderApp",
            dependencies: [
                "EPUBKit",
                "Zip",
                "SwiftSoup"
            ]
        ),
        .testTarget(
            name: "AIReaderAppTests",
            dependencies: ["AIReaderApp"]
        )
    ]
)
