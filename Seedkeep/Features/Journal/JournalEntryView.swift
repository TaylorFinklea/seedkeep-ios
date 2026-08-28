import SwiftUI
import SwiftData
import PhotosUI
import SeedkeepKit
import SeedkeepCloudKit

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
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entryID == nil ? "Press a new leaf" : "Tend the record")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(2)
                        .foregroundStyle(HerbColor.sepia)
                        .textCase(.uppercase)
                    Text(entryID == nil ? "New entry" : "Edit entry")
                        .font(HerbFont.display(size: 30))
                        .foregroundStyle(HerbColor.ink)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                .listRowSeparator(.hidden)
            }
            Section {
                DatePicker("Occurred on", selection: $occurredOn, displayedComponents: .date)
            } header: {
                Rubric(text: "date")
            }
            Section {
                TextField("What happened?", text: $entryBody, axis: .vertical)
                    .lineLimit(3...12)
            } header: {
                Rubric(text: "entry")
            }
            Section {
                AttachedEntityPicker(
                    seedID: $seedID,
                    bedID: $bedID,
                    plantingEventID: $plantingEventID)
            } header: {
                Rubric(text: "attached to")
            }

            Section {
                if photos.isEmpty && entryID == nil {
                    Text("Save the entry before adding photos")
                        .font(.footnote)
                        .foregroundStyle(HerbColor.inkSoft)
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
            } header: {
                Rubric(text: "photos")
            }

            Section {
                if checklistItems.isEmpty && entryID == nil {
                    Text("Save the entry before adding checklist items")
                        .font(.footnote)
                        .foregroundStyle(HerbColor.inkSoft)
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
            } header: {
                Rubric(text: "checklist")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(HerbColor.rose)
                }
            }
        }
        .vellumForm()
        .navigationTitle("")
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
                try await appEnv.journal.update(
                    local,
                    occurredOn: dateStr,
                    body: entryBody,
                    seedID: seedID,
                    bedID: bedID,
                    plantingEventID: plantingEventID,
                    householdID: appEnv.activeGardenHouseholdID
                )
            } else {
                _ = try await appEnv.journal.create(
                    occurredOn: dateStr,
                    body: entryBody,
                    seedID: seedID,
                    bedID: bedID,
                    plantingEventID: plantingEventID,
                    householdID: appEnv.activeGardenHouseholdID
                )
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
            .overlay(alignment: .topTrailing) {
                if isFailedPhoto(photo) {
                    Button {
                        Task { await retryPhoto(photo) }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, HerbColor.rose)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry photo sync")
                }
            }
            .contextMenu {
                if isFailedPhoto(photo) {
                    Button {
                        Task { await retryPhoto(photo) }
                    } label: {
                        Label("Retry sync", systemImage: "arrow.clockwise")
                    }
                }
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
                    .foregroundStyle(item.completed ? HerbColor.sage : HerbColor.inkSoft)
            }
            .buttonStyle(.plain)
            Text(item.text)
                .strikethrough(item.completed, color: HerbColor.inkSoft)
                .foregroundStyle(item.completed ? HerbColor.inkSoft : HerbColor.ink)
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
            _ = try await appEnv.journal.addChecklistItem(
                entryID: entryID,
                text: text,
                householdID: appEnv.activeGardenHouseholdID
            )
            newItemText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ item: LocalJournalChecklistItem) async {
        let newCompleted = !item.completed
        do {
            try await appEnv.journal.updateChecklistItem(
                item,
                completed: newCompleted,
                householdID: appEnv.activeGardenHouseholdID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem(_ item: LocalJournalChecklistItem) async {
        do {
            try await appEnv.journal.deleteChecklistItem(
                item,
                householdID: appEnv.activeGardenHouseholdID
            )
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
                // Resize off main actor (same idiom as ScanFlow). Photo path: resize failure means
                // "photo not created" (D6) — never fall back to uploading the original.
                let jpegData = try await Task.detached(priority: .userInitiated) {
                    try PhotoResizer.resizedPhotoJPEG(rawData)
                }.value
                // Decode width/height for the server's optional X-Photo-* headers.
                let (width, height) = await Self.imageDimensions(jpegData)
                _ = try await appEnv.sync.uploadJournalPhoto(
                    entryId: entryID,
                    jpegData: jpegData,
                    width: width,
                    height: height,
                    householdID: appEnv.activeGardenHouseholdID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deletePhoto(_ photo: LocalJournalEntryPhoto) async {
        do {
            try await appEnv.sync.deleteJournalPhoto(
                photo.id,
                householdID: appEnv.activeGardenHouseholdID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isFailedPhoto(_ photo: LocalJournalEntryPhoto) -> Bool {
        appEnv.cloudKit?.failedPhotoRecordNames.contains(
            SeedkeepRecordNames.journalEntryPhoto(photo.id)
        ) == true
    }

    private func retryPhoto(_ photo: LocalJournalEntryPhoto) async {
        guard let coordinator = appEnv.cloudKit else { return }
        do {
            try await coordinator.retryPhotoSync(
                recordName: SeedkeepRecordNames.journalEntryPhoto(photo.id))
        } catch {
            errorMessage = error.localizedDescription
        }
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
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .herbProgressStyle()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard image == nil else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                if let data = try await appEnv.sync.journalPhotoData(
                    photoId: photoId,
                    householdID: appEnv.activeGardenHouseholdID
                ) {
                    image = UIImage(data: data)
                }
            } catch {
                // The neutral placeholder remains available for a later retry.
            }
        }
    }
}
