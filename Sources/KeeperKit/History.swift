// Undo and redo for decisions and rotations. Each entry is one key press, which may touch several
// photos (for example "keep this frame, reject the rest" in compare view).

import Foundation

public struct Change: Equatable, Sendable {
    public let label: String
    public let before: [Decision]
    public let after: [Decision]
    /// Photos to rotate (local identifier → degrees clockwise). A rotation is an edit in Photos,
    /// so undoing one rotates back the other way.
    public let rotations: [String: Int]
    /// Sideways Photos proposals hidden (true: rotated or dismissed) or shown again (false).
    public let sidewaysHidden: [String: Bool]

    public init(label: String, before: [Decision], after: [Decision], rotations: [String: Int] = [:],
                sidewaysHidden: [String: Bool] = [:]) {
        self.label = label
        self.before = before
        self.after = after
        self.rotations = rotations
        self.sidewaysHidden = sidewaysHidden
    }

    public var reversed: Change {
        Change(label: label, before: after, after: before, rotations: rotations.mapValues { -$0 },
               sidewaysHidden: sidewaysHidden.mapValues { !$0 })
    }
}

public struct History: Sendable {
    public private(set) var undoStack: [Change] = []
    public private(set) var redoStack: [Change] = []
    public let limit: Int

    public init(limit: Int = 1000) { self.limit = limit }

    /// When each change on the stacks was made, so ⌘Z on a screen with a second undo list (the
    /// Dates screens) can take back whichever came last.
    private var undoTimes: [Date] = []
    private var redoTimes: [Date] = []

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// When the change ⌘Z would take back was made.
    public var undoTime: Date? { undoTimes.last }
    /// When the change ⇧⌘Z would redo was made.
    public var redoTime: Date? { redoTimes.last }

    public mutating func record(_ change: Change, at time: Date = Date()) {
        undoStack.append(change)
        undoTimes.append(time)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
            undoTimes.removeFirst(undoTimes.count - limit)
        }
        redoStack.removeAll()
        redoTimes.removeAll()
    }

    /// Returns the change to apply to undo the last action (already reversed).
    public mutating func undo() -> Change? {
        guard let change = undoStack.popLast() else { return nil }
        redoStack.append(change)
        if let t = undoTimes.popLast() { redoTimes.append(t) }
        return change.reversed
    }

    public mutating func redo() -> Change? {
        guard let change = redoStack.popLast() else { return nil }
        undoStack.append(change)
        if let t = redoTimes.popLast() { undoTimes.append(t) }
        return change
    }

    /// Swaps a recorded change for what actually happened (nil drops it), e.g. when only some of a
    /// batch could be rotated. Finds it from the newest back, so later changes don't matter.
    public mutating func replace(_ old: Change, with new: Change?) {
        if let i = undoStack.lastIndex(of: old) {
            if let new { undoStack[i] = new } else { undoStack.remove(at: i); undoTimes.remove(at: i) }
        } else if let i = redoStack.lastIndex(of: old) {
            if let new { redoStack[i] = new } else { redoStack.remove(at: i); redoTimes.remove(at: i) }
        }
    }

    /// Drops the last recorded change without making it redoable, e.g. when it failed to apply.
    public mutating func discardLast() {
        _ = undoStack.popLast()
        _ = undoTimes.popLast()
    }

    /// Forget everything, e.g. after a delete that can't be undone in Keeper.
    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        undoTimes.removeAll()
        redoTimes.removeAll()
    }
}
