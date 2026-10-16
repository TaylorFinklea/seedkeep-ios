#if os(iOS)
import CloudKit
import UIKit

/// Presents the system `UICloudSharingController` for a prepared zone-wide CKShare so the owner can
/// invite a partner via the native share sheet (Messages/Mail/…).
///
/// Presented DIRECTLY from the top view controller — NOT embedded as the root of a SwiftUI `.sheet`.
/// Embedding `UICloudSharingController` as a sheet's content view controller makes it render then
/// immediately dismiss itself (it expects modal presentation). The share is created/fetched by
/// `AppEnvironment.prepareOwnerShare` beforehand. Ported from SimmerSmith (commit 34a2288 fix).
enum CloudSharingPresenter {

    @MainActor
    static func present(share: CKShare, container: CKContainer, title: String, onComplete: @escaping () -> Void = {}) {
        guard let top = topViewController() else { return }
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        let delegate = Delegate(title: title, onComplete: onComplete)
        controller.delegate = delegate
        // UICloudSharingController.delegate is weak — keep the delegate alive for the controller's
        // lifetime via an associated object so the save/stop callbacks still fire.
        objc_setAssociatedObject(controller, &Delegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        top.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    final class Delegate: NSObject, UICloudSharingControllerDelegate {
        static var associatedKey: UInt8 = 0
        let title: String
        let onComplete: () -> Void
        init(title: String, onComplete: @escaping () -> Void) { self.title = title; self.onComplete = onComplete }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String ?? title
        }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { onComplete() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { onComplete() }
    }
}
#elseif os(macOS)
import AppKit
import CloudKit

/// Presents the native macOS CloudKit sharing service for an already-saved household share.
enum CloudSharingPresenter {
    @MainActor private static var activeSessions: [MacCloudSharingSession] = []

    @MainActor
    static func present(share: CKShare, container: CKContainer, title: String, onComplete: @escaping () -> Void = {}) {
        _ = title // The saved CKShare already carries its title.
        guard let service = NSSharingService(named: .cloudSharing) else {
            presentError("iCloud sharing is unavailable on this Mac.")
            return
        }

        let itemProvider = NSItemProvider()
        let options = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: .readWrite,
            allowedParticipantAccessOptions: .specifiedRecipientsOnly
        )
        itemProvider.registerCKShare(share, container: container, allowedSharingOptions: options)

        let session = MacCloudSharingSession(service: service, itemProvider: itemProvider, onComplete: onComplete)
        service.delegate = session
        activeSessions.append(session)
        service.perform(withItems: [itemProvider])
    }

    @MainActor fileprivate static func release(_ session: MacCloudSharingSession) {
        activeSessions.removeAll { $0 === session }
    }

    @MainActor fileprivate static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t share garden"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@MainActor
private final class MacCloudSharingSession: NSObject, NSCloudSharingServiceDelegate {
    let service: NSSharingService
    let itemProvider: NSItemProvider
    private let onComplete: () -> Void
    private var didFinish = false
    private var didNotifyCompletion = false

    init(service: NSSharingService, itemProvider: NSItemProvider, onComplete: @escaping () -> Void) {
        self.service = service
        self.itemProvider = itemProvider
        self.onComplete = onComplete
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        Task { @MainActor [weak self] in self?.notifyCompletion() }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        Task { @MainActor [weak self] in self?.notifyCompletion() }
    }

    nonisolated func options(for sharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadWrite]
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finish(error: error)
        }
    }

    @MainActor
    private func notifyCompletion() {
        guard !didFinish, !didNotifyCompletion else { return }
        didNotifyCompletion = true
        onComplete()
    }

    @MainActor
    private func finish(error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        if let error {
            CloudSharingPresenter.presentError(error.localizedDescription)
        }
        CloudSharingPresenter.release(self)
    }
}
#endif
