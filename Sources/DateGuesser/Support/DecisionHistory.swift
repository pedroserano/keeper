/// ⌘Z and ⇧⌘Z for choices made on the Dates screens before they're applied (selecting, hiding,
/// changing a guess). Each step holds the earlier decisions of just the photos one action changed.
/// Applying to Photos is undone from History instead.
struct DecisionHistory<D> {
    private var undos: [[String: D?]] = []
    private var redos: [[String: D?]] = []
    static var limit: Int { 200 }

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }

    /// Call just before changing `ids` in `decisions`.
    mutating func record(_ ids: some Sequence<String>, from decisions: [String: D]) {
        var before: [String: D?] = [:]
        for id in ids { before.updateValue(decisions[id], forKey: id) }
        guard !before.isEmpty else { return }
        undos.append(before)
        if undos.count > Self.limit { undos.removeFirst() }
        redos.removeAll()
    }

    /// Puts back the decisions from before the last change. False if there's nothing to undo.
    mutating func undo(_ decisions: inout [String: D]) -> Bool { Self.step(&undos, &redos, &decisions) }

    mutating func redo(_ decisions: inout [String: D]) -> Bool { Self.step(&redos, &undos, &decisions) }

    private static func step(_ from: inout [[String: D?]], _ to: inout [[String: D?]], _ decisions: inout [String: D]) -> Bool {
        guard let entry = from.popLast() else { return false }
        var back: [String: D?] = [:]
        var copy = decisions
        for (id, old) in entry {
            back.updateValue(copy[id], forKey: id)
            copy[id] = old
        }
        decisions = copy
        to.append(back)
        return true
    }
}
