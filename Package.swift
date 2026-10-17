// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeMotionMac",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "EdgeMotion", targets: ["EdgeMotionApp"])
    ],
    targets: [
        .target(
            name: "EdgeMotionInputBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(name: "EdgeMotionInputCore", dependencies: ["EdgeMotionInputBridge"]),
        .target(name: "EdgeMotionCore", dependencies: ["EdgeMotionInputCore"]),
        .target(name: "EdgeMotionUpdateCore"),
        .executableTarget(name: "EdgeMotionApp", dependencies: ["EdgeMotionCore", "EdgeMotionInputCore", "EdgeMotionInputBridge", "EdgeMotionUpdateCore"]),
        .testTarget(name: "EdgeMotionInputCoreTests", dependencies: ["EdgeMotionInputCore", "EdgeMotionCore"]),
        .testTarget(name: "EdgeMotionUpdateCoreTests", dependencies: ["EdgeMotionUpdateCore"])
    ]
)
