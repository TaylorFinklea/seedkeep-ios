// Live camera capture (AVFoundation) is iPhone and iPad only; macOS never compiles this file.
#if os(iOS)
import SwiftUI
import AVFoundation

/// SwiftUI wrapper around `AVCaptureSession` for explicit photo capture. Scanning starts at the
/// packet's front and back (N2), so there is no barcode detection.
///
/// `onPhotoCaptured` fires after `capture` is set to `.takePhoto(token)`, returning JPEG bytes that
/// the scan flow stages, with the token of the capture they answer. A capture error carries its
/// token too; a camera setup error has none.
struct CameraView: UIViewControllerRepresentable {
    let onPhotoCaptured: (Data, CaptureToken) -> Void
    let onError: (CameraError, CaptureToken?) -> Void
    @Binding var capture: CaptureCommand

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        if case .takePhoto(let token) = capture {
            uiViewController.snapPhoto(token)
            // Reset so the next `.takePhoto` flip retriggers.
            DispatchQueue.main.async { capture = .idle }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, CameraViewControllerDelegate {
        let parent: CameraView
        init(parent: CameraView) { self.parent = parent }

        func cameraViewController(_ vc: CameraViewController, didCapturePhoto data: Data, token: CaptureToken) {
            parent.onPhotoCaptured(data, token)
        }
        func cameraViewController(_ vc: CameraViewController, didEncounter error: CameraError, token: CaptureToken?) {
            parent.onError(error, token)
        }
    }
}

enum CaptureCommand: Equatable {
    case idle
    case takePhoto(CaptureToken)
}

enum CameraError: Error, LocalizedError {
    case unauthorized
    case unavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Camera access denied. Enable it in Settings."
        case .unavailable: return "No camera available on this device."
        case .captureFailed(let m): return "Capture failed: \(m)"
        }
    }
}

@MainActor
protocol CameraViewControllerDelegate: AnyObject {
    func cameraViewController(_ vc: CameraViewController, didCapturePhoto data: Data, token: CaptureToken)
    func cameraViewController(_ vc: CameraViewController, didEncounter error: CameraError, token: CaptureToken?)
}

final class CameraViewController: UIViewController {
    weak var delegate: CameraViewControllerDelegate?

    /// Started and stopped on a background queue, which AVFoundation documents as safe.
    nonisolated(unsafe) private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// Each in-flight capture's token, by its settings ID, so a late photo answers its own request.
    private var tokensBySettingsID: [Int64: CaptureToken] = [:]
    /// The last token snapped. SwiftUI can update the view again before the command resets, and
    /// that must not take a second photo.
    private var lastSnappedToken: CaptureToken?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func snapPhoto(_ token: CaptureToken) {
        guard token != lastSnappedToken else { return }
        lastSnappedToken = token
        guard session.isRunning else {
            delegate?.cameraViewController(self, didEncounter: .captureFailed("session not running"), token: token)
            return
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        tokensBySettingsID[settings.uniqueID] = token
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            attachInputsAndOutputs()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    DispatchQueue.main.async { self.attachInputsAndOutputs() }
                } else {
                    DispatchQueue.main.async { self.delegate?.cameraViewController(self, didEncounter: .unauthorized, token: nil) }
                }
            }
        default:
            delegate?.cameraViewController(self, didEncounter: .unauthorized, token: nil)
        }
    }

    private func attachInputsAndOutputs() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            delegate?.cameraViewController(self, didEncounter: .unavailable, token: nil)
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // No explicit maxPhotoDimensions — the value MUST come from the
            // device's activeFormat.supportedMaxPhotoDimensions list, and
            // any other value raises an uncatchable NSException at config
            // time. Defaults give the largest the format supports, which is
            // already past what AI extraction needs.
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }
}

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let captured: Result<Data, CameraError>
        if let error {
            captured = .failure(.captureFailed(error.localizedDescription))
        } else if let data = photo.fileDataRepresentation() {
            captured = .success(data)
        } else {
            captured = .failure(.captureFailed("no data"))
        }
        let settingsID = photo.resolvedSettings.uniqueID
        Task { @MainActor [weak self] in
            guard let self, let token = self.tokensBySettingsID.removeValue(forKey: settingsID) else { return }
            switch captured {
            case .success(let data):
                self.delegate?.cameraViewController(self, didCapturePhoto: data, token: token)
            case .failure(let err):
                self.delegate?.cameraViewController(self, didEncounter: err, token: token)
            }
        }
    }
}

#endif
