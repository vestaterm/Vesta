import Foundation

/// Fuzzy subsequence score. Returns nil when `needle` is not an in-order
/// (case-insensitive) subsequence of `haystack`; otherwise a score where
/// higher is better. Contiguous runs and an early first match score higher.
/// Pure logic — no AppKit, no I/O.
func fuzzyScore(_ needle: String, _ haystack: String) -> Int? {
    if needle.isEmpty { return 0 }
    let n = Array(needle.lowercased())
    let h = Array(haystack.lowercased())
    var ni = 0
    var score = 0
    var firstMatch = -1
    var prevMatch = -2   // so an initial run never counts as "contiguous"
    for (hi, c) in h.enumerated() {
        guard ni < n.count, c == n[ni] else { continue }
        if firstMatch < 0 { firstMatch = hi }
        if hi == prevMatch + 1 { score += 8 }   // contiguous with previous match
        else { score += 1 }                     // a match, but with a gap
        prevMatch = hi
        ni += 1
        if ni == n.count { break }
    }
    guard ni == n.count else { return nil }      // all needle chars consumed?
    // Reward matching near the start (anchored) and penalize trailing junk.
    score += max(0, 10 - firstMatch)             // earlier first match → bigger bonus
    score -= max(0, h.count - prevMatch - 1) / 4 // long tail after last match → mild penalty
    return score
}

/// Filter + rank `items` by fuzzy-matching `query` against `key(item)`.
/// Empty query → items unchanged. Non-empty → only matches, sorted by score
/// descending; ties preserve the original input order (stable).
func fuzzyFilter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return items }
    let scored = items.enumerated().compactMap { (i, item) -> (Int, Int, T)? in
        guard let s = fuzzyScore(q, key(item)) else { return nil }
        return (s, i, item)
    }
    // Sort by score desc, then original index asc (stable tie-break).
    return scored.sorted { a, b in a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }.map { $0.2 }
}

func fuzzySelfCheck() {
    // ── subsequence matching ────────────────────────────────────────────
    assert(fuzzyScore("", "anything") != nil, "empty needle always matches")
    assert(fuzzyScore("abc", "aXbXc") != nil, "in-order subsequence matches")
    assert(fuzzyScore("abc", "acb") == nil, "out-of-order is not a match")
    assert(fuzzyScore("xyz", "ab") == nil, "needle longer than haystack → no match")
    assert(fuzzyScore("HALO", "halo") != nil, "matching is case-insensitive")

    // ── score ordering: contiguous + start-anchored beat scattered ───────
    let contiguous = fuzzyScore("hal", "halo")!         // prefix, contiguous
    let scattered  = fuzzyScore("hal", "h-a-l-x")!      // gapped
    assert(contiguous > scattered, "contiguous prefix outscores scattered")

    let anchored = fuzzyScore("api", "api-server")!     // matches at index 0
    let mid      = fuzzyScore("api", "my-api")!         // matches mid-string
    assert(anchored > mid, "start-anchored outscores mid-string")

    // ── fuzzyFilter: empty query is identity, preserving order ───────────
    let all = ["alpha", "beta", "gamma"]
    assert(fuzzyFilter(all, query: "", key: { $0 }) == all, "empty query = identity")

    // ── fuzzyFilter: drops non-matches, ranks matches best-first ─────────
    let names = ["server", "api-server", "client", "svr"]
    let ranked = fuzzyFilter(names, query: "ser", key: { $0 })
    assert(!ranked.contains("client"), "non-matches are dropped")
    assert(!ranked.contains("svr"), "'ser' is not a subsequence of 'svr'")
    assert(ranked.first == "server", "best contiguous/anchored match ranks first")

    // ── stable ties: equal scores keep original input order ──────────────
    let tie = fuzzyFilter(["xa", "ya", "za"], query: "a", key: { $0 })
    assert(tie == ["xa", "ya", "za"], "equal-score matches keep input order")

    print("fuzzySelfCheck OK")
}
