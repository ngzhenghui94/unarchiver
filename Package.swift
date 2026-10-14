// swift-tools-version:5.9
import PackageDescription

// Absolute path: #filePath can be relative under the swift-build backend.
let frameworkDirectory = Context.packageDirectory + "/build/deps"

let package = Package(
    name: "Archiver",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .systemLibrary(
            name: "CLibArchive",
            path: "Sources/CLibArchive"
        ),
        .executableTarget(
            name: "Archiver",
            dependencies: ["CLibArchive", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Unarchiver",
            swiftSettings: [
                .unsafeFlags(["-F", frameworkDirectory])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", frameworkDirectory]),
                .linkedFramework("XADMaster"),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
