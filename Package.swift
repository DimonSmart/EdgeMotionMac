// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeMotionMac",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "EdgeMotionHardwareDiagnostic", targets: ["EdgeMotionHardwareDiagnostic"]),
        .executable(name: "EdgeMotion", targets: ["EdgeMotionApp"])
    ],
    targets: [
        .target(
            name: "EdgeMotionDiagnosticBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(name: "EdgeMotionDiagnosticCore", dependencies: ["EdgeMotionDiagnosticBridge"]),
        .target(name: "EdgeMotionCore", dependencies: ["EdgeMotionDiagnosticCore"]),
        .target(name: "EdgeMotionUpdateCore"),
        .executableTarget(name: "EdgeMotionHardwareDiagnostic", dependencies: ["EdgeMotionDiagnosticCore"]),
        .executableTarget(name: "EdgeMotionApp", dependencies: ["EdgeMotionCore", "EdgeMotionDiagnosticCore", "EdgeMotionDiagnosticBridge", "EdgeMotionUpdateCore"]),
        .testTarget(name: "EdgeMotionDiagnosticCoreTests", dependencies: ["EdgeMotionDiagnosticCore", "EdgeMotionCore"]),
        .testTarget(name: "EdgeMotionUpdateCoreTests", dependencies: ["EdgeMotionUpdateCore"])
    ]
)
