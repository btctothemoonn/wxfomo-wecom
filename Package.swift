// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "wxFomo",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "wxfomo", targets: ["WxFomoCLI"]),
    .executable(name: "wxfomo-gui", targets: ["WxFomoApp"]),
    .executable(name: "wxfomo-selftest", targets: ["WxFomoSelfTest"]),
    .library(name: "WxFomoCore", targets: ["WxFomoCore"]),
  ],
  targets: [
    .target(
      name: "WxFomoCore",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Vision"),
        .linkedLibrary("sqlite3"),
      ]
    ),
    .executableTarget(
      name: "WxFomoCLI",
      dependencies: ["WxFomoCore"]
    ),
    .executableTarget(
      name: "WxFomoApp",
      dependencies: ["WxFomoCore"],
      linkerSettings: [
        .linkedFramework("AVFoundation")
      ]
    ),
    .executableTarget(
      name: "WxFomoSelfTest",
      dependencies: ["WxFomoCore"]
    ),
  ]
)
