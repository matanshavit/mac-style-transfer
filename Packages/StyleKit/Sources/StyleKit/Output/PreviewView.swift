import AppKit
import AVFoundation
import SwiftUI

/// A FrameOutput that shows frames in an AVSampleBufferDisplayLayer. Add it to the pipeline, then host its layer
/// with `PreviewView` or `StylePreview`.
public final class PreviewOutput: FrameOutput, @unchecked Sendable {
    @MainActor public let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "StyleKit.PreviewOutput", qos: .userInteractive)

    @MainActor public init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
    }

    public func publish(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let sample = CMSampleBuffer.make(imageBuffer: pixelBuffer, time: time, displayImmediately: true) else { return }
        let box = UncheckedBox(sample)
        queue.async { [self] in
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
            renderer.enqueue(box.value)
        }
    }

    public func clear() {
        queue.async { [self] in renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    }
}

/// Hosts a PreviewOutput's layer; mirroring is a layer transform, the frames themselves are not flipped.
public final class PreviewView: NSView {
    public let output: PreviewOutput

    public var isMirrored: Bool {
        didSet { updateTransform() }
    }

    public init(output: PreviewOutput, mirrored: Bool = false) {
        self.output = output
        isMirrored = mirrored
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(output.displayLayer)
        updateTransform()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        output.displayLayer.bounds = bounds
        output.displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func updateTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        output.displayLayer.setAffineTransform(isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }
}

public struct StylePreview: NSViewRepresentable {
    public let output: PreviewOutput
    public var mirrored: Bool

    public init(output: PreviewOutput, mirrored: Bool = false) {
        self.output = output
        self.mirrored = mirrored
    }

    public func makeNSView(context: Context) -> PreviewView {
        PreviewView(output: output, mirrored: mirrored)
    }

    public func updateNSView(_ view: PreviewView, context: Context) {
        view.isMirrored = mirrored
    }
}
