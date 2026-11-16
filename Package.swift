// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vesta",
    platforms: [.macOS(.v13)],
    targets: [
        // Real libghostty (built from ghostty source, zig 0.15.2) as a macOS xcframework.
        // Prebuilt + published as a GitHub release asset, fetched + checksum-verified by
        // SwiftPM — no local framework checkout, no external host. To republish: regenerate
        // the macOS-only xcframework, zip it, `gh release upload ghostkit-N`, bump url+checksum.
        .binaryTarget(
            name: "GhosttyKit",
            url: "https://github.com/vestaterm/Vesta/releases/download/ghostkit-2/GhosttyKit.xcframework.zip",
            checksum: "81ca71da99e05772cfe54e3f8009faaffd710a4fcdabdae0df14da1fca683c90"
        ),
        // Vendored Lua 5.4.7 (embedded scripting runtime; see Sources/CLua/PROVENANCE.txt).
        .target(
            name: "CLua",
            path: "Sources/CLua",
            cSettings: [.define("LUA_USE_MACOSX")]   // POSIX + dlopen-based require on macOS
        ),
        .executableTarget(
            name: "vesta",
            dependencies: ["GhosttyKit", "VestaMux", "CLua"],
            path: "Sources/Vesta",
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
            name: "VestaMux",
            path: "Sources/VestaMux"
        ),
        .executableTarget(
            name: "vestad",
            dependencies: ["VestaMux"],
            path: "Sources/vestad"
        ),
        .executableTarget(
            name: "vesta-attach",
            dependencies: ["VestaMux"],
            path: "Sources/vesta-attach"
        ),
        // Pure-logic tests only (mux protocol). App-target logic (windows.json format,
        // ghostty config parsing) is covered by `vesta selfcheck` instead — a test target
        // depending on the vesta executable would have to link GhosttyKit + AppKit.
        .testTarget(
            name: "VestaTests",
            dependencies: ["VestaMux"],
            path: "Tests/VestaTests"
        ),
    ]
)
