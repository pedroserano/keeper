import CoreLocation
import DateGuessCore
import Foundation
import MapKit

/// Names for spots ("Annapolis, MD"), from Apple Maps. Asked one at a time and remembered, since
/// Apple limits how fast an app can ask.
@MainActor
@Observable
final class PlaceNames {
    static let shared = PlaceNames()

    private(set) var names: [String: String]
    @ObservationIgnored private var queue: [GeoPoint] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let store = JSONStore.shared
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        names = store.load([String: String].self, from: "placeNames") ?? [:]
    }

    /// About 100 m: close enough to share a name.
    static func key(_ p: GeoPoint) -> String { String(format: "%.3f,%.3f", p.lat, p.lon) }

    /// Just the town ("Annapolis, MD"), for guesses that are only good to the area.
    func city(for point: GeoPoint) -> String? {
        let key = "city|" + Self.key(point)
        if let name = names[key] { return name.isEmpty ? nil : name }
        enqueue(point)
        return nil
    }

    /// The name if it's known; otherwise asks for it, and the view updates when it arrives.
    func name(for point: GeoPoint) -> String? {
        let key = Self.key(point)
        if let name = names[key] { return name.isEmpty ? nil : name }
        enqueue(point)
        return nil
    }

    private func enqueue(_ point: GeoPoint) {
        let key = Self.key(point)
        guard !queued.contains(key) else { return }
        queued.insert(key)
        queue.append(point)
        startWorker()
    }

    func remember(_ name: String, for point: GeoPoint) {
        names[Self.key(point)] = name
        scheduleSave()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                // Newest requests first: those are the cards on screen now.
                let point = queue.removeLast()
                let found = await Self.lookUpBoth(point)
                names[Self.key(point)] = found.name ?? ""
                names["city|" + Self.key(point)] = found.city ?? found.name ?? ""
                scheduleSave()
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
            worker = nil
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            store.save(names, to: "placeNames")
        }
    }

    static func lookUp(_ point: GeoPoint) async -> String? { await lookUpBoth(point).name }

    static func lookUpBoth(_ point: GeoPoint) async -> (name: String?, city: String?) {
        let location = CLLocation(latitude: point.lat, longitude: point.lon)
        if #available(macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return (nil, nil) }
            let city = item.addressRepresentations?.cityWithContext
            if let name = item.name, let city, name != city, !name.contains(city) { return ("\(name), \(city)", city) }
            return (city ?? item.name, city)
        } else {
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return (nil, nil) }
            let city = [placemark.locality, placemark.administrativeArea ?? placemark.country].compactMap { $0 }.joined(separator: ", ")
            if let name = placemark.name, !city.isEmpty, name != placemark.locality { return ("\(name), \(city)", city) }
            return (city.isEmpty ? placemark.name : city, city.isEmpty ? nil : city)
        }
    }
}

/// As-you-type place suggestions from Apple Maps.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        var id: String { title + "|" + subtitle }
        var title: String
        var subtitle: String
        fileprivate var completion: MKLocalSearchCompletion
    }

    var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { suggestions = []; completer.cancel() }
            else { completer.queryFragment = query }
        }
    }
    private(set) var suggestions: [Suggestion] = []
    private(set) var failed = false
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.prefix(8).map { (title: $0.title, subtitle: $0.subtitle, completion: $0) }
        nonisolated(unsafe) let sendable = results
        MainActor.assumeIsolated {
            self.failed = false
            self.suggestions = sendable.map { Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0.completion) }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.failed = true }
    }

    /// The suggestion's spot and a short name for it.
    func resolve(_ suggestion: Suggestion) async -> PlaceChoice? {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26, *) { coordinate = item.location.coordinate } else { coordinate = item.placemark.coordinate }
        let name = suggestion.subtitle.isEmpty || suggestion.subtitle == "Search Nearby"
            ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        let point = GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude)
        PlaceNames.shared.remember(name, for: point)
        return PlaceChoice(name: name, point: point)
    }

    /// Typed text that isn't one of the suggestions: the best match.
    func resolve(text: String) async -> PlaceChoice? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26, *) { coordinate = item.location.coordinate } else { coordinate = item.placemark.coordinate }
        let point = GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude)
        let name = item.name ?? text
        PlaceNames.shared.remember(name, for: point)
        return PlaceChoice(name: name, point: point)
    }
}
