import Accelerate
import CoreVideo
import Foundation
import ZoomVideoSDK

/// Zoom external video source fed by Nosmai's processed camera frames.
/// Nosmai owns the camera; Zoom never opens it.
///
/// Zoom takes raw I420 frames and centre-crops portrait input, so each Nosmai
/// frame (a portrait BGRA or NV12 `CVPixelBuffer`) is:
///   1. scaled to the size Zoom asked for,
///   2. turned 90° into a landscape frame, sent with a rotation flag so Zoom
///      turns it back upright for viewers,
///   3. converted to I420.
/// At most one frame is converted at a time; a busy converter drops the newest frame.
final class NosmaiZoomVideoSource: NSObject, ZoomVideoSDKVideoSource {
    /// Called on the main queue when Zoom starts or stops asking for frames.
    var onSendingChanged: ((Bool) -> Void)?
    /// Called on a background queue after each frame handed to Zoom.
    var onFrameSent: (() -> Void)?

    private let lock = NSLock()
    private var sender: ZoomVideoSDKVideoSender?
    private var sending = false
    /// Long side (pixels) of the resolution Zoom currently wants; 0 until Zoom says.
    private var suggestedLongSide = 0

    private let convertQueue = DispatchQueue(label: "com.nosmai.zoom.demo.convert")
    private let inFlight = DispatchSemaphore(value: 1)

    // Reusable buffers, touched only on convertQueue.
    private let nv12Scratch = Scratch()
    private let scaleScratch = Scratch()
    private let rotateScratch = Scratch()
    private let i420Ring = [Scratch(), Scratch(), Scratch()]
    private var ringIndex = 0

    // MARK: - ZoomVideoSDKVideoSource (called by Zoom)

    func onInitialize(_ rawDataSender: ZoomVideoSDKVideoSender,
                      supportCapabilityArray: [Any],
                      suggest suggestCapability: ZoomVideoSDKVideoCapability) {
        lock.lock()
        sender = rawDataSender
        suggestedLongSide = Int(max(suggestCapability.width, suggestCapability.height))
        lock.unlock()
    }

    func onPropertyChange(_ supportCapabilityArray: [Any], suggest suggestCapability: ZoomVideoSDKVideoCapability) {
        lock.lock()
        suggestedLongSide = Int(max(suggestCapability.width, suggestCapability.height))
        lock.unlock()
    }

    /// Zoom is ready for frames: start taking them from Nosmai.
    func onStartSend() {
        lock.lock()
        let wasSending = sending
        sending = true
        lock.unlock()
        guard !wasSending else { return }
        NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, _ in
            self?.handle(pixelBuffer)
        }
        notify(sending: true)
    }

    func onStopSend() {
        lock.lock()
        let wasSending = sending
        sending = false
        lock.unlock()
        guard wasSending else { return }
        NosmaiCore.shared().liveFrameStreamCallback = nil
        notify(sending: false)
    }

    func onUninitialized() {
        onStopSend()
        lock.lock()
        sender = nil
        lock.unlock()
    }

    /// Detaches from Nosmai and waits for the frame being converted. Safe to call repeatedly.
    func shutdown() {
        lock.lock()
        sending = false
        sender = nil
        lock.unlock()
        NosmaiCore.shared().liveFrameStreamCallback = nil
        convertQueue.sync {}
    }

    private func notify(sending: Bool) {
        DispatchQueue.main.async { self.onSendingChanged?(sending) }
    }

    // MARK: - Frames

    /// Nosmai's processing thread, once per processed frame. Never blocks.
    private func handle(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let active = sending && sender != nil
        lock.unlock()
        guard active, inFlight.wait(timeout: .now()) == .success else { return }
        // Swift retains the buffer for the lifetime of the closure below.
        convertQueue.async {
            self.convertAndSend(pixelBuffer)
            self.inFlight.signal()
        }
    }

    private func convertAndSend(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let sender = sending ? self.sender : nil
        let longSide = suggestedLongSide
        lock.unlock()
        guard let sender else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let frame = makeI420(from: pixelBuffer, targetLongSide: longSide)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        guard let frame else { return }

        sender.sendVideoFrame(frame.data,
                              width: UInt(frame.width),
                              height: UInt(frame.height),
                              dataLength: UInt(frame.width * frame.height * 3 / 2),
                              rotation: frame.rotated ? .rotation90 : .rotationNone)
        onFrameSent?()
    }

    private struct I420Frame {
        let data: UnsafeMutablePointer<CChar>
        let width: Int
        let height: Int
        /// The frame was turned to landscape and needs the rotation flag.
        let rotated: Bool
    }

    /// Returns a landscape I420 frame (even sizes), or nil if the buffer cannot be converted.
    private func makeI420(from pixelBuffer: CVPixelBuffer, targetLongSide: Int) -> I420Frame? {
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth >= 2, srcHeight >= 2 else { return nil }
        let noFlags = vImage_Flags(kvImageNoFlags)

        // 1. A BGRA view of the frame.
        var bgra: vImage_Buffer
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            bgra = vImage_Buffer(data: base, height: vImagePixelCount(srcHeight), width: vImagePixelCount(srcWidth),
                                 rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
                  let scratch = nv12Scratch.take(srcWidth * srcHeight * 4) else { return nil }
            var luma = vImage_Buffer(data: lumaBase, height: vImagePixelCount(srcHeight), width: vImagePixelCount(srcWidth),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
            var chroma = vImage_Buffer(data: chromaBase, height: vImagePixelCount(srcHeight / 2),
                                       width: vImagePixelCount(srcWidth / 2),
                                       rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
            bgra = vImage_Buffer(data: scratch, height: vImagePixelCount(srcHeight), width: vImagePixelCount(srcWidth),
                                 rowBytes: srcWidth * 4)
            var conversion = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ? Self.fullRangeToRGB : Self.videoRangeToRGB
            let toBGRA: [UInt8] = [3, 2, 1, 0]
            guard vImageConvert_420Yp8_CbCr8ToARGB8888(&luma, &chroma, &bgra, &conversion, toBGRA, 255, noFlags)
                    == kvImageNoError else { return nil }
        default:
            return nil
        }

        // 2. Scale to the size Zoom asked for (Zoom centre-crops frames of any other size).
        let portrait = srcHeight > srcWidth
        let srcLong = max(srcWidth, srcHeight)
        let srcShort = min(srcWidth, srcHeight)
        let dstLong = Self.even(targetLongSide >= 320 ? targetLongSide : srcLong)
        let dstShort = Self.even(Int((Double(dstLong) * Double(srcShort) / Double(srcLong)).rounded()))
        let scaledWidth = portrait ? dstShort : dstLong
        let scaledHeight = portrait ? dstLong : dstShort
        var scaled = bgra
        if scaledWidth != srcWidth || scaledHeight != srcHeight {
            guard let scratch = scaleScratch.take(scaledWidth * scaledHeight * 4) else { return nil }
            scaled = vImage_Buffer(data: scratch, height: vImagePixelCount(scaledHeight),
                                   width: vImagePixelCount(scaledWidth), rowBytes: scaledWidth * 4)
            guard vImageScale_ARGB8888(&bgra, &scaled, nil, noFlags) == kvImageNoError else { return nil }
        }

        // 3. Portrait goes out as landscape turned 90° counter-clockwise, plus a rotation flag.
        var upright = scaled
        if portrait {
            guard let scratch = rotateScratch.take(scaledWidth * scaledHeight * 4) else { return nil }
            upright = vImage_Buffer(data: scratch, height: vImagePixelCount(scaledWidth),
                                    width: vImagePixelCount(scaledHeight), rowBytes: scaledHeight * 4)
            let black: [UInt8] = [0, 0, 0, 255]
            guard vImageRotate90_ARGB8888(&scaled, &upright, UInt8(kRotate90DegreesCounterClockwise), black, noFlags)
                    == kvImageNoError else { return nil }
        }

        // 4. BGRA -> I420 (BT.601 limited range, Zoom's default external source format).
        let width = Int(upright.width)
        let height = Int(upright.height)
        let lumaSize = width * height
        let chromaSize = (width / 2) * (height / 2)
        guard let out = i420Ring[ringIndex].take(lumaSize + 2 * chromaSize) else { return nil }
        ringIndex = (ringIndex + 1) % i420Ring.count
        var yPlane = vImage_Buffer(data: out, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: width)
        var uPlane = vImage_Buffer(data: out + lumaSize, height: vImagePixelCount(height / 2),
                                   width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var vPlane = vImage_Buffer(data: out + lumaSize + chromaSize, height: vImagePixelCount(height / 2),
                                   width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var conversion = Self.rgbToVideoRange
        let fromBGRA: [UInt8] = [3, 2, 1, 0]
        guard vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&upright, &yPlane, &uPlane, &vPlane, &conversion, fromBGRA, noFlags)
                == kvImageNoError else { return nil }

        return I420Frame(data: out.assumingMemoryBound(to: CChar.self), width: width, height: height, rotated: portrait)
    }

    private static func even(_ value: Int) -> Int { max(2, value & ~1) }

    // MARK: - Colour conversion tables (BT.601)

    private static var videoRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
    private static var fullRange = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                                           YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)

    private static let rgbToVideoRange: vImage_ARGBToYpCbCr = {
        var info = vImage_ARGBToYpCbCr()
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &videoRange, &info,
                                                      kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags))
        return info
    }()

    private static let videoRangeToRGB: vImage_YpCbCrToARGB = makeToRGB(&videoRange)
    private static let fullRangeToRGB: vImage_YpCbCrToARGB = makeToRGB(&fullRange)

    private static func makeToRGB(_ range: inout vImage_YpCbCrPixelRange) -> vImage_YpCbCrToARGB {
        var info = vImage_YpCbCrToARGB()
        vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info,
                                                      kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        return info
    }
}

/// A reusable byte buffer that grows when a bigger frame arrives.
private final class Scratch {
    private var data: UnsafeMutableRawPointer?
    private var capacity = 0

    func take(_ bytes: Int) -> UnsafeMutableRawPointer? {
        if capacity < bytes {
            free(data)
            data = malloc(bytes)
            capacity = data == nil ? 0 : bytes
        }
        return data
    }

    deinit { free(data) }
}
