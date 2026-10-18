// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EvenSound",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "EvenSound", targets: ["EvenSound"]),
        .library(name: "EvenSoundDSP", targets: ["EvenSoundDSP"]),
    ],
    targets: [
        .target(name: "EvenSoundDSP"),
        .executableTarget(
            name: "EvenSound",
            dependencies: ["EvenSoundDSP"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "EvenSoundDSPTests", dependencies: ["EvenSoundDSP"]),
    ],
    swiftLanguageModes: [.v5]
)
