// Undo and redo for decisions. Each entry is one key press, which may touch several photos
// (for example "keep this frame, reject the rest" in compare view).

public struct Change: Equatable, Sendable {
    public let label: String
    public let before: [Decision]
    public let after: [Decision]

    public init(label: String, before: [Decision], after: [Decision]) {
        self.label = label
        self.before = before
        self.after = after
    }

    public var reversed: Change { Change(label: label, before: after, after: before) }
}

public struct History: Sendable {
    public private(set) var undoStack: [Change] = []
    public private(set) var redoStack: [Change] = []
    public let limit: Int

    public init(limit: Int = 1000) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ change: Change) {
        undoStack.append(change)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// Returns the change to apply to undo the last action (already reversed).
    public mutating func undo() -> Change? {
        guard let change = undoStack.popLast() else { return nil }
        redoStack.append(change)
        return change.reversed
    }

    public mutating func redo() -> Change? {
        guard let change = redoStack.popLast() else { return nil }
        undoStack.append(change)
        return change
    }

    /// Drops the last recorded change without making it redoable, e.g. when it failed to apply.
    public mutating func discardLast() {
        _ = undoStack.popLast()
    }

    /// Forget everything, e.g. after a delete that can't be undone in Winnow.
    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
