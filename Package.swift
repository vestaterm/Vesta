// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v13)],
    targets: [
        // Real libghostty, built from ghostty source (zig 0.15.2) as an xcframework.
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        // Vendored Lua 5.4.7 (embedded scripting runtime; see Sources/CLua/PROVENANCE.txt).
        .target(
            name: "CLua",
            path: "Sources/CLua",
            cSettings: [.define("LUA_USE_MACOSX")]   // POSIX + dlopen-based require on macOS
        ),
        .executableTarget(
            name: "halo",
            dependencies: ["GhosttyKit", "HaloMux", "CLua"],
            path: "Sources/Halo",
            resources: [.copy("Resources/Fonts")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "HaloMux",
            path: "Sources/HaloMux"
        ),
        .executableTarget(
            name: "halod",
            dependencies: ["HaloMux"],
            path: "Sources/halod"
        ),
        .executableTarget(
            name: "halo-attach",
            dependencies: ["HaloMux"],
            path: "Sources/halo-attach"
        ),
    ]
)
