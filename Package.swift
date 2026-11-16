// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pua",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "pua", targets: ["pua"])],
    targets: [
        .target(
            name: "PuaKit",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("FoundationModels"),
            ]
        ),
        .executableTarget(name: "pua", dependencies: ["PuaKit"]),
    ]
)
