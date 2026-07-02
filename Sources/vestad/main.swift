import Foundation
import VestaMux

// A write to a vanished client fd must surface as EPIPE, not kill the daemon.
signal(SIGPIPE, SIG_IGN)

// Version probe for `vesta attach ssh://…` deploy decision. Must run without
// touching the socket so a remote one-shot `vestad --proto-version` is cheap.
if CommandLine.arguments.dropFirst().first == "--proto-version" {
    print("vestad-proto \(muxProtocolVersion)")
    exit(0)
}

// Raise the soft fd limit before we open anything: with dozens of persisted sessions the
// daemon (and every shell it forks, which inherit this limit) blew past the default 256.
raiseFDLimit()

let daemon = Daemon()
daemon.run()
