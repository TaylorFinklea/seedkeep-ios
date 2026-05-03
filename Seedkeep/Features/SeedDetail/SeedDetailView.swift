import SwiftUI
import SwiftData
import PhotosUI
import SeedkeepKit

/// Detail + edit view. The view loads the matching `LocalSeed` via id so
/// it stays in sync with the local store; edits go through the SyncEngine
/// (optimistic local + queued push).
struct SeedDetailView: View {
    let seedID: String

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @Query private var seedQuery: [LocalSeed]
    @Query private var photoQuery: [LocalSeedPhoto]

    @Query(filter: #Predicate<LocalLocation> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var locations: [LocalLocation]

    @Query(filter: #Predicate<LocalTag> { $0.deletedAt == nil },
           sort: \.name, order: .forward)
    private var tags: [LocalTag]

    @State private var pendingDelete = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploadingPhoto = false
    @State private var uploadError: String?

    init(seedID: String) {
        self.seedID = seedID
        let id = seedID
        _seedQuery = Query(filter: #Predicate<LocalSeed> { $0.id == id })
        _photoQuery = Query(
            filter: #Predicate<LocalSeedPhoto> { $0.seedID == id },
            sort: \.capturedAt,
            order: .forward
        )
    }

    var body: some View {
        Group {
            if let seed = seedQuery.first {
                Form {
                    headerSection(seed)
                    photosSection(seed)
                    lifecycleSection(seed)
                    if seed.state != .wishlist {
                        quantitySection(seed)
                    }
                    storageSection(seed)
                    provenanceSection(seed)
                    notesSection(seed)
                    deleteSection(seed)
                }
                .navigationTitle(seed.customName ?? "Seed")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: seed.id) {
                    // Refresh photos on first appearance so the grid is
                    // current even if the local store predates new uploads.
                    if case .signedIn(_, let household) = appEnv.auth.state {
                        try? await appEnv.sync.refreshSeedPhotos(seedID: seed.id, householdID: household.id)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Seed unavailable",
                    systemImage: "leaf.slash",
                    description: Text("This seed may have been deleted on another device.")
                )
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func photosSection(_ seed: LocalSeed) -> some View {
        Section("Photos") {
            if photoQuery.isEmpty {
                Text("No photos yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photoQuery, id: \.id) { photo in
                            AuthedImage(photoID: photo.id, contentMode: .fill)
                                .frame(width: 96, height: 96)
                                .clipped()
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(alignment: .bottomLeading) {
                                    Text(photo.role.rawValue)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.black.opacity(0.6), in: .capsule)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                PhotosPicker(
                    selection: $pickedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(uploadingPhoto ? "Uploading…" : "Add photo", systemImage: "photo.badge.plus")
                }
                .disabled(uploadingPhoto)
                if uploadingPhoto {
                    ProgressView().controlSize(.small)
                }
            }
            if let uploadError {
                Text(uploadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await uploadPicked(item, seedID: seed.id) }
        }
    }

    private func uploadPicked(_ item: PhotosPickerItem, seedID: String) async {
        uploadingPhoto = true
        uploadError = nil
        defer { uploadingPhoto = false; pickedPhoto = nil }

        guard case .signedIn(_, let household) = appEnv.auth.state else {
            uploadError = "Not signed in."
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                uploadError = "Couldn't read the selected photo."
                return
            }
            let jpeg = jpegEncode(originalData: data) ?? data
            try await appEnv.sync.uploadPhoto(
                seedID: seedID,
                role: .extra,
                jpegData: jpeg,
                householdID: household.id
            )
        } catch let err as SeedkeepError {
            uploadError = "\(err.code): \(err.message)"
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// Convert HEIC/PNG bytes from the photo picker into a reasonably-sized
    /// JPEG so the upload body stays manageable. ~75% quality balances
    /// quality vs. wire size for packet photos.
    private func jpegEncode(originalData: Data) -> Data? {
        guard let image = UIImage(data: originalData) else { return nil }
        return image.jpegData(compressionQuality: 0.75)
    }

    @ViewBuilder
    private func headerSection(_ seed: LocalSeed) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(seed.customName ?? "Untitled seed")
                    .font(.title2.weight(.semibold))
                if let v = seed.customVariety, !v.isEmpty, v != seed.customName {
                    Text(v).foregroundStyle(.secondary)
                }
                if let c = seed.customCompany, !c.isEmpty {
                    Text(c).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func lifecycleSection(_ seed: LocalSeed) -> some View {
        Section("Lifecycle") {
            Picker(
                "State",
                selection: Binding(
                    get: { seed.state },
                    set: { newState in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(state: newState))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            ) {
                Text("Active").tag(SeedState.active)
                Text("Wishlist").tag(SeedState.wishlist)
                Text("Saved").tag(SeedState.saved)
                Text("Archive").tag(SeedState.archived)
            }
        }
    }

    @ViewBuilder
    private func quantitySection(_ seed: LocalSeed) -> some View {
        Section("Quantity") {
            Stepper(
                "\(seed.packetCount) packet\(seed.packetCount == 1 ? "" : "s")",
                value: Binding(
                    get: { seed.packetCount },
                    set: { newCount in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(packet_count: newCount))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                ),
                in: 0...100
            )
        }
    }

    @ViewBuilder
    private func storageSection(_ seed: LocalSeed) -> some View {
        Section("Storage") {
            Picker(
                "Location",
                selection: Binding(
                    get: { seed.locationID },
                    set: { newID in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(location_id: newID))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            ) {
                Text("None").tag(String?.none)
                ForEach(locations) { loc in
                    Text(loc.name).tag(Optional(loc.id))
                }
            }

            if !tags.isEmpty {
                let selection = Binding<Set<String>>(
                    get: { Set(seed.tagIDs) },
                    set: { newSet in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(tag_ids: Array(newSet)))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
                NavigationLink {
                    TagSelectionView(tags: tags, selection: selection)
                } label: {
                    HStack {
                        Text("Tags")
                        Spacer()
                        Text(selection.wrappedValue.isEmpty ? "None" : "\(selection.wrappedValue.count) selected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func provenanceSection(_ seed: LocalSeed) -> some View {
        Section("Provenance") {
            Picker(
                "Source",
                selection: Binding(
                    get: { seed.source },
                    set: { newSource in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(source: newSource))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            ) {
                Text("Store-bought").tag(SeedSource.store)
                Text("Self-saved").tag(SeedSource.saved)
                Text("Gift").tag(SeedSource.gift)
                Text("Swap").tag(SeedSource.swap)
            }

            YearPicker(
                year: Binding(
                    get: { seed.yearPacked },
                    set: { newYear in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(year_packed: newYear))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            )
        }
    }

    @ViewBuilder
    private func notesSection(_ seed: LocalSeed) -> some View {
        Section("Notes") {
            TextField(
                "Notes",
                text: Binding(
                    get: { seed.notes ?? "" },
                    set: { newNotes in
                        try? appEnv.sync.enqueueUpdateSeed(
                            id: seed.id,
                            .init(notes: newNotes.isEmpty ? nil : newNotes)
                        )
                        // Throttle: don't push every keystroke. Push once when
                        // the user navigates away — handled by .onDisappear.
                    }
                ),
                axis: .vertical
            )
            .lineLimit(3...8)
        }
        .onDisappear {
            Task { try? await appEnv.sync.flushPending() }
        }
    }

    @ViewBuilder
    private func deleteSection(_ seed: LocalSeed) -> some View {
        Section {
            Button("Delete seed", role: .destructive) {
                pendingDelete = true
            }
        }
        .confirmationDialog("Delete this seed?", isPresented: $pendingDelete) {
            Button("Delete", role: .destructive) {
                try? appEnv.sync.enqueueDeleteSeed(id: seed.id)
                Task { try? await appEnv.sync.flushPending() }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove it from this device and the household.")
        }
    }
}

private struct TagSelectionView: View {
    let tags: [LocalTag]
    @Binding var selection: Set<String>

    var body: some View {
        List(tags) { tag in
            Button {
                if selection.contains(tag.id) {
                    selection.remove(tag.id)
                } else {
                    selection.insert(tag.id)
                }
            } label: {
                HStack {
                    Text(tag.name)
                    Spacer()
                    if selection.contains(tag.id) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct YearPicker: View {
    @Binding var year: Int?
    private let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    var body: some View {
        Picker("Year packed", selection: $year) {
            Text("Unknown").tag(Int?.none)
            ForEach((currentYear - 8 ... currentYear + 1).reversed(), id: \.self) { y in
                Text(String(y)).tag(Optional(y))
            }
        }
    }
}
