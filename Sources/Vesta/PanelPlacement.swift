import AppKit

/// Persisted placement for a panel, keyed by its title. A panel is anchored to its
/// nearest corner and offset inward from there (dx from the near horizontal edge, dy from
/// the near vertical edge), so it stays glued to that corner when the window resizes
/// instead of drifting. Also remembers edge-minimized state.
struct PanelPlacement: Codable {
    var corner: String = "topright"
    var dx: Double = 16     // inward offset from the corner's horizontal edge
    var dy: Double = 44     // inward offset from the corner's vertical edge
    var minimized: Bool = false
    var edge: String = "right"
    var z: Int = 0
}

/// Tiny UserDefaults-backed store of panel placements (title → placement).
enum PanelStore {
    private static let key = "VestaPanelPlacements"

    static func all() -> [String: PanelPlacement] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: PanelPlacement].self, from: d) else { return [:] }
        return m
    }
    static func get(_ title: String) -> PanelPlacement? { all()[title.isEmpty ? "·" : title] }
    static func set(_ title: String, _ p: PanelPlacement) {
        var m = all(); m[title.isEmpty ? "·" : title] = p
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Monotonic stacking counter, seeded from the highest persisted z. Main-thread only.
    nonisolated(unsafe) private static var z = all().values.map(\.z).max() ?? 0
    static func nextZ() -> Int { z += 1; return z }
}
