import SwiftUI
import SwiftData
import PhotosUI
import SeedkeepKit

/// Create + edit a journal entry. `entryID == nil` means create; otherwise
/// the view loads the existing `LocalJournalEntry` and PATCHes on save.
struct JournalEntryView: View {
    /// nil ⇒ creating new; non-nil ⇒ editing existing entry by id.
    let entryID: String?

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var photos: [LocalJournalEntryPhoto]
    @Query private var checklistItems: [LocalJournalChecklistItem]

    @State private var occurredOn: Date = Date()
    @State private var newItemText: String = ""
    @State private var entryBody: String = ""
    @State private var seedID: String?
    @State private var bedID: String?
    @State private var plantingEventID: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var didLoadInitial = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var uploadingPhotos: Bool = false

    init(entryID: String?) {
        self.entryID = entryID
        // Scope the photo query to this entry's ID. Use "__none__" sentinel when
        // creating a new entry — the query returns nothing, which is fine.
        let id = entryID ?? "__none__"
        _photos = Query(
            filter: #Predicate<LocalJournalEntryPhoto> { $0.entryID == id },
            sort: \.sortOrder)
        _checklistItems = Query(
            filter: #Predicate<LocalJournalChecklistItem> { $0.entryID == id },
            sort: \.sortOrder)
    }

    var body: some View {
        Form {
            Section("Date") {
                DatePicker("Occurred on", selection: $occurredOn, displayedComponents: .date)
            }
            Section("Entry") {
                TextField("What happened?", text: $entryBody, axis: .vertical)
                    .lineLimit(3...12)
            }
            Section {
                AttachedEntityPicker(
                    seedID: $seedID,
                    bedID: $bedID,
                    plantingEventID: $plantingEventID)
            } header: {
                Text("Attached to")
            }

            Section("Photos") {
                if photos.isEmpty && entryID == nil {
                    Text("Save the entry before adding photos")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos) { photo in
                                photoThumb(photo)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if let entryID {
                        PhotosPicker(
                            selection: $photosPickerItems,
                            maxSelectionCount: 5,
                            matching: .images
                        ) {
                            Label(uploadingPhotos ? "Uploading…" : "Add photos",
                                  systemImage: "photo.badge.plus")
                        }
                        .disabled(uploadingPhotos)
                        .onChange(of: photosPickerItems) { _, newItems in
                            guard !newItems.isEmpty else { return }
                            Task { await uploadPicked(newItems, entryID: entryID) }
                        }
                    }
                }
            }

            Section("Checklist") {
                if checklistItems.isEmpty && entryID == nil {
                    Text("Save the entry before adding checklist items")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(checklistItems) { item in
                        checklistRow(item)
                    }
                    if let entryID {
                        HStack {
                            TextField("New item", text: $newItemText)
                                .textFieldStyle(.plain)
                                .onSubmit { Task { await addItem(entryID: entryID) } }
                            Button {
                                Task { await addItem(entryID: entryID) }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            .disabled(newItemText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(HerbColor.rose)
                }
            }
        }
        .navigationTitle(entryID == nil ? "New entry" : "Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(saving || entryBody.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(saving)
            }
        }
        .task {
            // Load existing entry's fields the first time the view appears.
            guard !didLoadInitial else { return }
            didLoadInitial = true
            if let id = entryID,
               let existing = try? modelContext.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
               ).first {
                loadFields(from: existing)
            }
        }
    }

    private func loadFields(from entry: LocalJournalEntry) {
        if let date = Self.parseYYYYMMDD(entry.occurredOn) { occurredOn = date }
        entryBody = entry.body
        seedID = entry.seedID
        bedID = entry.bedID
        plantingEventID = entry.plantingEventID
    }

    private func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }
        let dateStr = Self.yyyymmdd(occurredOn)
        do {
            if let id = entryID,
               let local = try? modelContext.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
               ).first {
                // PATCH existing entry. Use `.some(value)` (including
                // `.some(nil)` to clear) so the encoder actually emits
                // the field — plain `nil` would mean "omit / no change".
                var patch = SeedkeepClient.UpdateJournalEntryInput()
                patch.occurredOn = dateStr
                patch.body = entryBody
                patch.seedId = .some(seedID)
                patch.bedId = .some(bedID)
                patch.plantingEventId = .some(plantingEventID)
                let dto = try await appEnv.client.updateJournalEntry(local.id, patch)
                dto.apply(to: local)
                try modelContext.save()
            } else {
                // Create new entry via the store.
                _ = try await appEnv.journal.create(
                    occurredOn: dateStr,
                    body: entryBody,
                    seedID: seedID,
                    bedID: bedID,
                    plantingEventID: plantingEventID)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func photoThumb(_ photo: LocalJournalEntryPhoto) -> some View {
        JournalPhotoThumbnail(photoId: photo.id)
            .frame(width: 88, height: 88)
            .clipShape(.rect(cornerRadius: 8))
            .contextMenu {
                Button(role: .destructive) {
                    Task { await deletePhoto(photo) }
                } label: {
                    Label("Delete photo", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func checklistRow(_ item: LocalJournalChecklistItem) -> some View {
        HStack {
            Button {
                Task { await toggle(item) }
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.completed ? HerbColor.sage : Color.secondary)
            }
            .buttonStyle(.plain)
            Text(item.text)
                .strikethrough(item.completed, color: .secondary)
                .foregroundStyle(item.completed ? .secondary : .primary)
            Spacer()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await deleteItem(item) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func addItem(entryID: String) async {
        let text = newItemText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            let dto = try await appEnv.client.addChecklistItem(entryId: entryID, text: text)
            modelContext.insert(dto.makeLocal())
            try modelContext.save()
            newItemText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ item: LocalJournalChecklistItem) async {
        let newCompleted = !item.completed
        do {
            var patch = SeedkeepClient.UpdateChecklistItemInput()
            patch.completed = newCompleted
            let dto = try await appEnv.client.updateChecklistItem(item.id, patch)
            dto.apply(to: item)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: LocalJournalChecklistItem) async {
        do {
            try await appEnv.client.deleteChecklistItem(item.id)
            modelContext.delete(item)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func uploadPicked(_ items: [PhotosPickerItem], entryID: String) async {
        uploadingPhotos = true
        defer {
            uploadingPhotos = false
            photosPickerItems = []
        }
        for item in items {
            do {
                guard let rawData = try await item.loadTransferable(type: Data.self) else { continue }
                // Resize off main actor (same idiom as ScanFlow).
                let jpegData = await Self.resizedJPEG(rawData, maxDimension: 2048, quality: 0.85) ?? rawData
                // Decode width/height for the server's optional X-Photo-* headers.
                let (width, height) = await Self.imageDimensions(jpegData)
                let dto = try await appEnv.client.uploadJournalPhoto(
                    entryId: entryID,
                    jpegData: jpegData,
                    width: width,
                    height: height)
                modelContext.insert(dto.makeLocal())
                try modelContext.save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deletePhoto(_ photo: LocalJournalEntryPhoto) async {
        do {
            try await appEnv.client.deleteJournalPhoto(photo.id)
            modelContext.delete(photo)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resize a JPEG/PNG/HEIC to fit within `maxDimension` (longer side) and
    /// re-encode as JPEG at the given quality. Returns nil on failure.
    /// Copied from ScanFlow.swift — keeping a local copy here so the journal
    /// flow doesn't accidentally regress if the scan flow's helper changes.
    nonisolated private static func resizedJPEG(
        _ data: Data, maxDimension: CGFloat, quality: CGFloat
    ) async -> Data? {
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let source = UIImage(data: data) else { return nil }
            let size = source.size
            let longest = max(size.width, size.height)
            if longest <= maxDimension {
                return source.jpegData(compressionQuality: quality)
            }
            let scale = maxDimension / longest
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.image { _ in
                source.draw(in: CGRect(origin: .zero, size: newSize))
            }
            return resized.jpegData(compressionQuality: quality)
        }.value
    }

    /// Decode pixel dimensions from JPEG bytes — used to populate the
    /// X-Photo-Width / X-Photo-Height headers the server stores.
    nonisolated private static func imageDimensions(_ data: Data) async -> (Int?, Int?) {
        return await Task.detached(priority: .userInitiated) { () -> (Int?, Int?) in
            guard let img = UIImage(data: data) else { return (nil, nil) }
            return (Int(img.size.width), Int(img.size.height))
        }.value
    }

    static func yyyymmdd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: date)
    }

    static func parseYYYYMMDD(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: s)
    }
}

private struct JournalPhotoThumbnail: View {
    let photoId: String
    @Environment(AppEnvironment.self) private var appEnv
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .herbProgressStyle()
            }
        }
        .task {
            guard image == nil else { return }
            do {
                let data = try await appEnv.client.journalPhotoData(photoId: photoId)
                self.image = UIImage(data: data)
            } catch {
                // Silent — thumbnail just stays as a spinner.
            }
        }
    }
}
