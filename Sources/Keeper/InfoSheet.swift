// Get Info (⌘I): the current photo's metadata, as in Photos' Info window. Dates, file, camera and
// exposure, and where it was taken: the address Apple Maps gives for its coordinates (only the
// coordinates are sent, as when Places names a spot) and the coordinates themselves.

import AppKit
import CoreLocation
import MapKit
import Photos
import SwiftUI
import KeeperCore

struct InfoSheet: View {
    let asset: PHAsset
    let libraryURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var details: PhotoDetails?
    @State private var address: String?
    @State private var lookingUp = false
    @State private var resource: PHAssetResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                AssetImage(asset: asset, pointSize: CGSize(width: 96, height: 96), fill: true)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(details?.title ?? filename ?? "Photo")
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let date = asset.creationDate {
                        Text(date.formatted(date: .complete, time: .standard)).foregroundStyle(.secondary)
                    }
                    if let caption = details?.caption {
                        Text(caption).font(.callout).lineLimit(4).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                    section("Where")
                    if let location = asset.location {
                        row("Address", address ?? (lookingUp ? "Looking up…" : "No address found"))
                        row("Coordinates", Self.coordinates(location.coordinate))
                        if location.verticalAccuracy >= 0, location.altitude != 0 {
                            row("Altitude", Measurement(value: location.altitude, unit: UnitLength.meters)
                                .formatted(.measurement(width: .abbreviated, usage: .asProvided)))
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            HStack {
                                Button("Copy Coordinates") { copy(Self.coordinates(location.coordinate)) }
                                Button("Show in Maps") { showInMaps(location.coordinate) }
                            }
                            .controlSize(.small)
                        }
                    } else {
                        row("Location", "None")
                    }

                    section("When")
                    if let date = asset.creationDate { row("Taken", date.formatted(date: .long, time: .standard)) }
                    if let zone = details?.timeZone { row("Time zone", zone) }
                    if let added = details?.addedDate {
                        row("Added", Date(timeIntervalSinceReferenceDate: added).formatted(date: .long, time: .shortened))
                    }
                    if let modified = asset.modificationDate { row("Modified", modified.formatted(date: .long, time: .shortened)) }

                    section("File")
                    if let filename { row("Filename", filename) }
                    if let type = resource?.uniformTypeIdentifier, let ut = UTType(type) {
                        row("Type", ut.localizedDescription ?? type)
                    }
                    row("Dimensions", dimensions)
                    if let bytes = details?.bytes { row("Size", bytes.formatted(.byteCount(style: .file))) }
                    if let importedBy = details?.importedBy { row("Imported by", importedBy) }

                    if details?.camera != nil || details?.lens != nil || details?.exposureText != nil {
                        section("Camera")
                        if let camera = details?.camera { row("Camera", camera) }
                        if let lens = details?.lens { row("Lens", lens) }
                        if let exposure = details?.exposureText { row("Exposure", exposure) }
                        if let flash = details?.flashFired { row("Flash", flash ? "Fired" : "Off") }
                    }

                    section("In Photos")
                    row("Favorite", asset.isFavorite ? "Yes" : "No")
                    if asset.rating.rawValue > 0 { row("Rating", String(repeating: "★", count: asset.rating.rawValue)) }
                    if asset.isHidden { row("Hidden", "Yes") }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 600)
        .task(id: asset.localIdentifier) { await load() }
    }

    private var filename: String? { details?.originalFilename ?? resource?.originalFilename }

    private var dimensions: String {
        let w = asset.pixelWidth, h = asset.pixelHeight
        let mp = Double(w * h) / 1_000_000
        return "\(w.formatted()) × \(h.formatted()) (\(mp.formatted(.number.precision(.fractionLength(1)))) MP)"
    }

    @ViewBuilder private func section(_ title: String) -> some View {
        GridRow {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .gridCellColumns(2)
                .padding(.top, 8)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "41.763710, -72.685093".
    static func coordinates(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showInMaps(_ c: CLLocationCoordinate2D) {
        let item = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        item.name = details?.title ?? filename
        item.openInMaps()
    }

    private func load() async {
        resource = PHAssetResource.assetResources(for: asset).first {
            $0.type == .photo || $0.type == .alternatePhoto
        } ?? PHAssetResource.assetResources(for: asset).first
        let uuid = String(asset.localIdentifier.prefix { $0 != "/" })
        let url = libraryURL
        details = await Task.detached(priority: .userInitiated) {
            (try? PhotosDatabase.readPhotoDetails(uuid: uuid, inLibrary: url)) ?? nil
        }.value
        guard let location = asset.location else { return }
        lookingUp = true
        defer { lookingUp = false }
        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first {
            var text = item.address?.fullAddress ?? item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: false)
            if let name = item.name, let full = text, !full.contains(name) { text = "\(name)\n\(full)" }
            address = text ?? item.name
        }
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}
