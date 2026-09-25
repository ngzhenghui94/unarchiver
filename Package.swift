// swift-tools-version:5.9
import PackageDescription

// Absolute path: #filePath can be relative under the swift-build backend.
let frameworkDirectory = Context.packageDirectory + "/build/deps"

let package = Package(
    name: "Unarchiver",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Unarchiver",
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
