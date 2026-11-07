import Contacts
import Foundation

/// Reads, and when the user turns it on, updates birthdays on the Contacts cards Photos linked people to.
enum ContactBirthdays {
    struct Birthday: Equatable {
        var year: Int
        var month: Int?
        var day: Int?
    }

    /// Everything Photos knows about a person's card, tried in order to find it.
    struct Link: Hashable {
        var photosPersonID: String
        var identifiers: [String]
        var match: ContactMatch?

        init(_ tagged: TaggedPerson) {
            photosPersonID = tagged.id
            identifiers = ([tagged.contactID] + (tagged.contactMatch?.identifiers ?? [])).compactMap { $0 }
            match = tagged.contactMatch
        }

        var isEmpty: Bool { identifiers.isEmpty && match == nil }
    }

    enum SaveResult: Equatable {
        case saved(previousYear: Int?)
        case unchanged
        /// Contacts needs a month and day for a birthday, and neither the card nor the user gave them.
        case needsMonthAndDay
        case notFound
        case denied
        case failed(String)
    }

    static var isAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    /// macOS hasn't asked yet, so asking now shows the system prompt.
    static var notAskedYet: Bool { CNContactStore.authorizationStatus(for: .contacts) == .notDetermined }

    /// Shows the system prompt (or returns the earlier answer).
    static func requestAccess() async -> Bool { await requestAccess(CNContactStore()) }

    static func requestAccess(_ store: CNContactStore) async -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Finds the card: by identifier first (Contacts IDs look like "UUID:ABPerson", suffix included),
    /// then by email, phone, and finally by name when exactly one card has it.
    static func find(_ link: Link, in store: CNContactStore, keys: [CNKeyDescriptor]) -> CNContact? {
        for id in link.identifiers {
            if let c = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) { return c }
        }
        guard let match = link.match else { return nil }
        for email in match.emails {
            if let c = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: keys))?.first {
                return c
            }
        }
        for phone in match.phones {
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
            if let c = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first { return c }
        }
        let name = [match.firstName, match.lastName].compactMap { $0 }.joined(separator: " ")
        if !name.isEmpty, let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys),
           found.count == 1 {
            return found[0]
        }
        return nil
    }

    /// Asks for Contacts access if needed, then returns birthdays (with a year) keyed by Photos person.
    /// `found` counts the cards located at all, with or without a birthday.
    static func birthdays(for links: [Link]) async -> (granted: Bool, found: Int, birthdays: [String: Birthday]) {
        let store = CNContactStore()
        guard await requestAccess(store) else { return (false, 0, [:]) }
        let keys = [CNContactBirthdayKey as CNKeyDescriptor, CNContactIdentifierKey as CNKeyDescriptor]
        var out: [String: Birthday] = [:]
        var found = 0
        for link in links where !link.isEmpty {
            guard let c = find(link, in: store, keys: keys) else { continue }
            found += 1
            guard let b = c.birthday, let year = b.year, year > 1800 else { continue }
            out[link.photosPersonID] = Birthday(year: year, month: b.month, day: b.day)
        }
        return (true, found, out)
    }

    /// Sets the birthday on one card. Month and day the user didn't give are kept from the card.
    static func save(_ birthday: Birthday, to link: Link) async -> SaveResult {
        let store = CNContactStore()
        guard await requestAccess(store) else { return .denied }
        let keys = [CNContactBirthdayKey as CNKeyDescriptor, CNContactIdentifierKey as CNKeyDescriptor]
        guard let contact = find(link, in: store, keys: keys) else { return .notFound }
        let existing = contact.birthday
        guard let month = birthday.month ?? existing?.month, let day = birthday.day ?? existing?.day else {
            return .needsMonthAndDay
        }
        if existing?.year == birthday.year && existing?.month == month && existing?.day == day { return .unchanged }
        let updated = contact.mutableCopy() as! CNMutableContact
        updated.birthday = DateComponents(calendar: Calendar(identifier: .gregorian), year: birthday.year, month: month, day: day)
        let request = CNSaveRequest()
        request.update(updated)
        do {
            try store.execute(request)
            return .saved(previousYear: existing?.year)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
