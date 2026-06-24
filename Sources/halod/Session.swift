import Foundation
import HaloMux
import CVterm
#if canImport(Darwin)
import Darwin
#endif

/// One live shell: PTY master + libvterm authoritative screen + scrollback ring
/// (disk-spilled) + image cache. Drained by the daemon even when no client is attached.
final class Session {
    let paneID: String
    let masterFD: Int32
    let pid: pid_t
    var cols: Int32
    var rows: Int32
    private let vt: OpaquePointer
    private let screen: OpaquePointer
    // libvterm stores the *pointer* to the callbacks struct (screen.c:49), not a copy,
    // so it must outlive `installScreenCallbacks`. We own it here for the session's life.
    private let callbacks = UnsafeMutablePointer<VTermScreenCallbacks>.allocate(capacity: 1)
    let ring: ScrollbackRing
    let images = ImageCache()
    var attached: [Int32] = []     // attached client fds (mirroring)
    private(set) var alive = true
    var cwd: String?
    var name: String?

    init?(paneID: String, cols: Int32, rows: Int32) {
        self.paneID = paneID; self.cols = cols; self.rows = rows
        // forkpty a login shell.
        var master: Int32 = 0
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &ws)
        if child < 0 { return nil }
        if child == 0 {
            let shell = getenv("SHELL").flatMap { String(cString: $0) } ?? "/bin/zsh"
            // execl is variadic (unavailable to Swift); build an explicit argv for execv.
            // Login shell: argv[0] = shell, argv[1] = "-l".
            shell.withCString { shellC in
                "-l".withCString { dashL in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        strdup(shellC), strdup(dashL), nil,
                    ]
                    _ = execv(shellC, &argv)
                }
            }
            _exit(127)
        }
        self.pid = child; self.masterFD = master
        // libvterm: authoritative screen, UTF-8, scrollback callback drains evicted rows.
        guard let vt = vterm_new(Int32(rows), Int32(cols)) else {
            kill(child, SIGKILL); _ = waitpid(child, nil, 0); close(master); return nil
        }
        self.vt = vt
        vterm_set_utf8(vt, 1)
        guard let screen = vterm_obtain_screen(vt) else {
            vterm_free(vt); kill(child, SIGKILL); _ = waitpid(child, nil, 0); close(master); return nil
        }
        self.screen = screen
        vterm_screen_reset(screen, 1)
        // Disk-spill ring: evicted lines append to the session log (history recovery).
        let logPath = MuxPaths.sessionLog(paneID)
        self.ring = ScrollbackRing(cap: 10_000) { line in
            if let fh = FileHandle(forWritingAtPath: logPath) ?? {
                FileManager.default.createFile(atPath: logPath, contents: nil)
                return FileHandle(forWritingAtPath: logPath)
            }() {
                fh.seekToEndOfFile(); fh.write(line); fh.write(Data([0x0a])); try? fh.close()
            }
        }
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL, 0) | O_NONBLOCK)
    }

    /// Feed raw PTY output into libvterm (updates the authoritative screen). Rows
    /// that scroll off the top are captured into the ring via the `sb_pushline`
    /// callback the daemon installs (see `Daemon.installScrollback`).
    func ingest(_ bytes: Data) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = vterm_input_write(vt, base.assumingMemoryBound(to: CChar.self), raw.count)
        }
    }

    /// Render the current libvterm screen to a UTF-8 byte stream (clean redraw on attach).
    func screenSnapshot() -> Data {
        var out = Data()
        for row in 0..<rows {
            for col in 0..<cols {
                var cell = VTermScreenCell()
                let pos = VTermPos(row: Int32(row), col: Int32(col))
                vterm_screen_get_cell(screen, pos, &cell)
                // Wide glyph (CJK/emoji): a width-2 cell followed by a width-0 continuation
                // cell. Emit nothing for the continuation — the preceding glyph already spans
                // both columns (ghostty re-renders it 2 wide); emitting a space would drift cols.
                if cell.width == 0 { continue }
                if cell.chars.0 == 0 { out.append(0x20) }
                else if let u = Unicode.Scalar(cell.chars.0) {
                    out.append(contentsOf: Array(String(u).utf8))
                } else { out.append(0x20) }
            }
            out.append(0x0a)
        }
        return out
    }

    func resize(cols: Int32, rows: Int32) {
        self.cols = cols; self.rows = rows
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        vterm_set_size(vt, Int32(rows), Int32(cols))
    }

    func writeInput(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(masterFD, base.advanced(by: off), raw.count - off)
                if n <= 0 { break }; off += n
            }
        }
    }

    func markDead() { alive = false }

    deinit {
        vterm_free(vt)
        callbacks.deallocate()
        close(masterFD)
    }
}

extension Session {
    /// A stable raw-pointer identity for this session, used as the `user` arg of
    /// libvterm screen callbacks (we can't pass Swift closures to C). Derived from
    /// the object's address so it's unique and stable for the session's lifetime.
    var screenKey: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    func installScreenCallbacks(_ cbs: VTermScreenCallbacks, user: UnsafeMutableRawPointer) {
        // Persist the struct in our owned storage; vterm keeps the pointer.
        callbacks.pointee = cbs
        vterm_screen_set_callbacks(screen, callbacks, user)
        vterm_screen_enable_altscreen(screen, 1)
    }
}
