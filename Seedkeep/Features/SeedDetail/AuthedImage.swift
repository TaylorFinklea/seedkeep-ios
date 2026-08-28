import SwiftUI
import SeedkeepKit

/// Loads seed-photo bytes through the active storage boundary: the durable
/// CloudKit photo stores while that mode is active, or the authenticated
/// server route in rollback mode.
struct AuthedImage: View {
    @Environment(AppEnvironment.self) private var appEnv
    let photoID: String
    let contentMode: ContentMode

    @State private var image: UIImage?
    @State private var isLoading = true

    init(photoID: String, contentMode: ContentMode = .fill) {
        self.photoID = photoID
        self.contentMode = contentMode
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading {
                ProgressView().controlSize(.small).herbProgressStyle()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: photoID) {
            await load()
        }
    }

    private func load() async {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        do {
            guard let data = try await appEnv.sync.fetchSeedPhotoData(
                photoID: photoID,
                householdID: appEnv.activeGardenHouseholdID
            ) else { return }
            await MainActor.run {
                self.image = UIImage(data: data)
            }
        } catch {
            await MainActor.run { self.image = nil }
        }
    }
}
