// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics
import CryptoKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox
import Vision

/// Only the explicit menu action may prompt. Background reads never request access.
enum AlbumScreenCapturePermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// Reads Lightroom's search tokens when its accessibility tree omits their text.
/// Images stay in memory: no files, full-screen capture, or previous-frame fallback.
final class AlbumTokenReader {
    private let cacheLock = NSLock()
    private var lastRecognition: (key: RecognitionKey, texts: [String])?
    private var lastSidebarRecognition: (key: RecognitionKey, name: String?)?

    /// The caller supplies only the visible album-list text column, excluding thumbnails.
    /// A complete, uniquely dark selection band is required; ordinary rows are never read.
    func readSelectedAlbum(rect: CGRect, processID: pid_t, windowFrame: CGRect) -> String? {
        guard !Thread.isMainThread, AlbumScreenCapturePermission.isGranted,
              Self.isValidSidebarRect(rect, in: windowFrame),
              let windowID = Self.windowID(processID: processID, frame: windowFrame),
              let image = captureTokens(rect: rect, processID: processID, windowID: windowID, windowFrame: windowFrame),
              Self.windowID(processID: processID, frame: windowFrame) == windowID else { return nil }
        let key = recognitionKey(image: image, rect: rect, processID: processID,
                                 windowID: windowID, windowFrame: windowFrame)
        if let key {
            cacheLock.lock()
            let cached = lastSidebarRecognition
            cacheLock.unlock()
            if let cached, cached.key == key { return cached.name }
        }
        let name = Self.selectedSidebarRow(in: image, pointHeight: rect.height).flatMap { row -> String? in
            guard let crop = image.cropping(to: row) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                // Preserve the first observation even if unreadable. A later count/name
                // must never replace it. The album title starts at the text column's left.
                guard let first = request.results?.min(by: { $0.boundingBox.minX < $1.boundingBox.minX }),
                      first.boundingBox.minX < 0.15,
                      let candidate = first.topCandidates(1).first, candidate.confidence >= 0.85 else { return nil }
                var text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                // Vision may merge the right-aligned photo count with the album title.
                // Strip it only when its own character box is in that far-right column.
                if let range = text.range(of: #"\s+\d+[’',]?\d*$"#, options: .regularExpression),
                   let countBox = try? candidate.boundingBox(for: range), countBox.boundingBox.minX > 0.82 {
                    text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return text.isEmpty ? nil : text
            } catch { return nil }
        }
        if let key {
            cacheLock.lock()
            lastSidebarRecognition = (key, name)
            cacheLock.unlock()
        }
        return name
    }

    /// Detect the selected-row background, independent of the text it contains. The
    /// unselected Lightroom sidebar is neutral gray; selection is a darker full band.
    /// Partial/clipped bands, multiple bands, or unfamiliar themes fail closed.
    static func selectedSidebarRow(in image: CGImage, pointHeight: CGFloat) -> CGRect? {
        let width = image.width, height = image.height
        guard width >= 32, height >= 32, pointHeight > 0 else { return nil }
        let scale = CGFloat(height) / pointHeight
        guard scale >= 0.9, scale <= 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The text column begins with a narrow empty inset. Sampling only that inset
        // avoids text/count glyphs and never considers a dark thumbnail a selection.
        let columns = [max(1, Int(scale)), max(2, Int(2 * scale)), max(3, Int(3 * scale))]
        var shades = [Int](repeating: -1, count: height)
        var histogram = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            var samples: [Int] = []
            for x in columns where x < width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if pixels[i + 3] >= 250, max(r, g, b) - min(r, g, b) <= 4 {
                    samples.append((r + g + b) / 3)
                }
            }
            if samples.count == columns.count, let shade = samples.min(), samples.max()! - shade <= 3 {
                shades[y] = shade
                histogram[shade] += 1
            }
        }
        guard let background = (24...100).max(by: { histogram[$0] < histogram[$1] }),
              histogram[background] > height / 5 else { return nil }
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0...height {
            let isDark = y < height && shades[y] >= 12 && shades[y] <= background - 7
            if isDark && start == nil { start = y }
            if !isDark, let begin = start { bands.append(begin..<y); start = nil }
        }
        let margin = max(2, Int(3 * scale))
        let rows = bands.filter { band in
            let points = CGFloat(band.count) / scale
            return points >= 28 && points <= 62 && band.lowerBound >= margin && band.upperBound + margin < height &&
                abs(shades[band.lowerBound - margin] - background) <= 3 &&
                abs(shades[band.upperBound + margin] - background) <= 3
        }
        guard rows.count == 1, let row = rows.first else { return nil }
        return CGRect(x: 0, y: row.lowerBound, width: width, height: row.count)
    }

    /// Coordinates use the accessibility/Quartz screen coordinate system (top-left origin).
    /// Call from the reader queue, never the main thread. Nil means capture/recognition failed;
    /// an empty array means the current image contained no sufficiently confident text.
    func read(rect: CGRect, processID: pid_t, windowFrame: CGRect) -> [String]? {
        guard !Thread.isMainThread, AlbumScreenCapturePermission.isGranted,
              Self.isValidTokenRect(rect, in: windowFrame),
              let windowID = Self.windowID(processID: processID, frame: windowFrame) else { return nil }

        let image = captureTokens(rect: rect, processID: processID, windowID: windowID, windowFrame: windowFrame)
        guard let image, image.width > 0, image.height > 0,
              Self.windowID(processID: processID, frame: windowFrame) == windowID else { return nil }

        // Capture first on every read. A cached OCR result is usable only if the current
        // pixels and the complete capture identity match; a timeout never reuses old text.
        let key = recognitionKey(image: image, rect: rect, processID: processID,
                                 windowID: windowID, windowFrame: windowFrame)
        if let key {
            cacheLock.lock()
            let cached = lastRecognition.flatMap { $0.key == key ? $0.texts : nil }
            cacheLock.unlock()
            if let cached { return cached }
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let texts: [String] = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.map { observation in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= 0.85 else { return "" }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                return text
            }
            if let key {
                cacheLock.lock()
                lastRecognition = (key, texts)
                cacheLock.unlock()
            }
            return texts
        } catch { return nil }
    }

    private struct RecognitionKey: Equatable {
        let processID: pid_t
        let windowID: CGWindowID
        let rect: CGRect
        let windowFrame: CGRect
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bitsPerPixel: Int
        let bitmapInfo: UInt32
        let colorSpace: String?
        let digest: SHA256.Digest
    }

    private func recognitionKey(image: CGImage, rect: CGRect, processID: pid_t,
                                windowID: CGWindowID, windowFrame: CGRect) -> RecognitionKey? {
        guard let bytes = image.dataProvider?.data else { return nil }
        return RecognitionKey(processID: processID, windowID: windowID, rect: rect,
            windowFrame: windowFrame, width: image.width, height: image.height,
            bytesPerRow: image.bytesPerRow, bitsPerPixel: image.bitsPerPixel,
            bitmapInfo: image.bitmapInfo.rawValue, colorSpace: image.colorSpace?.name as String?,
            digest: SHA256.hash(data: bytes as Data))
    }

    private static func isValidTokenRect(_ rect: CGRect, in frame: CGRect) -> Bool {
        let values = [rect.minX, rect.minY, rect.width, rect.height,
                      frame.minX, frame.minY, frame.width, frame.height]
        return values.allSatisfy(\.isFinite) && !rect.isEmpty && !frame.isEmpty &&
            frame.contains(rect) && rect.height <= 80 && rect.maxY <= frame.minY + 100
    }

    private static func isValidSidebarRect(_ rect: CGRect, in frame: CGRect) -> Bool {
        let values = [rect.minX, rect.minY, rect.width, rect.height,
                      frame.minX, frame.minY, frame.width, frame.height]
        return values.allSatisfy(\.isFinite) && !rect.isEmpty && !frame.isEmpty &&
            frame.contains(rect) && rect.width <= 320 && rect.maxX <= frame.minX + 320 &&
            rect.minY >= frame.minY + 40
    }

    private static func sameFrame(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
            abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }

    /// A same-process floating panel, inspector, or second Lightroom window is not sufficient.
    private static func windowID(processID: pid_t, frame: CGRect) -> CGWindowID? {
        guard processID > 0,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches = windows.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let currentFrame = CGRect(dictionaryRepresentation: bounds),
                  sameFrame(currentFrame, frame),
                  let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return number.uint32Value
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func captureTokens(rect: CGRect, processID: pid_t, windowID: CGWindowID,
                               windowFrame: CGRect) -> CGImage? {
        let result = CaptureResult()
        let deadline = DispatchTime.now() + .milliseconds(800)
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            guard error == nil, DispatchTime.now() < deadline,
                  let windows = content?.windows else { result.finish(nil); return }
            let matches = windows.filter {
                $0.windowID == windowID && $0.owningApplication?.processID == processID &&
                    $0.windowLayer == 0 && Self.sameFrame($0.frame, windowFrame)
            }
            guard matches.count == 1 else { result.finish(nil); return }
            let window = matches[0]
            let crop = rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            guard CGRect(origin: .zero, size: window.frame.size).contains(crop) else {
                result.finish(nil); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = crop
            let scale: CGFloat
            if #available(macOS 14.0, *) { scale = CGFloat(filter.pointPixelScale) }
            else { scale = 2 }
            guard scale.isFinite, scale > 0, scale <= 4 else { result.finish(nil); return }
            configuration.width = Int(ceil(crop.width * scale))
            configuration.height = Int(ceil(crop.height * scale))
            configuration.showsCursor = false
            configuration.scalesToFit = false
            if #available(macOS 14.0, *) {
                configuration.ignoreShadowsSingleWindow = true
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    result.finish(error == nil ? image : nil)
                }
            } else {
                result.captureFirstFrame(filter: filter, configuration: configuration)
            }
        }
        return result.wait(until: deadline)
    }
}

/// Synchronizes capture callbacks without sharing or retaining an image across reads.
private final class CaptureResult: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var image: CGImage?
    private var expired = false
    private var finished = false
    private var stream: SCStream?
    private var output: OneFrameOutput?

    func finish(_ value: CGImage?) {
        lock.lock()
        guard !expired, !finished else { lock.unlock(); return }
        image = value
        finished = true
        lock.unlock()
        semaphore.signal()
    }

    /// macOS 13 has no screenshot manager. Stop its cropped window stream after one frame.
    func captureFirstFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        let output = OneFrameOutput { [weak self] image in self?.finish(image) }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "photo-info.album-token-frame"))
        } catch { finish(nil); return }
        lock.lock()
        guard !expired, !finished else { lock.unlock(); return }
        self.stream = stream
        self.output = output
        lock.unlock()
        stream.startCapture { [self, output, stream] error in
            if error != nil { finish(nil) }
            lock.lock()
            let shouldStop = expired || finished
            lock.unlock()
            // The wait may have timed out before asynchronous startup completed.
            if shouldStop { stream.stopCapture { _ in withExtendedLifetime(output) {} } }
        }
    }

    func wait(until deadline: DispatchTime) -> CGImage? {
        let completed = semaphore.wait(timeout: deadline) == .success
        lock.lock()
        expired = true
        let value = completed ? image : nil
        let pendingStream = stream
        let pendingOutput = output
        image = nil
        stream = nil
        output = nil
        lock.unlock()
        pendingStream?.stopCapture { _ in withExtendedLifetime(pendingOutput) {} }
        return value
    }
}

private final class OneFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let completion: (CGImage?) -> Void
    init(completion: @escaping (CGImage?) -> Void) { self.completion = completion }

    func stream(_ stream: SCStream, didStopWithError error: Error) { completion(nil) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                  createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else {
            completion(nil); return
        }
        completion(image)
    }
}
