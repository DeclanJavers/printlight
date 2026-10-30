import AVFoundation
import CoreImage
import UIKit

/// Which kind of RAW the current lens can give us.
enum RawMode: Equatable {
    /// Apple ProRAW: multi-frame merged, demosaiced, linear. We discard Apple's
    /// rendering (tone map, boost, sharpening) at develop time but keep the noise benefit.
    case proRAW
    /// Single-frame Bayer RAW: the purest readout, noisier. Used on non-Pro phones.
    case bayer
    case unavailable

    var label: String {
        switch self {
        case .proRAW: "ProRAW"
        case .bayer: "RAW"
        case .unavailable: "No RAW"
        }
    }
}

struct Lens: Identifiable, Equatable {
    let id: String
    let label: String
    let device: AVCaptureDevice
}

/// Owns the capture session. All session work happens on `sessionQueue`;
/// published state is only ever touched on the main thread.
final class CameraController: NSObject, ObservableObject {
    enum Status: Equatable { case starting, running, denied, failed(String) }

    @Published private(set) var status: Status = .starting
    @Published private(set) var rawMode: RawMode = .unavailable
    @Published private(set) var megapixels: Int = 0
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var currentLensID: String?
    @Published private(set) var isCapturing = false
    @Published var exposureBias: Float = 0 {
        didSet { applyExposureBias(exposureBias) }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "printlight.session")
    private let videoQueue = DispatchQueue(label: "printlight.video", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    /// Session-queue only. `start()` is called on appear and on every return to foreground.
    private var isConfigured = false

    /// Receives every preview frame on the video queue.
    var onPreviewFrame: (@Sendable (CIImage) -> Void)?
    /// Called on the main thread with the DNG bytes of each capture.
    var onRawCaptured: ((Data) -> Void)?
    /// Called on the main thread when a capture fails.
    var onCaptureError: ((String) -> Void)?

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureAndRun() }
                } else {
                    self.publish { $0.status = .denied }
                }
            }
        default:
            publish { $0.status = .denied }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndRun() {
        if isConfigured {
            if !session.isRunning { session.startRunning() }
            return
        }

        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices
        guard let wide = discovered.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? discovered.first else {
            publish { $0.status = .failed("No back camera found.") }
            return
        }
        let lenses = discovered.map { Lens(id: $0.uniqueID, label: Self.zoomLabel(for: $0, relativeTo: wide), device: $0) }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            publish { $0.status = .failed("Could not configure camera outputs.") }
            return
        }
        session.addOutput(photoOutput)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)

        let ok = attach(device: wide)
        session.commitConfiguration()

        guard ok else {
            publish { $0.status = .failed("Could not open the camera.") }
            return
        }
        isConfigured = true
        session.startRunning()
        publish {
            $0.lenses = lenses
            $0.status = .running
        }
    }

    /// Must be called inside begin/commitConfiguration on the session queue.
    @discardableResult
    private func attach(device: AVCaptureDevice) -> Bool {
        if let input { session.removeInput(input) }
        guard let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            return false
        }
        session.addInput(newInput)
        input = newInput

        // Largest stills the sensor can give (48MP on Pro main cameras, ProRAW only).
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported

        // UI is locked to portrait, so preview frames are always rotated upright.
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

        let mode = currentRawMode()
        let dims = photoOutput.maxPhotoDimensions
        let mp = mode == .proRAW ? Int((Double(dims.width) * Double(dims.height) / 1_000_000).rounded()) : 12
        publish {
            $0.rawMode = mode
            $0.megapixels = mp
            $0.currentLensID = device.uniqueID
            $0.exposureBias = 0
        }
        return true
    }

    func select(lens: Lens) {
        guard lens.id != currentLensID else { return }
        sessionQueue.async {
            self.session.beginConfiguration()
            self.attach(device: lens.device)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Controls

    private func applyExposureBias(_ bias: Float) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// `point` is in normalized coordinates of the upright (portrait) preview image, origin top-left.
    func focus(at point: CGPoint) {
        // Device coordinates are in the sensor's native landscape orientation.
        let devicePoint = CGPoint(x: point.y, y: 1 - point.x)
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Capture

    private func currentRawMode() -> RawMode {
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        if photoOutput.isAppleProRAWEnabled, formats.contains(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return .proRAW
        }
        if formats.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
            return .bayer
        }
        return .unavailable
    }

    func capture() {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        publish { $0.isCapturing = true }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let mode = self.currentRawMode()
            let formats = self.photoOutput.availableRawPhotoPixelFormatTypes
            let rawFormat: OSType? = switch mode {
            case .proRAW: formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
            case .bayer: formats.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
            case .unavailable: nil
            }
            guard let rawFormat else {
                self.publish {
                    $0.isCapturing = false
                    $0.onCaptureError?("This camera doesn't offer RAW capture.")
                }
                return
            }

            // RAW only: no processed companion image, we develop it ourselves.
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            if mode == .proRAW {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .quality
            } else {
                settings.photoQualityPrioritization = .speed
            }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { self.inFlight[id] = nil }
                self.publish {
                    $0.isCapturing = false
                    switch result {
                    case .success(let dng): $0.onRawCaptured?(dng)
                    case .failure(let error): $0.onCaptureError?(error.localizedDescription)
                    }
                }
            }
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    // MARK: - Helpers

    private func publish(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { update(self) }
    }

    private static func zoomLabel(for device: AVCaptureDevice, relativeTo wide: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5"
        case .builtInWideAngleCamera: return "1"
        default:
            // Ratio of horizontal fields of view gives the optical magnification.
            let w = tan(Double(wide.activeFormat.videoFieldOfView) * .pi / 360)
            let t = tan(Double(device.activeFormat.videoFieldOfView) * .pi / 360)
            guard t > 0 else { return "T" }
            return String(format: "%.0f", (w / t).rounded())
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPreviewFrame?(CIImage(cvPixelBuffer: pixelBuffer))
    }
}
