// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Unarchiver",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Unarchiver", path: "Sources/Unarchiver")
    ]
)
