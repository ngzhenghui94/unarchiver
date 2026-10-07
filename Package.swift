// swift-tools-version:5.9
import PackageDescription

// Absolute path: #filePath can be relative under the swift-build backend.
let frameworkDirectory = Context.packageDirectory + "/build/deps"

let package = Package(
    name: "Archiver",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CLibArchive",
            path: "Sources/CLibArchive"
        ),
        .executableTarget(
            name: "Archiver",
            dependencies: ["CLibArchive"],
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
