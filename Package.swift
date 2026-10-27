// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemindBar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RemindCore", targets: ["RemindCore"]),
        .executable(name: "RemindBar", targets: ["RemindBar"]),
        .executable(name: "remind-selftest", targets: ["RemindSelfTest"])
    ],
    targets: [
        .target(name: "RemindCore", path: "Sources/RemindCore"),
        .executableTarget(name: "RemindBar", dependencies: ["RemindCore"], path: "Sources/RemindBar"),
        .executableTarget(name: "RemindSelfTest", dependencies: ["RemindCore"], path: "Tools/SelfTest")
    ],
    swiftLanguageModes: [.v5]
)
