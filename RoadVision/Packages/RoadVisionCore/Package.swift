// swift-tools-version:5.9
// RoadVisionCore — platform-independent logic of the RoadVision app
// (geometry, tracking, OSM parsing, route progress, chat protocol).
// It depends only on Foundation, so it builds and is tested on Linux and macOS.
// The iOS app compiles these same source files directly into the app target
// (see RoadVision.xcodeproj: synchronized folder Packages/RoadVisionCore/Sources/RoadVisionCore),
// therefore app code must NOT `import RoadVisionCore`.
import PackageDescription

let package = Package(
    name: "RoadVisionCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoadVisionCore", targets: ["RoadVisionCore"]),
    ],
    targets: [
        .target(name: "RoadVisionCore"),
        .testTarget(
            name: "RoadVisionCoreTests",
            dependencies: ["RoadVisionCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
