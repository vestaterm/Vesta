import Foundation
import HaloMux

// Remote helper layout on the host (created by deploy). scp lands both binaries
// in ~/.local/bin and we chmod 700 them. The remote socket path is NOT specified
// here: the remote halod and remote halo-attach both compute it via the same
// MuxPaths math on the host, so they agree without us hardcoding anything.
private let remoteBinDir = ".local/bin"
private let remoteHalod = ".local/bin/halod"
private let remoteAttach = ".local/bin/halo-attach"

/// `halo attach ssh://[user@]host[:port] [session]`
/// Parses the URL, self-deploys the helper if missing/skewed, then streams the
/// SAME wire frames over the ssh pty. No raw TCP (out of scope).
func runRemoteAttach(_ args: [String]) -> Int32 {
    guard let url = args.first else {
        FileHandle.standardError.write(Data("halo attach: usage: halo attach ssh://host[:port] [session]\n".utf8))
        return 1
    }
    let session = args.count > 1 ? args[1] : nil
    guard let target = parseRemoteURL(url, session: session) else {
        FileHandle.standardError.write(Data("halo attach: bad ssh url: \(url)\n".utf8))
        return 1
    }

    // ssh destination args reused for every hop.
    let dest = target.user.map { "\($0)@\(target.host)" } ?? target.host
    let sshBase = ["-p", String(target.port),
                   "-o", "BatchMode=no",            // allow password/2FA prompts
                   "-o", "ConnectTimeout=10"]

    // 1) Probe the remote helper's protocol version.
    let probeOut = runCapturing("/usr/bin/ssh",
        sshBase + [dest, "halod --proto-version 2>/dev/null || true"])
    let probe = parseProbeOutput(probeOut)

    // 2) Deploy if missing or version-skewed.
    if shouldDeploy(probe) {
        FileHandle.standardError.write(Data("halo attach: deploying helper to \(dest)…\n".utf8))
        guard deployHelpers(dest: dest, sshBase: sshBase) == 0 else {
            FileHandle.standardError.write(Data("halo attach: deploy failed\n".utf8))
            return 1
        }
    }

    // 3) Stream. The remote halo-attach lazy-spawns the remote halod itself (M3),
    //    connects to the daemon socket it computes via MuxPaths, and pumps the SAME
    //    frames. `ssh -tt` gives a pty bridge so stdin/stdout are byte-transparent.
    //    An empty paneID is invalid, so a bare `halo attach ssh://host` defaults to
    //    "default"; a named session becomes the remote daemon's paneID key.
    let remotePaneID = target.session ?? "default"
    let relay = "exec \(remoteAttach) \(remotePaneID)"
    let code = execForeground("/usr/bin/ssh",
        sshBase + ["-tt", dest, relay])
    return code
}

/// scp the local halod + halo-attach (beside the running binary) to the remote
/// ~/.local/bin, then chmod 700. Returns 0 on success.
private func deployHelpers(dest: String, sshBase: [String]) -> Int32 {
    let here = Bundle.main.executableURL!.deletingLastPathComponent()
    let localHalod = here.appendingPathComponent("halod").path
    let localAttach = here.appendingPathComponent("halo-attach").path

    // scp uses -P (capital) for port; pull it out of sshBase.
    let portIdx = sshBase.firstIndex(of: "-p")
    let port = portIdx.map { sshBase[sshBase.index(after: $0)] } ?? "22"

    // Ensure the remote bin dir exists. The remote halod creates its own XDG dirs
    // via MuxPaths.ensureDirs() when it starts, so we only need the bin dir here.
    if execForeground("/usr/bin/ssh",
        sshBase + [dest, "mkdir -p \(remoteBinDir)"]) != 0 {
        return 1
    }
    for local in [localHalod, localAttach] {
        let name = (local as NSString).lastPathComponent
        if execForeground("/usr/bin/scp",
            ["-P", port, local, "\(dest):\(remoteBinDir)/\(name)"]) != 0 {
            return 1
        }
    }
    return execForeground("/usr/bin/ssh",
        sshBase + [dest, "chmod 700 \(remoteHalod) \(remoteAttach)"])
}

/// Run a process, capture stdout as a String (used for the version probe).
private func runCapturing(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Run a process with inherited stdio (interactive ssh/scp), return exit code.
private func execForeground(_ launchPath: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    do { try p.run() } catch {
        FileHandle.standardError.write(Data("halo attach: cannot exec \(launchPath): \(error)\n".utf8))
        return 1
    }
    p.waitUntilExit()
    return p.terminationStatus
}
