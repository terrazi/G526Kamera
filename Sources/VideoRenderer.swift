import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo

/// Çözülen kareleri ekrandaki AVSampleBufferDisplayLayer'a gönderir (herhangi bir iş parçacığından).
final class VideoRenderer {
    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let target = layer
        lock.unlock()
        guard let layer = target else { return }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let description = format else { return }

        var timing = CMSampleTimingInfo(duration: CMTime.invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: CMTime.invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: pixelBuffer,
                                                              formatDescription: description,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard status == noErr, let buffer = sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if layer.status == .failed { layer.flush() }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(buffer)
        }
    }
}

/// Kare katmanı alt katman olarak durur: görüntü yönü yalnız bu katmanın dönüşümüyle uygulanır (kare başına iş yok).
/// Dik çevrilince katmanın sınırları en/boy yer değiştirir; çevrilmiş resim görünümün içine sığdırılır.
final class DisplayView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    var orientation: ImageOrientation = .normal {
        didSet {
            if orientation != oldValue { setNeedsLayout() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) kullanılmıyor")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        displayLayer.transform = CATransform3DIdentity
        displayLayer.bounds = orientation.isQuarterTurn
            ? CGRect(x: 0, y: 0, width: b.height, height: b.width)
            : CGRect(x: 0, y: 0, width: b.width, height: b.height)
        displayLayer.position = CGPoint(x: b.midX, y: b.midY)
        if orientation != .normal {
            displayLayer.transform = CATransform3DMakeRotation(orientation.angle, 0, 0, 1)
        }
        CATransaction.commit()
    }
}

struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer
    var orientation: ImageOrientation = .normal

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.orientation = orientation
        renderer.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        uiView.orientation = orientation
    }
}
