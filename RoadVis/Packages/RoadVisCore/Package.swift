// swift-tools-version:5.9
// RoadVisCore — platform-independent logic of the RoadVis app
// (geometry, tracking, OSM parsing, route progress, chat protocol).
// It depends only on Foundation, so it builds and is tested on Linux and macOS.
// The iOS app compiles these same source files directly into the app target
// (see RoadVis.xcodeproj: synchronized folder Packages/RoadVisCore/Sources/RoadVisCore),
// therefore app code must NOT `import RoadVisCore`.
import PackageDescription

let package = Package(
    name: "RoadVisCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoadVisCore", targets: ["RoadVisCore"]),
    ],
    targets: [
        .target(name: "RoadVisCore"),
        .testTarget(
            name: "RoadVisCoreTests",
            dependencies: ["RoadVisCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
