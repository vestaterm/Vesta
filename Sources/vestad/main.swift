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
// `--resume <state> --lockfd <n>`: we were execv'd by a previous vestad performing a
// zero-downtime in-place upgrade. Adopt the inherited pty masters + lock fd and the session
// snapshot instead of a fresh start. NOTE: SIGPIPE disposition and the fd limit are already
// re-established above (execv resets signal handlers, so re-running main from the top matters).
let cmdArgs = CommandLine.arguments
if let ri = cmdArgs.firstIndex(of: "--resume"), ri + 1 < cmdArgs.count {
    var lockFD: Int32 = -1
    if let li = cmdArgs.firstIndex(of: "--lockfd"), li + 1 < cmdArgs.count, let n = Int32(cmdArgs[li + 1]) {
        lockFD = n
    }
    daemon.resume(statePath: cmdArgs[ri + 1], lockFD: lockFD)
} else {
    daemon.run()
}
