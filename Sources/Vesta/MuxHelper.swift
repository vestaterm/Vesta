import Foundation

/// Absolute path to the `vesta-attach` relay binary that sits beside the running
/// executable — works both in Vesta.app/Contents/MacOS and in .build/debug.
func muxHelperPath() -> String {
    Bundle.main.executableURL!.deletingLastPathComponent()
        .appendingPathComponent("vesta-attach").path
}
