import SwiftUI
import SeedkeepKit

/// `AsyncImage` doesn't support custom Authorization headers. This loader
/// fetches photo bytes via `SeedkeepClient.fetchSeedPhotoData(photoID:)`
/// (which adds the Bearer token) and renders them. Cached in-memory only;
/// good enough for Phase 1 — the photos are small and the seed detail
/// view is not list-scrolling.
struct AuthedImage: View {
    @Environment(AppEnvironment.self) private var appEnv
    let photoID: String
    let contentMode: ContentMode

    @State private var image: UIImage?
    @State private var failed = false

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
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).herbProgressStyle()
            }
        }
        .task(id: photoID) {
            await load()
        }
    }

    private func load() async {
        do {
            let data = try await appEnv.client.fetchSeedPhotoData(photoID: photoID)
            await MainActor.run {
                self.image = UIImage(data: data)
                if self.image == nil { self.failed = true }
            }
        } catch {
            await MainActor.run { self.failed = true }
        }
    }
}
