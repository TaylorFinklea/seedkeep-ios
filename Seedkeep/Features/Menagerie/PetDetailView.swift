import SwiftUI
import SwiftData
import SeedkeepKit

/// Phase 5.1.2 pet detail surface. Read-only single-pet view reached from
/// MenagerieView's row tap (or future Today roll-call taps).
///
/// Layout (top → bottom): vellum-backed hero (pressed plant + companion),
/// rubric'd name + rarity badge, italic personality vignette, optional
/// 14-day mood timeline strip, age stars or graduation laurel, optional
/// goodbye-note block (departed only), and a provenance footer.
struct PetDetailView: View {

    let plantingEventID: String

    @Query private var matches: [LocalPlantingEvent]
    @Query private var departureRows: [LocalPetDeparture]
    @Query private var moodSnapshots: [LocalPetMoodSnapshot]

    init(plantingEventID: String) {
        self.plantingEventID = plantingEventID
        let id = plantingEventID
        _matches = Query(filter: #Predicate<LocalPlantingEvent> { $0.id == id })
        _departureRows = Query(filter: #Predicate<LocalPetDeparture> {
            $0.plantingEventID == id && $0.deletedAt == nil
        })
        _moodSnapshots = Query(
            filter: #Predicate<LocalPetMoodSnapshot> { $0.plantingEventID == id },
            sort: \LocalPetMoodSnapshot.dayYMD,
            order: .reverse
        )
    }

    var body: some View {
        ZStack {
            VellumBackground()
            ScrollView {
                if let pet = matches.first {
                    content(for: pet)
                } else {
                    ContentUnavailableView(
                        "Pet unavailable",
                        systemImage: "pawprint",
                        description: Text("This planting may have been removed on another device.")
                    )
                    .padding(.top, 60)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(for pet: LocalPlantingEvent) -> some View {
        let phase = pet.petLifecyclePhase
        let departure = departureRows.first

        VStack(alignment: .leading, spacing: 16) {
            hero(pet: pet, phase: phase)
            nameBlock(pet: pet)
            if let vignette = pet.petPersonality?.vignette, !vignette.isEmpty {
                Text(vignette)
                    .font(HerbFont.bodyItalic(size: 14))
                    .foregroundStyle(HerbColor.ink)
                    .padding(.horizontal, 22)
            }
            if phase == .alive || phase == .wilted || phase == .departing {
                moodStrip(pet: pet, phase: phase, departure: departure)
            }
            ageBlock(pet: pet, phase: phase)
            if phase == .departed, let note = goodbyeNote(departure) {
                goodbyeBlock(note: note)
            }
            provenance(pet: pet)
        }
        .padding(.vertical, 18)
        .padding(.bottom, 96)
    }

    // MARK: - Hero

    private func hero(pet: LocalPlantingEvent, phase: PetLifecyclePhase) -> some View {
        let creatureOpacity: Double = {
            switch phase {
            case .alive, .wilted, .graduated: return 1.0
            case .departing: return 0.45
            case .departed: return 0.2
            }
        }()
        let creatureRotation: Double = {
            switch phase {
            case .wilted: return -4
            case .departing: return -8
            default: return 0
            }
        }()
        let creature = CompanionKind.from(pet.petCreatureKind)

        return HStack(alignment: .center, spacing: 24) {
            // Pressed plant on the left (best-effort; uses the existing
            // PressedPlant dispatch which falls back to a generic shape).
            PressedPlant(kind: .generic, size: 96, faded: phase == .departed)
                .frame(width: 96, height: 96)
            CompanionIllustration(
                kind: creature,
                size: 96,
                faded: phase == .wilted || phase == .departing
            )
            .opacity(creatureOpacity)
            .rotationEffect(.degrees(creatureRotation))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .padding(.horizontal, 22)
    }

    // MARK: - Name + rarity

    private func nameBlock(pet: LocalPlantingEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(pet.petName ?? pet.petPersonality?.name ?? "Companion")
                .font(HerbFont.display(size: 30))
                .foregroundStyle(HerbColor.ink)
            Spacer()
            if let rarity = pet.petRarityValue {
                RarityBadge(rarity: rarity)
            }
        }
        .padding(.horizontal, 22)
    }

    // MARK: - Mood strip

    private func moodStrip(pet: LocalPlantingEvent, phase: PetLifecyclePhase, departure: LocalPetDeparture?) -> some View {
        let anchor: Date = {
            switch phase {
            case .alive, .wilted, .departing: return Date()
            case .departed: return Date(timeIntervalSince1970: TimeInterval((departure?.departedAt ?? 0) / 1000))
            case .graduated: return Date(timeIntervalSince1970: TimeInterval((pet.completedAt ?? 0) / 1000))
            }
        }()
        let calendar = Calendar(identifier: .gregorian)
        let snapByYMD = Dictionary(uniqueKeysWithValues:
            moodSnapshots.map { ($0.dayYMD, $0) })
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            return f
        }()

        return VStack(alignment: .leading, spacing: 6) {
            Rubric(text: "last 14 days")
            HStack(spacing: 6) {
                ForEach(0..<14, id: \.self) { i in
                    let day = calendar.date(byAdding: .day, value: -(13 - i), to: anchor) ?? anchor
                    let key = formatter.string(from: day)
                    Circle()
                        .fill(color(for: snapByYMD[key]))
                        .frame(width: 12, height: 12)
                }
            }
        }
        .padding(.horizontal, 22)
    }

    private func color(for snapshot: LocalPetMoodSnapshot?) -> Color {
        guard let snapshot,
              let label = PetMoodLabel(rawValue: snapshot.moodLabel)
        else { return HerbColor.inkFaint.opacity(0.3) }
        switch label {
        case .thriving:          return HerbColor.moodThriving
        case .content:           return HerbColor.moodContent
        case .quiet:             return HerbColor.moodQuiet
        case .wilted:            return HerbColor.moodWilted
        case .departingImminent: return HerbColor.moodDepartingImminent
        }
    }

    // MARK: - Age + graduation

    @ViewBuilder
    private func ageBlock(pet: LocalPlantingEvent, phase: PetLifecyclePhase) -> some View {
        if phase == .alive || phase == .wilted || phase == .departing {
            let stars = PetAgeStars.compute(spawnedAt: pet.petSpawnedAt, phase: phase)
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < stars ? HerbColor.goldInk : HerbColor.inkFaint.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
        } else if phase == .graduated {
            HStack(spacing: 6) {
                Image(systemName: "laurel.leading")
                    .foregroundStyle(HerbColor.goldInk)
                Text("Graduated")
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(HerbColor.inkSoft)
                Image(systemName: "laurel.trailing")
                    .foregroundStyle(HerbColor.goldInk)
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: - Goodbye note

    private func goodbyeNote(_ departure: LocalPetDeparture?) -> PetGoodbyeNote? {
        guard let json = departure?.goodbyeNoteJSON,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(PetGoodbyeNote.self, from: data)
    }

    private func goodbyeBlock(note: PetGoodbyeNote) -> some View {
        VStack(spacing: 0) {
            TapeStrip()
            VStack(alignment: .center, spacing: 10) {
                Text(note.noteText)
                    .font(HerbFont.handwritten(size: 18))
                    .foregroundStyle(HerbColor.ink)
                    .multilineTextAlignment(.center)
                Text("— \(note.signoff)")
                    .font(HerbFont.handwrittenEmph(size: 16))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 24)
            TapeStrip()
        }
        .padding(.horizontal, 22)
    }

    // MARK: - Provenance

    private func provenance(pet: LocalPlantingEvent) -> some View {
        let spawnedDate: String = {
            guard let ms = pet.petSpawnedAt else { return "—" }
            let date = Date(timeIntervalSince1970: TimeInterval(ms / 1000))
            let f = DateFormatter()
            f.dateStyle = .medium
            return f.string(from: date)
        }()
        return Text("SPAWNED \(spawnedDate)")
            .font(HerbFont.smallCaps(size: 9))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(HerbColor.inkFaint)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
    }
}
