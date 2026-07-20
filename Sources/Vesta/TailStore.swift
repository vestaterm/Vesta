import Foundation

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

    func ingest(paneID: String, chunk: Data) {
        guard let s = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1),
              !s.isEmpty else { return }
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
    print("tailStoreSelfCheck OK")
}
