// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "vde-notifier-app",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "VdeNotifierAppCore", targets: ["VdeNotifierAppCore"]),
    .executable(name: "vde-notifier-app", targets: ["VdeNotifierApp"])
  ],
  targets: [
    .target(
      name: "VdeNotifierAppCore",
      path: "Sources/VdeNotifierAppCore"
    ),
    .executableTarget(
      name: "VdeNotifierApp",
      dependencies: ["VdeNotifierAppCore"],
      path: "Sources/VdeNotifierApp"
    ),
    .testTarget(
      name: "VdeNotifierAppCoreTests",
      dependencies: ["VdeNotifierAppCore"],
      path: "Tests/VdeNotifierAppCoreTests"
    )
  ]
)
