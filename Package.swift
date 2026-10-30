// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KittyClear",
    platforms: [.macOS(.v14)],
    targets: [
        // What the app and the battery helper both need to know about the Mac's charging hardware.
        .target(name: "Hardware"),
        .executableTarget(name: "KittyClear", dependencies: ["Hardware"]),
        // The small root daemon behind 电池养护; build-app.sh puts it in the app's Resources.
        .executableTarget(name: "KittyClearBattery", dependencies: ["Hardware"]),
    ]
)
