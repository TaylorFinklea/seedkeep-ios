import SwiftUI
import AVFoundation

/// SwiftUI wrapper around `AVCaptureSession` with both barcode detection
/// (continuous) and explicit photo capture in the same session.
///
/// The parent controls behavior with two callbacks. `onBarcodeDetected`
/// fires every time the metadata output sees a recognized symbology; the
/// scan flow coordinator debounces / acts on it. `onPhotoCaptured` fires
/// after `capture.send(.takePhoto)` triggers a snapshot, returning JPEG
/// bytes ready to upload.
struct CameraView: UIViewControllerRepresentable {
    let onBarcodeDetected: (String) -> Void
    let onPhotoCaptured: (Data) -> Void
    let onError: (CameraError) -> Void
    @Binding var capture: CaptureCommand

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        if capture == .takePhoto {
            uiViewController.snapPhoto()
            // Reset so the next `.takePhoto` flip retriggers.
            DispatchQueue.main.async { capture = .idle }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, CameraViewControllerDelegate {
        let parent: CameraView
        init(parent: CameraView) { self.parent = parent }

        func cameraViewController(_ vc: CameraViewController, didDetectBarcode value: String) {
            parent.onBarcodeDetected(value)
        }
        func cameraViewController(_ vc: CameraViewController, didCapturePhoto data: Data) {
            parent.onPhotoCaptured(data)
        }
        func cameraViewController(_ vc: CameraViewController, didEncounter error: CameraError) {
            parent.onError(error)
        }
    }
}

enum CaptureCommand: Equatable {
    case idle
    case takePhoto
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

protocol CameraViewControllerDelegate: AnyObject {
    func cameraViewController(_ vc: CameraViewController, didDetectBarcode value: String)
    func cameraViewController(_ vc: CameraViewController, didCapturePhoto data: Data)
    func cameraViewController(_ vc: CameraViewController, didEncounter error: CameraError)
}

final class CameraViewController: UIViewController {
    weak var delegate: CameraViewControllerDelegate?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataQueue = DispatchQueue(label: "seedkeep.camera.metadata")
    private var lastBarcodeReportedAt: Date = .distantPast

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

    func snapPhoto() {
        guard session.isRunning else {
            delegate?.cameraViewController(self, didEncounter: .captureFailed("session not running"))
            return
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
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
                    self.delegate?.cameraViewController(self, didEncounter: .unauthorized)
                }
            }
        default:
            delegate?.cameraViewController(self, didEncounter: .unauthorized)
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
            delegate?.cameraViewController(self, didEncounter: .unavailable)
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
            // Common seed-packet symbologies. UPC-A and EAN-13 dominate;
            // Code 128 and QR are occasional. List from broad to narrow.
            metadataOutput.metadataObjectTypes = [
                .ean13, .ean8, .upce, .code128, .code39, .code93, .qr,
            ]
        }

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

extension CameraViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Pull out the first machine-readable string outside the actor;
        // bounce to MainActor for the debounce + delegate hop.
        var firstValue: String?
        for obj in metadataObjects {
            if let readable = obj as? AVMetadataMachineReadableCodeObject,
               let value = readable.stringValue {
                firstValue = value
                break
            }
        }
        guard let value = firstValue else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastBarcodeReportedAt) < 1.5 { return }
            self.lastBarcodeReportedAt = now
            self.delegate?.cameraViewController(self, didDetectBarcode: value)
        }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch captured {
            case .success(let data):
                self.delegate?.cameraViewController(self, didCapturePhoto: data)
            case .failure(let err):
                self.delegate?.cameraViewController(self, didEncounter: err)
            }
        }
    }
}
