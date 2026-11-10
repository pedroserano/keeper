// To Apply: every date and place change waiting to be written to Photos, from anywhere in Keeper.
// Nothing is written until Apply: the Undated Photos and Places screens keep their selections, and
// right-click Set Date… / Set Location… and History's fix queue theirs here.

import Foundation
import DateGuessCore

/// A date or place set from a right-click menu or History, waiting for Apply.
struct PendingChange: Codable, Hashable {
    /// The new date. With `keepsTime`, only its day counts: each photo keeps its own time of day
    /// (noon if it had no date).
    var date: Date?
    var keepsTime = true
    /// History's fix: the date the photo had when it was queued. Apply skips it if it changed again.
    var expected: Date?
    var place: PlaceChoice?

    var isEmpty: Bool { date == nil && place == nil }
}

extension AppState {
    /// One photo's change in To Apply, and where it was made.
    struct WaitingChange: Identifiable {
        enum Origin { case undated, places, elsewhere }
        var id: String
        var text: String
        var origin: Origin
    }

    /// Every date change waiting for Apply: Undated Photos' selection, then the queued ones.
    var waitingDates: [WaitingChange] {
        let queued = pending.filter { $0.value.date != nil }
        let fromReview = selectedForApply.filter { queued[$0] == nil }.compactMap { id in
            effectiveEstimate(id).map { WaitingChange(id: id, text: $0.displayString, origin: .undated) }
        }
        let rest = queued.sorted { $0.value.date! < $1.value.date! }.map { id, change in
            WaitingChange(id: id, text: change.keepsTime ? change.date!.formatted(date: .abbreviated, time: .omitted)
                                                         : change.date!.formatted(.dateTime.month(.wide).year()),
                          origin: .elsewhere)
        }
        return fromReview + rest
    }

    /// Every place change waiting for Apply: Places' selection, then the queued ones.
    var waitingPlaces: [WaitingChange] {
        let queued = pending.filter { $0.value.place != nil }
        let fromPlaces = places.checkedForApply.filter { queued[$0] == nil }.compactMap { id -> WaitingChange? in
            guard let point = places.effectivePoint(id) else { return nil }
            let name = places.decision(id).override?.name ?? PlaceNames.shared.name(for: point)
            return WaitingChange(id: id, text: name ?? Self.coordinates(point), origin: .places)
        }
        let rest = queued.sorted { $0.key < $1.key }.map { id, change in
            let place = change.place!
            return WaitingChange(id: id, text: place.name.isEmpty ? Self.coordinates(place.point) : place.name, origin: .elsewhere)
        }
        return fromPlaces + rest
    }

    nonisolated static func coordinates(_ p: GeoPoint) -> String {
        String(format: "%.3f, %.3f", p.lat, p.lon)
    }

    /// The sidebar count: changes waiting. A queued change deselects the photo on its screen, so
    /// nothing is counted twice; Places' count is kept as it changes.
    var waitingCount: Int {
        pending.values.reduce(0) { $0 + ($1.date == nil ? 0 : 1) + ($1.place == nil ? 0 : 1) }
            + selectedForApply.count + places.checkedCount
    }

    // MARK: Queueing

    /// The photos a right-click in Undated Photos acts on: every selected one if it's one of them.
    func reviewMenuIDs(_ id: String) -> [String] {
        guard decision(id).selected else { return [id] }
        return undatedSorted.map(\.id).filter { decisions[$0]?.selected == true }
    }

    /// The photos a right-click in Places acts on: every selected one if it's one of them.
    func placesMenuIDs(_ id: String) -> [String] {
        places.selectedIDs.contains(id) ? places.allSelected : [id]
    }

    /// Right-click › Set Date…: these photos get `day` when you apply, each keeping its time of day.
    func queueDate(_ ids: [String], day: Date) -> String {
        var copy = pending
        for id in ids {
            var change = copy[id] ?? PendingChange()
            change.date = day
            change.keepsTime = true
            change.expected = nil
            copy[id] = change
        }
        pending = copy
        deselectInLists(ids, dates: true)
        return "\(Self.photos(ids.count)) will get \(day.formatted(date: .abbreviated, time: .omitted)) when you apply them in To Apply."
    }

    /// Right-click › Set Location…: these photos get `place` when you apply, replacing any they have.
    func queuePlace(_ ids: [String], _ place: PlaceChoice) -> String {
        var copy = pending
        for id in ids {
            var change = copy[id] ?? PendingChange()
            change.place = place
            copy[id] = change
        }
        pending = copy
        deselectInLists(ids, dates: false)
        let name = place.name.isEmpty ? "this place" : place.name
        return "\(Self.photos(ids.count)) will get \(name) when you apply them in To Apply."
    }

    /// History's fix for dates changed in Photos: the 1st of `month` at noon, unless the photo's date
    /// changes again before Apply.
    func queueDate(_ shifts: [DateShift], year: Int, month: Int) -> String? {
        guard !shifts.isEmpty, let date = Self.appliedDate(year: year, month: month) else { return nil }
        var copy = pending
        for shift in shifts {
            var change = copy[shift.assetID] ?? PendingChange()
            change.date = date
            change.keepsTime = false
            change.expected = shift.current
            copy[shift.assetID] = change
        }
        pending = copy
        deselectInLists(shifts.map(\.assetID), dates: true)
        return "\(Self.photos(shifts.count)) will get \(date.formatted(.dateTime.month(.wide).year())) when you apply them in To Apply."
    }

    /// Takes photos out of To Apply: their queued change, or their selection in Undated Photos or Places.
    func dontApply(_ ids: [String], dates: Bool) {
        var copy = pending
        for id in ids {
            if dates { copy[id]?.date = nil } else { copy[id]?.place = nil }
            if copy[id]?.isEmpty == true { copy[id] = nil }
        }
        pending = copy
        deselectInLists(ids, dates: dates)
    }

    /// A photo has one change of each kind waiting: a queued one replaces its selection on the
    /// Undated Photos or Places screen, so Apply can't write two.
    private func deselectInLists(_ ids: [String], dates: Bool) {
        if dates {
            let chosen = ids.filter { decisions[$0]?.selected == true }
            if !chosen.isEmpty { select(chosen, false) }
        } else {
            let chosen = ids.filter { places.decisions[$0]?.selected == true }
            if !chosen.isEmpty { places.select(chosen, false) }
        }
    }

    nonisolated static func photos(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n.formatted()) photos" }

    // MARK: Applying

    var isApplyingAnything: Bool { isApplying || places.isApplying }

    /// Apply in To Apply: writes every waiting date and place, one kind after another. Each is
    /// undone from its History.
    func applyEverything() {
        guard !isApplyingAnything else { return }
        Task {
            var said: [String] = []
            if let text = await applyQueuedDates() { said.append(text) }
            if let text = await applySelectedNow() { said.append(text) }
            if let text = await applyQueuedPlaces() { said.append(text) }
            if let text = await places.applyCheckedNow() { said.append(text) }
            checkShiftedDates()
            banner = said.isEmpty ? "Nothing was waiting to apply." : said.joined(separator: " ")
        }
    }

    private func applyQueuedDates() async -> String? {
        let queued = pending.compactMap { id, change in change.date.map { (id, $0, change) } }
        guard !queued.isEmpty, !isApplying else { return nil }
        isApplying = true
        applyProgress = (0, queued.count)
        let keepTime = queued.filter { $0.2.keepsTime }.map(\.0)
        let current = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.shared.assets(for: keepTime).mapValues(\.creationDate)
        }.value
        let changes = queued.map { id, date, change in
            DateWriter.Change(assetID: id,
                              date: change.keepsTime ? Self.day(date, keepingTimeOf: current[id] ?? nil) : date,
                              requireUnchanged: change.expected != nil, expectedCurrentDate: change.expected)
        }
        let batch = await DateWriter.apply(changes) { done, total in
            await MainActor.run { self.applyProgress = (done, total) }
        }
        finishWrite(batch, verb: "Set the date of")
        // Written or not, they leave the queue: a failure says why in the message.
        dontApplyQueued(queued.map(\.0), dates: true)
        return banner
    }

    private func applyQueuedPlaces() async -> String? {
        let queued = pending.compactMapValues(\.place)
        guard !queued.isEmpty, let result = await places.writeLocations(queued) else { return nil }
        dontApplyQueued(result.tried, dates: false)
        return result.message
    }

    private func dontApplyQueued(_ ids: [String], dates: Bool) {
        var copy = pending
        for id in ids {
            if dates { copy[id]?.date = nil } else { copy[id]?.place = nil }
            if copy[id]?.isEmpty == true { copy[id] = nil }
        }
        pending = copy
    }

    /// `day`'s date with the time of day of `old` (noon without one).
    nonisolated static func day(_ day: Date, keepingTimeOf old: Date?, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        if let old {
            let time = calendar.dateComponents([.hour, .minute, .second], from: old)
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
        } else {
            parts.hour = 12
        }
        return calendar.date(from: parts) ?? day
    }
}
