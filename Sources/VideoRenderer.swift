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

    /// true: görünüm dikey sayfa kadrajıdır; kare görünümü boyuna ya da enine doldurur, kadrajın dışı kırpılır (yalnız ekranda;
    /// çekilen fotoğraf kırpılmaz). Kırpılan bölüm `PageFrame.verticalPage` ile aynıdır.
    var cropToPage = false {
        didSet {
            if cropToPage != oldValue { setNeedsLayout() }
        }
    }

    /// Katmanın (çevrilmemiş) boyutu. Kırpmada: sayfa görünümü doldurur, kare ortada kalır, taşan kısım kırpılır.
    static func layerSize(in view: CGSize, orientation: ImageOrientation, cropToPage: Bool,
                          aspect: CGFloat = 16.0 / 9.0) -> CGSize {
        if cropToPage {
            // normal/180°: sayfa görünümün boyunu, 90°: eni doldurur (çevrilmemiş katmanın yüksekliği = görünümün eni)
            let h = orientation.isQuarterTurn ? view.width : view.height
            return CGSize(width: h * aspect, height: h)
        }
        return orientation.isQuarterTurn ? CGSize(width: view.height, height: view.width) : view
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
        let size = DisplayView.layerSize(in: b.size, orientation: orientation, cropToPage: cropToPage)
        displayLayer.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
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
    var cropToPage = false

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.orientation = orientation
        view.cropToPage = cropToPage
        renderer.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        uiView.orientation = orientation
        uiView.cropToPage = cropToPage
    }
}
