import SwiftUI
import SwiftData
import SeedkeepKit

/// New bed and Edit bed (R3 G2): name, width and length as decimal feet (4 × 8 for a new bed), and a
/// description. A size must be from 1 to 50 feet; a blank size means no grid. An edit sends only the
/// changed fields and keeps a size the user didn't touch. Resizing never moves plantings: those that
/// fall outside a smaller grid show in the Outside list. Edit bed also deletes the bed, after a
/// confirmation. Writes go through the existing `SyncEngine` bed enqueue methods (`BedFormWriter`), and an
/// edit or delete is refused when the garden changed or the bed was deleted since the editor opened.
struct AddBedView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    /// The bed to edit, or nil for a new bed.
    private let editingBedID: String?
    /// After a new bed is created: its choice for Plan.
    private let onCreated: ((GardenSession.BedChoice) -> Void)?
    /// After the bed is deleted.
    private let onDeleted: (() -> Void)?

    @Query private var editingBeds: [LocalBed]

    @State private var form = BedForm.new()
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false
    /// The garden the editor opened in; an edit or delete is refused once the active garden differs.
    @State private var scopeHouseholdID: String?

    init(
        editingBedID: String? = nil,
        onCreated: ((GardenSession.BedChoice) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.editingBedID = editingBedID
        self.onCreated = onCreated
        self.onDeleted = onDeleted
        let id = editingBedID ?? ""
        _editingBeds = Query(filter: #Predicate<LocalBed> { $0.id == id && $0.deletedAt == nil })
    }

    private var isEditing: Bool { editingBedID != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Back garden, greenhouse shelf, etc.", text: $form.name)
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        #endif
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("bedForm.name")
                } header: {
                    WBSectionHeader("name")
                }
                Section {
                    sizeField("Width", text: $form.width, field: .width, identifier: "bedForm.width")
                    sizeField("Length", text: $form.length, field: .length, identifier: "bedForm.length")
                } header: {
                    WBSectionHeader("size")
                } footer: {
                    Text("In feet, from 1 to 50. One square on the grid is one square foot. Leave a size blank for a bed without a grid.")
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }
                Section {
                    TextField("What's special about this bed?", text: $form.description, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityLabel("Description")
                        .accessibilityIdentifier("bedForm.description")
                } header: {
                    WBSectionHeader("description")
                }
                if let error {
                    Section {
                        Label {
                            Text(error)
                                .font(.wbFootnote)
                                .foregroundStyle(WBColor.ink)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(WBColor.warn)
                                .accessibilityHidden(true)
                        }
                    }
                }
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete bed…", systemImage: "trash")
                        }
                        .accessibilityIdentifier("bedForm.delete")
                    } footer: {
                        Text("Deleting a bed unlinks its planting events; the events themselves stick around so harvest history isn't lost.")
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    }
                }
            }
            .wbForm()
            .navigationTitle(isEditing ? "Edit bed" : "New bed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                        .accessibilityIdentifier("bedForm.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || !form.canSave || (isEditing && editingBeds.first == nil))
                        .accessibilityIdentifier("bedForm.save")
                }
            }
            .confirmationDialog(
                "Delete this bed?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete bed", role: .destructive) { deleteBed() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes this bed for everyone in this garden. Its planting events and journal entries stay.")
            }
            .onAppear {
                if scopeHouseholdID == nil { scopeHouseholdID = appEnv.activeGardenHouseholdID }
                load()
            }
            .onChange(of: editingBeds.first?.id) { _, _ in load() }
            .accessibilityIdentifier(isEditing ? "screen.editBed" : "screen.newBed")
        }
    }

    private func sizeField(_ title: String, text: Binding<String>, field: BedForm.Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField("ft", text: text)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                    .accessibilityLabel("\(title) in feet")
                    .accessibilityIdentifier(identifier)
                Text("ft").foregroundStyle(WBColor.muted).accessibilityHidden(true)
            }
            .frame(minHeight: WBMetrics.minTouchTarget)
            if let message = form.message(field) {
                Text(message)
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(title): \(message)")
            }
        }
    }

    /// Loads the stored bed once for an edit; a new bed keeps the 4 × 8 default.
    private func load() {
        guard !loaded, isEditing, let bed = editingBeds.first else { return }
        loaded = true
        form = BedForm.edit(.init(
            name: bed.name, description: bed.bedDescription,
            widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet
        ))
    }

    private func save() {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let scope = editScope {
                let outcome = try BedFormWriter.update(
                    form, scope: scope, currentHouseholdID: appEnv.activeGardenHouseholdID,
                    sync: appEnv.sync, container: appEnv.container
                )
                if case .refused(let message) = outcome {
                    error = message
                    return
                }
                if outcome == .written { Task { await appEnv.syncIfPossible() } }
            } else {
                guard case .signedIn(_, let household) = appEnv.auth.state else {
                    error = "Not signed in."
                    return
                }
                let householdID = appEnv.activeGardenHouseholdID ?? household.id
                guard let created = try BedFormWriter.create(form, sync: appEnv.sync, householdID: householdID) else {
                    return
                }
                onCreated?(created)
                Task { await appEnv.syncIfPossible() }
            }
            dismiss()
        } catch let err as SeedkeepError {
            error = "\(err.code): \(err.message)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The garden and bed an edit or delete must still match; nil for a new bed.
    private var editScope: GardenActions.Scope? {
        guard let editingBedID else { return nil }
        // An editor opened with no garden matches none, so its writes are refused.
        return GardenActions.Scope(householdID: scopeHouseholdID ?? "", bedID: editingBedID)
    }

    private func deleteBed() {
        guard let scope = editScope else { return }
        error = nil
        do {
            let outcome = try BedFormWriter.delete(
                scope: scope, currentHouseholdID: appEnv.activeGardenHouseholdID,
                sync: appEnv.sync, container: appEnv.container
            )
            if case .refused(let message) = outcome {
                error = message
                return
            }
        } catch {
            appEnv.surfaceError(error)
            return
        }
        Task { await appEnv.syncIfPossible() }
        onDeleted?()
        dismiss()
    }
}
