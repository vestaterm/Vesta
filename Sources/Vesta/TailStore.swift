import Foundation
import VestaMux

/// Last few cleaned scrollback lines per pane — the session cards' "output tail".
/// Fed by PaneOutputTap (same passive daemon subscription that powers `pane-output`),
/// consumed by WindowContext.renderSidebar via SidebarSession.tail.
@MainActor
final class TailStore {
    static let shared = TailStore()
    static let maxLines = 4

    /// Debounced change signal (≤1 fire/sec) — AppDelegate points this at sidebar refresh.
    var onChange: (() -> Void)?

    private var tails: [String: [String]] = [:]      // paneID → last lines, newest last
    private var partial: [String: String] = [:]      // trailing unterminated line (the prompt)
    private var lastActivity: [String: Date] = [:]
    private var lastExit: [String: (code: Int, at: Date)] = [:]  // OSC 133;D per pane (card heat)
    private var cmdStart: [String: Date] = [:]                    // OSC 133;C per pane

    /// Fired on each command completion (paneID, exit code, duration since its 133;C).
    /// AppDelegate uses this for background-attention — the old pid heuristic can't see
    /// through the persist relay (ghostty's pty only ever runs vesta-attach).
    var onCommandDone: ((String, Int, TimeInterval) -> Void)?
    private var notifyScheduled = false

    /// Cleaned tail for a pane: complete lines plus the current partial (prompt) line.
    /// The partial is stored RAW and cleaned here — cleaning it at ingest would mangle
    /// escape sequences split across chunk boundaries (a chunk ending mid-`ESC[32m`
    /// leaks a literal "2m" into the next line).
    func lines(_ paneID: String) -> [String] {
        var out = tails[paneID] ?? []
        if let p = partial[paneID] {
            let clean = Self.cleanLine(p)
            if !clean.isEmpty { out.append(clean) }
        }
        return out.suffix(Self.maxLines)
    }

    func activity(_ paneID: String) -> Date? { lastActivity[paneID] }

    /// Last command's exit (code + when), from shell-integration OSC 133;D markers.
    /// nil when the shell doesn't emit them, or after markSeen.
    func exitState(_ paneID: String) -> (code: Int, at: Date)? { lastExit[paneID] }

    /// The user looked at the session — its ✓/✗ heat is old news now.
    func markSeen(_ paneIDs: [String]) { paneIDs.forEach { lastExit[$0] = nil } }

    /// `ESC ] 133 ; C` anywhere in a chunk — a command just started (shell integration).
    nonisolated static func hasStartMarker(_ s: String) -> Bool {
        s.range(of: "\u{1B}]133;C") != nil
    }

    func ingest(paneID: String, chunk: Data) {
        guard let s = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1),
              !s.isEmpty else { return }
        // Exit-status heat: scan ONLY the fresh chunk (not the carried partial — a marker
        // parked in the partial would re-record every ingest and pin its age at "now").
        // ponytail: a marker split across chunks is missed; fine, the next command re-emits.
        if Self.hasStartMarker(s) { cmdStart[paneID] = Date() }
        if let code = Self.lastExitMarker(s) {
            lastExit[paneID] = (code, Date())
            let dur = cmdStart[paneID].map { Date().timeIntervalSince($0) } ?? 0
            cmdStart[paneID] = nil
            onCommandDone?(paneID, code, dur)
        }
        let text = (partial[paneID] ?? "") + s
        var lines = tails[paneID] ?? []
        var rest = Substring(text)
        while let nl = rest.firstIndex(of: "\n") {
            let clean = Self.cleanLine(String(rest[..<nl]))
            if !clean.isEmpty { lines.append(clean) }
            rest = rest[rest.index(after: nl)...]
        }
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        tails[paneID] = lines
        // Keep the unterminated remainder (usually the prompt) RAW — see lines(). Bounded:
        // a >1KB no-newline line can cut mid-escape at the FRONT, but the dominant case is a
        // \r progress bar, whose CR handling wipes anything before the last \r anyway.
        partial[paneID] = String(rest.suffix(1024))
        lastActivity[paneID] = Date()
        scheduleNotify()
    }

    func forget(_ paneID: String) {
        tails[paneID] = nil; partial[paneID] = nil; lastActivity[paneID] = nil
        lastExit[paneID] = nil; cmdStart[paneID] = nil
    }

    /// Last `ESC ] 133 ; D [; code] (BEL | ESC \)` in a chunk → exit code (no code ⇒ 0).
    /// Emitted by ghostty/iTerm2-style shell integration when a command finishes.
    nonisolated static func lastExitMarker(_ s: String) -> Int? {
        var result: Int? = nil
        var rest = Substring(s)
        while let r = rest.range(of: "\u{1B}]133;D") {
            var tail = rest[r.upperBound...]
            var digits = ""
            if tail.first == ";" {
                tail.removeFirst()
                while let c = tail.first, c.isNumber { digits.append(c); tail.removeFirst() }
            }
            if tail.first == "\u{07}" || tail.hasPrefix("\u{1B}\\") {
                result = Int(digits) ?? 0
            }
            rest = rest[r.upperBound...]
        }
        return result
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.onChange?()
        }
    }

    /// Strip ANSI escapes + control chars; resolve carriage returns (progress bars
    /// redraw in place — keep the final segment).
    nonisolated static func cleanLine(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = raw.unicodeScalars[...]
        while let c = scalars.first {
            scalars.removeFirst()
            switch c {
            case "\u{1B}":   // ESC
                guard let k = scalars.first else { break }
                if k == "[" {                     // CSI: ESC [ params final-byte
                    scalars.removeFirst()
                    while let p = scalars.first, !(0x40...0x7E).contains(p.value) { scalars.removeFirst() }
                    if !scalars.isEmpty { scalars.removeFirst() }
                } else if k == "]" {              // OSC: ESC ] ... (BEL | ESC \)
                    scalars.removeFirst()
                    while let p = scalars.first, p != "\u{07}", p != "\u{1B}" { scalars.removeFirst() }
                    if scalars.first == "\u{1B}" { scalars.removeFirst() }   // the ST's ESC
                    if !scalars.isEmpty { scalars.removeFirst() }            // BEL or backslash
                } else {                          // 2-char escape (charset, keypad, …)
                    scalars.removeFirst()
                }
            case "\r":
                out.removeAll(keepingCapacity: true)   // in-place redraw: keep what follows
            case let c where c.value < 0x20 && c != "\t":
                break                                   // other C0 controls: drop
            default:
                out.append(c)
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }
}

/// Pure-logic check for the line cleaner + split-chunk handling (run by `vesta selfcheck`).
@MainActor
func tailStoreSelfCheck() {
    assert(TailStore.cleanLine("\u{1B}[32m✓ built\u{1B}[0m in 240ms") == "✓ built in 240ms", "SGR stripped")
    assert(TailStore.cleanLine("\u{1B}]0;title\u{07}hello") == "hello", "OSC stripped")
    assert(TailStore.cleanLine("Progress 10%\rProgress 99%") == "Progress 99%", "CR keeps last segment")
    assert(TailStore.cleanLine("  \u{1B}[2K  ") == "", "blank after clean is empty")
    // Escape sequence split across two chunks must not leak fragments ("2m").
    let ts = TailStore()
    ts.ingest(paneID: "t", chunk: Data("ok \u{1B}[3".utf8))
    ts.ingest(paneID: "t", chunk: Data("2mgreen\u{1B}[0m\n❯ ".utf8))
    assert(ts.lines("t") == ["ok green", "❯"], "split SGR survives chunk boundary: \(ts.lines("t"))")
    ts.forget("t")
    assert(ts.lines("t").isEmpty, "forget clears")
    // OSC 133;D exit markers (shell integration) → heat state.
    assert(TailStore.lastExitMarker("out\u{1B}]133;D;1\u{07}❯ ") == 1, "failure code parsed")
    assert(TailStore.lastExitMarker("\u{1B}]133;D\u{1B}\\") == 0, "bare D means success")
    assert(TailStore.lastExitMarker("\u{1B}]133;D;0\u{07}x\u{1B}]133;D;2\u{07}") == 2, "last marker wins")
    assert(TailStore.lastExitMarker("plain text") == nil, "no marker, no heat")
    assert(TailStore.lastExitMarker("\u{1B}]133;D;1") == nil, "unterminated marker ignored")
    assert(TailStore.hasStartMarker("run: \u{1B}]133;C\u{07}x"), "start marker seen")
    assert(!TailStore.hasStartMarker("plain"), "no false start")
    // onCommandDone: C then D in separate chunks fires with a real duration; C+D in ONE
    // chunk yields dur≈0 (no ring); forget clears pending starts.
    var fired: [(String, Int, TimeInterval)] = []
    ts.onCommandDone = { fired.append(($0, $1, $2)) }
    ts.ingest(paneID: "c", chunk: Data("\u{1B}]133;C\u{07}building…\n".utf8))
    ts.ingest(paneID: "c", chunk: Data("done\u{1B}]133;D;0\u{07}".utf8))
    assert(fired.count == 1 && fired[0].0 == "c" && fired[0].1 == 0 && fired[0].2 >= 0, "C→D fires")
    ts.ingest(paneID: "c", chunk: Data("\u{1B}]133;C\u{07}x\u{1B}]133;D;2\u{07}".utf8))
    assert(fired.count == 2 && fired[1].1 == 2 && fired[1].2 < 1, "same-chunk C+D ≈ zero duration")
    ts.ingest(paneID: "c", chunk: Data("\u{1B}]133;C\u{07}".utf8))
    ts.forget("c")
    ts.ingest(paneID: "c", chunk: Data("\u{1B}]133;D;0\u{07}".utf8))
    assert(fired.count == 3 && fired[2].2 == 0, "forget cleared the pending start (dur 0)")
    // End-to-end: the EXACT bytes our generated zsh integration emits must parse. Uses the
    // shared source of truth (VestaShellIntegration.doneMark) so the script's mark and this
    // parser can't silently drift apart.
    assert(TailStore.lastExitMarker(VestaShellIntegration.doneMark(0)) == 0, "script success mark parses")
    assert(TailStore.lastExitMarker("build\r\n" + VestaShellIntegration.doneMark(127) + "❯ ") == 127,
           "script failure mark parses in a realistic prompt tail")
    print("tailStoreSelfCheck OK")
}
