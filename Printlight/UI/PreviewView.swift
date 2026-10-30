import CoreImage
import MetalKit
import SwiftUI

/// Draws the newest camera frame through the look into an MTKView.
/// Frames arrive on the video queue and drawing happens on main; shared state is behind `lock`.
final class PreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private let lock = NSLock()
    private var latestFrame: CIImage?
    /// Last image drawn to the screen, look included: the instant thumbnail at capture.
    private var lastDrawn: CIImage?
    private var frameCount: UInt64 = 0
    private var _params = LookParameters.standard
    private var _lookEnabled = true
    private var _zebras = true
    /// Size of the last frame after rotation, used to map taps to image coordinates.
    private(set) var frameSize: CGSize = .zero

    var params: LookParameters {
        get { lock.withLock { _params } }
        set { lock.withLock { _params = newValue } }
    }

    var zebras: Bool {
        get { lock.withLock { _zebras } }
        set { lock.withLock { _zebras = newValue } }
    }

    var lookEnabled: Bool {
        get { lock.withLock { _lookEnabled } }
        set { lock.withLock { _lookEnabled = newValue } }
    }

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
        super.init()
    }

    /// Called from the camera's video queue.
    func enqueue(_ frame: CIImage) {
        lock.withLock {
            latestFrame = frame
            frameCount &+= 1
        }
    }

    /// The newest camera frame as delivered (Apple-rendered, display-referred, upright).
    func currentFrame() -> CIImage? {
        lock.withLock { latestFrame }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let (frame, count, params, enabled, zebras) = lock.withLock {
            (latestFrame, frameCount, _params, _lookEnabled, _zebras)
        }
        guard let frame,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        frameSize = frame.extent.size

        // Aspect-fill into the drawable, downscaling first so the look runs at screen resolution.
        let target = view.drawableSize
        let scale = max(target.width / frame.extent.width, target.height / frame.extent.height)
        var image = frame
            .transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (image.extent.width - target.width) / 2
        let dy = (image.extent.height - target.height) / 2
        image = image
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: target))

        let cameraFrame = image
        if enabled {
            image = FilmLook.shared.renderPreview(displayReferred: image, params: params, frame: count)
        }

        lock.withLock { lastDrawn = image }
        if zebras {
            // Stripes crawl slowly so they read as an overlay, not part of the picture.
            image = FilmLook.shared.zebras(on: image, source: cameraFrame, phase: Float(count % 24) / 2)
        }

        let destination = CIRenderDestination(
            width: Int(target.width),
            height: Int(target.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        destination.colorSpace = colorSpace
        _ = try? context.startTask(toRender: image, to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// What the viewfinder shows right now, as a small image.
    func snapshot(maxDimension: CGFloat = 300) -> UIImage? {
        guard let image = lock.withLock({ lastDrawn }), image.extent.width > 0 else { return nil }
        let scale = min(maxDimension / max(image.extent.width, image.extent.height), 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Converts a point in the view to normalized coordinates of the upright camera frame.
    func normalizedFramePoint(for point: CGPoint, in viewSize: CGSize) -> CGPoint {
        guard frameSize.width > 0, viewSize.width > 0 else {
            return CGPoint(x: point.x / max(viewSize.width, 1), y: point.y / max(viewSize.height, 1))
        }
        let scale = max(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        let x = (point.x + (shown.width - viewSize.width) / 2) / shown.width
        let y = (point.y + (shown.height - viewSize.height) / 2) / shown.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

struct PreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.backgroundColor = .black
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
