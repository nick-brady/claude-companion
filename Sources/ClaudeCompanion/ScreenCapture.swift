import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A picture to send to Claude.
struct Attachment: Identifiable {
    let id = UUID()
    let label: String
    let image: CGImage
    let jpeg: Data
}

enum ScreenCapture {
    struct Shot {
        let image: CGImage
        /// The NSScreen frame (global Cocoa coordinates, origin bottom-left) the image covers.
        let screenFrame: CGRect
        let scale: CGFloat
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (first time only) / adds the app to the Screen Recording list.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Captures the whole display under `point`, excluding this app's own windows.
    static func captureScreen(containing point: CGPoint) async throws -> Shot {
        guard let screen = screen(containing: point),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw CaptureError.noDisplay }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == num.uint32Value }) else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        cfg.width = Int(screen.frame.width * scale)
        cfg.height = Int(screen.frame.height * scale)
        cfg.showsCursor = true
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Shot(image: img, screenFrame: screen.frame, scale: scale)
    }

    /// Converts a global Cocoa rect to pixel coordinates (origin top-left) in the shot.
    static func pixelRect(_ r: CGRect, in shot: Shot) -> CGRect {
        let f = shot.screenFrame
        return CGRect(x: (r.minX - f.minX) * shot.scale,
                      y: (f.maxY - r.maxY) * shot.scale,
                      width: r.width * shot.scale,
                      height: r.height * shot.scale)
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
    }

    /// Full screen with a red ring at the cursor.
    static func screenWithCursor(_ shot: Shot, cursor: CGPoint) -> CGImage {
        let px = pixelRect(CGRect(x: cursor.x - 28, y: cursor.y - 28, width: 56, height: 56), in: shot)
        return annotate(shot.image, ellipse: px)
    }

    /// Full screen with a red box around a circled region.
    static func screenWithRegion(_ shot: Shot, region: CGRect) -> CGImage {
        annotate(shot.image, box: pixelRect(region, in: shot))
    }

    static func crop(_ shot: Shot, region: CGRect) -> CGImage? {
        shot.image.cropping(to: pixelRect(region, in: shot).integral)
    }

    /// Interactive drag-to-select using macOS's own screencapture UI (Space toggles window mode,
    /// Esc cancels). Returns nil, after logging why, if the user cancelled or nothing usable was captured.
    static func dragRegion() async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-region-\(UUID().uuidString).png")
        let status: Int32? = await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", "-o", url.path]   // interactive, silent, no window shadow
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch {
                DiagLog.log("capture.region", "couldn't launch screencapture: \(error.localizedDescription)")
                c.resume(returning: nil)
            }
        }
        guard let status else { return nil }
        return loadCapture(at: url, exitStatus: status)
    }

    /// Reads the PNG `screencapture` wrote, fully decoded into memory, then deletes the file.
    ///
    /// The image must own its pixels before the file goes away. `CGImageSourceCreateImageAtIndex`
    /// on a file URL returns a lazily-decoded image that re-opens the path when the pixels are
    /// first needed; encoding that image after the temp file was deleted produced a header-only
    /// JPEG (small captures) or a blank one (captures that went through `resize`).
    static func loadCapture(at url: URL, exitStatus: Int32 = 0) -> CGImage? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            DiagLog.log("capture.region", "no file written (cancelled?) exit=\(exitStatus)")
            return nil
        }
        // A PNG ends with an IEND chunk; without it the file is truncated and ImageIO quietly
        // decodes it as a blank image instead of failing.
        let pngTrailer: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        guard data.count > pngTrailer.count, [UInt8](data.suffix(pngTrailer.count)) == pngTrailer else {
            DiagLog.log("capture.region", "incomplete png (\(data.count) bytes, no IEND) exit=\(exitStatus)")
            return nil
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let lazy = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              lazy.width > 0, lazy.height > 0,
              let img = bitmapCopy(lazy)
        else {
            DiagLog.log("capture.region", "undecodable capture (\(data.count) bytes) exit=\(exitStatus)")
            return nil
        }
        DiagLog.log("capture.region", "\(img.width)x\(img.height) from \(data.count)-byte png")
        return img
    }

    // MARK: - Encoding

    /// Downscale so the long edge is <= maxEdge, encode JPEG. Returns nil (and logs) rather than
    /// an attachment whose JPEG has no pixel data.
    static func makeAttachment(_ img: CGImage, label: String, maxEdge: CGFloat = 1600) -> Attachment? {
        guard img.width > 0, img.height > 0 else {
            DiagLog.log("capture.encode", "empty image (\(img.width)x\(img.height)) for \"\(label)\"")
            return nil
        }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let s = min(1, maxEdge / max(w, h))
        let target = s < 1 ? (resize(img, to: CGSize(width: (w * s).rounded(), height: (h * s).rounded())) ?? img) : img
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, target, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest), isUsableJPEG(data as Data) else {
            DiagLog.log("capture.encode", "jpeg encode failed for \"\(label)\": \(data.length) bytes from \(target.width)x\(target.height)")
            return nil
        }
        return Attachment(label: label, image: target, jpeg: data as Data)
    }

    /// True when `data` is a JPEG with a frame header (SOF) and decodable, nonzero dimensions.
    /// ImageIO can "successfully" finalize a JPEG that is only APP0/Exif/ICC headers (674 bytes)
    /// when the source image's pixels can't be read.
    static func isUsableJPEG(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return false }
        var hasSOF = false
        for i in 2..<(b.count - 1) where b[i] == 0xFF && (b[i + 1] == 0xC0 || b[i + 1] == 0xC1 || b[i + 1] == 0xC2) {
            hasSOF = true; break
        }
        guard hasSOF,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return w > 0 && h > 0
    }

    /// A copy of `img` whose pixels live in our own bitmap, independent of any file or lazy decoder.
    private static func bitmapCopy(_ img: CGImage) -> CGImage? {
        resize(img, to: CGSize(width: img.width, height: img.height))
    }

    private static func resize(_ img: CGImage, to size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private static func annotate(_ img: CGImage, ellipse: CGRect? = nil, box: CGRect? = nil) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext origin is bottom-left; our rects are top-left.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height) }
        ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.2, alpha: 0.95))
        ctx.setLineWidth(max(4, CGFloat(w) / 500))
        if let e = ellipse { ctx.strokeEllipse(in: flip(e)) }
        if let b = box { ctx.stroke(flip(b).insetBy(dx: -3, dy: -3)) }
        return ctx.makeImage() ?? img
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "Couldn't find the display to capture." }
    }
}
