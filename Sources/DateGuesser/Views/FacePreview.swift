import SwiftUI
import DateGuessCore

/// A photo with a box on every face Photos detected, labeled with the name Photos has for it.
/// Names come only from Photos: clicking a face shows who it is and offers to open the photo there.
struct FacePreview: View {
    @Environment(AppState.self) private var state
    var assetID: String
    var maxSide: CGFloat
    var _loader = State<ThumbnailLoader>(initialValue: ThumbnailLoader())
    private var loader: ThumbnailLoader { get { _loader.wrappedValue } nonmutating set { _loader.wrappedValue = newValue } }
    var _openFace = State<Int?>(initialValue: nil)
    private var openFace: Int? { get { _openFace.wrappedValue } nonmutating set { _openFace.wrappedValue = newValue } }

    var body: some View {
        let faces = state.detectedFaces[assetID] ?? []
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            GeometryReader { geo in
                                let diagonal = (geo.size.width * geo.size.width + geo.size.height * geo.size.height).squareRoot()
                                ForEach(faces.indices, id: \.self) { i in
                                    let f = faces[i]
                                    let side = max(24, f.size * diagonal)
                                    faceBox(f, index: i)
                                        .frame(width: side, height: side)
                                        .position(x: f.x * geo.size.width, y: f.y * geo.size.height)
                                }
                            }
                        }
                } else {
                    ProgressView().frame(width: maxSide, height: maxSide * 0.7)
                }
            }
            .frame(maxWidth: maxSide, maxHeight: maxSide)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                if !faces.isEmpty {
                    Label("Name faces in Photos; names show up here when you come back.", systemImage: "info.circle")
                } else if state.taggedPeople.isEmpty {
                    Label("Import from Photos (People tab) to see the faces Photos found.", systemImage: "info.circle")
                }
                Spacer(minLength: 8)
                ShowInPhotosButton(assetID: assetID)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { loader.load(assetID, side: maxSide) }
        .onChange(of: ImageRevisions.shared.revision(assetID)) { loader.load(assetID, side: maxSide, force: true) }
        .onDisappear { loader.cancel() }
    }

    private func faceBox(_ face: DetectedFace, index: Int) -> some View {
        let person = face.clusterID.flatMap { state.clusterPeople[$0] }.flatMap { id in state.people.first { $0.id == id } }
        let named = person != nil
        return Button {
            openFace = index
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(named ? Color.green : Color.white, style: StrokeStyle(lineWidth: 2, dash: named ? [] : [5, 3]))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.001)))
                .shadow(color: .black.opacity(0.6), radius: 1.5)
                .overlay(alignment: .bottom) {
                    if let name = person?.name ?? face.name {
                        Text(name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.black.opacity(0.65), in: Capsule())
                            .foregroundStyle(.white)
                            .offset(y: 16)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(person.map(\.name) ?? face.name ?? "Not named in Photos")
        .popover(isPresented: Binding(get: { openFace == index }, set: { if !$0 { openFace = nil } }), arrowEdge: .trailing) {
            FaceInfo(assetID: assetID, face: face)
                .padding(16)
                .frame(width: 300)
        }
    }
}

/// Who a detected face is, according to Photos, plus the birth year this app needs.
struct FaceInfo: View {
    @Environment(AppState.self) private var state
    var assetID: String
    var face: DetectedFace

    private var person: PersonInfo? {
        face.clusterID.flatMap { state.clusterPeople[$0] }.flatMap { id in state.people.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let person {
                Text(person.name).font(.headline)
                HStack {
                    Text("Born")
                    NumberField(title: "year", value: birthYear(person.id), range: 1850...YearBounds.currentYear(), width: 64)
                    if person.birthYear == nil {
                        Text("(needed to date photos)").font(.caption).foregroundStyle(.secondary)
                    } else if person.birthdayFromContacts == true {
                        Text("from Contacts").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let name = face.name {
                Text(name).font(.headline)
                Text("Named in Photos since the last refresh. It’s picked up when you come back from Photos.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not named in Photos").font(.headline)
                Text("Click Show in Photos and name this face there. The name shows up here when you come back.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ShowInPhotosButton(assetID: assetID)
        }
    }

    private func birthYear(_ id: UUID) -> Binding<Int?> {
        Binding(
            get: { state.people.first { $0.id == id }?.birthYear },
            set: { year in state.updateBirthday(id) { $0.birthYear = year } })
    }
}

/// Opens the photo in Photos, e.g. to name a face there so it's tagged in Photos too. Problems are
/// shown right under the button, since this is often used inside a sheet that hides the banner.
struct ShowInPhotosButton: View {
    @Environment(AppState.self) private var state
    var assetID: String
    var _problem = State<String?>(initialValue: nil)
    private var problem: String? { get { _problem.wrappedValue } nonmutating set { _problem.wrappedValue = newValue } }
    var _working = State<Bool>(initialValue: false)
    private var working: Bool { get { _working.wrappedValue } nonmutating set { _working.wrappedValue = newValue } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                working = true
                problem = nil
                Task {
                    problem = await state.showInPhotos(assetID)
                    working = false
                }
            } label: {
                if working {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("Show in Photos", systemImage: "photo.on.rectangle")
                }
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(working)
            .help("Opens this photo in Photos, where you can name faces and edit it")
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }
}
