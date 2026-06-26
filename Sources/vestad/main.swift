import Foundation
import VestaMux

// Version probe for `vesta attach ssh://…` deploy decision. Must run without
// touching the socket so a remote one-shot `vestad --proto-version` is cheap.
if CommandLine.arguments.dropFirst().first == "--proto-version" {
    print("vestad-proto \(muxProtocolVersion)")
    exit(0)
}

let daemon = Daemon()
daemon.run()
