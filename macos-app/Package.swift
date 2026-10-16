// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRReviews",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PRReviews", path: "Sources/PRReviews")
    ]
)
