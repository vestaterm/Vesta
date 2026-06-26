import Foundation
import HaloMux
#if canImport(Darwin)
import Darwin
#endif

/// GUI-owned read-only subscriber to the focused pane's daemon output, feeding the
/// `pane-output` Lua event. The terminal bytes flow daemon → halo-attach → libghostty
/// entirely below the GUI, so this opens a *second*, passive connection to the daemon
/// (the daemon fans output to all readers) purely to surface output to plugins.
///
/// - Opened only while a `pane-output` handler is registered (costs nothing otherwise).
/// - Follows the focused pane (retargeted on focus/window change).
/// - Reads off-main; coalesces a burst into one main-thread delivery; caps a delivery
///   to avoid flooding Lua under a log spew (best-effort — may coalesce/drop).
/// - No-op when `halo-persist` is off (no daemon → no bytes to tap).
///
/// @unchecked Sendable: all mutable state is confined to `q` or guarded by `lock`.
final class PaneOutputTap: @unchecked Sendable {
    @MainActor static let shared = PaneOutputTap()

    private let q = DispatchQueue(label: "halo.paneoutput")
    private let cap = 256 * 1024

    // q-owned:
    private var fd: Int32 = -1
    private var paneID: String?
    private var source: DispatchSourceRead?
    private var inbuf = Data()

    // shared between q (producer) and main (consumer), under `lock`:
    private let lock = NSLock()
    private var pending = Data()
    private var deliveryScheduled = false

    /// Point the tap at the focused pane (or nil/none to stop). Call on the main thread.
    /// Self-gates: a no-op unless a `pane-output` handler exists and persist is on.
    @MainActor func retarget(_ paneID: String?) {
        let enabled = luaHasPaneOutputHandler() && HaloConfig.shared.persist
        let target = enabled ? paneID : nil
        q.async { [weak self] in self?._retarget(target) }
    }

    @MainActor func stop() { q.async { [weak self] in self?._retarget(nil) } }

    // MARK: - q-confined

    private func _retarget(_ target: String?) {
        if target == paneID && fd >= 0 { return }   // already tapping it
        _teardown()
        guard let target, let f = Self.connectSubscribe(target) else { return }
        fd = f; paneID = target
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: q)
        src.setEventHandler { [weak self] in self?.onReadable() }
        src.setCancelHandler { close(f) }
        source = src
        src.resume()
    }

    private func _teardown() {
        source?.cancel(); source = nil   // cancel handler closes the fd
        fd = -1; paneID = nil; inbuf.removeAll()
        lock.lock(); pending.removeAll(); deliveryScheduled = false; lock.unlock()
    }

    private func onReadable() {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 {
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            _teardown(); return   // EOF / error: daemon closed us (e.g. session exited)
        }
        inbuf.append(Data(tmp[0..<n]))
        while let frame = decodeServerFrame(from: &inbuf) {
            switch frame {
            case let .output(d):
                if let pid = paneID { coalesce(d, paneID: pid) }
            case let .helloAck(v):
                if v != muxProtocolVersion { _teardown(); return }   // version mismatch → bail
            case .exited:
                _teardown(); return
            case .sessions:
                break
            }
        }
    }

    /// Accumulate output and schedule (at most) one main-thread delivery per burst.
    private func coalesce(_ bytes: Data, paneID: String) {
        lock.lock()
        pending.append(bytes)
        if pending.count > cap { pending.removeFirst(pending.count - cap) }   // drop oldest under flood
        let schedule = !deliveryScheduled
        if schedule { deliveryScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(paneID: paneID) } }
        }
    }

    @MainActor private func deliver(paneID: String) {
        lock.lock(); let data = pending; pending.removeAll(); deliveryScheduled = false; lock.unlock()
        guard !data.isEmpty else { return }
        luaFirePaneOutput(paneID: paneID, chunk: data)
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
