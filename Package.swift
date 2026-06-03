// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wattusb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "wattusb",
            path: "Sources/wattusb",
            exclude: ["Info.plist"]
        )
    ]
)
