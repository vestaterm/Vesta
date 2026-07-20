import Foundation
import VestaMux
#if canImport(Darwin)
import Darwin
#endif

/// GUI-owned read-only subscribers feeding the `pane-output` Lua event. Terminal bytes
/// flow daemon → vesta-attach → libghostty below the GUI, so this opens a *passive*
/// connection to the daemon per live pane (the daemon fans output to all readers) purely
/// to surface output to plugins.
///
/// - Subscribes to EVERY live pane (not just the focused one) so plugins can watch
///   background panes; the paneID travels in each dispatch so handlers can distinguish.
/// - Opened only while a `pane-output` handler is registered (costs nothing otherwise).
/// - Reads off-main; coalesces a burst into one main-thread delivery per run-loop tick;
///   caps a delivery to avoid flooding Lua under a log spew (best-effort — may coalesce/drop).
/// - No-op when `vesta-persist` is off (no daemon → no bytes to tap).
///
/// @unchecked Sendable: all mutable state is confined to `q` or guarded by `lock`.
final class PaneOutputTap: @unchecked Sendable {
    @MainActor static let shared = PaneOutputTap()

    private let q = DispatchQueue(label: "vesta.paneoutput")
    private let cap = 256 * 1024

    /// One passive subscriber connection to a pane's daemon session.
    private final class Tap {
        let fd: Int32
        var source: DispatchSourceRead?
        var inbuf = Data()
        init(fd: Int32) { self.fd = fd }
    }

    private var taps: [String: Tap] = [:]   // q-owned: paneID → connection

    // shared between q (producer) and main (consumer), under `lock`:
    private let lock = NSLock()
    private var pending: [String: Data] = [:]   // keyed by paneID, so bytes are never mislabeled
    private var deliveryScheduled = false

    /// Reconcile the open taps against the set of live pane IDs. Call on the main thread.
    /// Self-gates: closes everything unless a `pane-output` handler exists and persist is on.
    @MainActor func reconcile(_ paneIDs: Set<String>) {
        // Sidebar tails need the same passive byte feed as the Lua event, so the taps
        // stay open whenever either consumer wants them (and persist is on).
        // ponytail: that's one fd + dispatch source per live pane, always (fd limit was
        // raised in a04aee7). Subscribe-on-expand if pane counts ever make this hurt.
        let enabled = (luaHasPaneOutputHandler() || VestaConfig.shared.sidebarTails)
            && VestaConfig.shared.persist
        let want = enabled ? paneIDs : []
        q.async { [weak self] in self?._reconcile(want) }
    }

    @MainActor func stop() { q.async { [weak self] in self?._reconcile([]) } }

    // MARK: - q-confined

    private func _reconcile(_ want: Set<String>) {
        for (pid, tap) in taps where !want.contains(pid) {   // close panes that went away
            tap.source?.cancel(); taps[pid] = nil; clearPending(pid)
            forgetTail(pid)
        }
        for pid in want where taps[pid] == nil {             // open newly-live panes
            guard let fd = Self.connectSubscribe(pid) else { continue }
            let tap = Tap(fd: fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
            src.setEventHandler { [weak self] in self?.onReadable(pid) }
            src.setCancelHandler { close(fd) }
            tap.source = src; taps[pid] = tap
            src.resume()
        }
    }

    private func drop(_ pid: String) {
        taps[pid]?.source?.cancel(); taps[pid] = nil; clearPending(pid)
        forgetTail(pid)
    }

    /// Dead pane → drop its tail lines (TailStore is main-actor; we're on q).
    private func forgetTail(_ pid: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { TailStore.shared.forget(pid) } }
    }

    private func onReadable(_ pid: String) {
        guard let tap = taps[pid] else { return }
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = read(tap.fd, &tmp, tmp.count)
        if n <= 0 {
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            drop(pid); return   // EOF / error: daemon closed us (e.g. session exited)
        }
        tap.inbuf.append(Data(tmp[0..<n]))
        while let frame = decodeServerFrame(from: &tap.inbuf) {
            switch frame {
            case let .output(d):
                coalesce(d, paneID: pid)
            case let .helloAck(v):
                if v != muxProtocolVersion { drop(pid); return }   // version mismatch → bail
            case .exited:
                // Belt-and-suspenders: the daemon doesn't send subscribers `.exited`
                // (only attached clients); we normally learn of death via EOF above.
                drop(pid); return
            case .sessions:
                break
            }
        }
    }

    /// Accumulate output per pane and schedule (at most) one main-thread delivery per burst.
    private func coalesce(_ bytes: Data, paneID: String) {
        lock.lock()
        pending[paneID, default: Data()].append(bytes)
        if let n = pending[paneID]?.count, n > cap { pending[paneID]!.removeFirst(n - cap) }  // drop oldest
        let schedule = !deliveryScheduled
        if schedule { deliveryScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver() } }
        }
    }

    private func clearPending(_ pid: String) { lock.lock(); pending[pid] = nil; lock.unlock() }

    @MainActor private func deliver() {
        lock.lock(); let batch = pending; pending.removeAll(); deliveryScheduled = false; lock.unlock()
        for (pid, data) in batch where !data.isEmpty {
            if VestaConfig.shared.sidebarTails { TailStore.shared.ingest(paneID: pid, chunk: data) }
            luaFirePaneOutput(paneID: pid, chunk: data)
        }
    }

    /// Connect to the daemon and send a subscribe frame for `paneID`. The fd is
    /// non-blocking so the DispatchSource read loop never stalls.
    private static func connectSubscribe(_ paneID: String) -> Int32? {
        guard let fd = MuxClient.connect() else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        MuxClient.send(fd, .subscribe(paneID: paneID))
        return fd
    }
}
