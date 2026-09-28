// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoolWeb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CoolWeb",
            resources: [.copy("web")]
        )
    ]
)
