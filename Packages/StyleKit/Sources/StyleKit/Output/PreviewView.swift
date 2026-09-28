import AppKit
import AVFoundation
import SwiftUI

/// A FrameOutput that shows frames in an AVSampleBufferDisplayLayer. Add it to the pipeline, then host its layer
/// with `PreviewView` or `StylePreview`.
public final class PreviewOutput: FrameOutput, @unchecked Sendable {
    @MainActor public let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "StyleKit.PreviewOutput", qos: .userInteractive)
    private var isCleared = false

    @MainActor public init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
    }

    public func publish(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let sample = Self.sampleBuffer(pixelBuffer, time: time) else { return }
        let box = UncheckedBox(sample)
        queue.async { [self] in
            guard !isCleared else { return }
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
            renderer.enqueue(box.value)
        }
    }

    /// Removes the frame on screen and ignores frames published after it, including frames still in the pipeline,
    /// until `resume()`.
    public func clear() {
        queue.async { [self] in
            isCleared = true
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    public func resume() {
        queue.async { [self] in isCleared = false }
    }

    private static func sampleBuffer(_ imageBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: imageBuffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: imageBuffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
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
