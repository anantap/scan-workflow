import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading and writing images with macOS's own ImageIO, so files carry an sRGB profile and open as
/// intended in Photoshop, Compositor, Lightroom and the like.
enum ImageFiles {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Reading

    /// A JPEG or PNG as 8-bit RGBA (premultiplied, alpha last) for the converter.
    static func rgba8(_ url: URL) throws -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "\(url.lastPathComponent) can't be read as an image")
        }
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(message: "\(url.lastPathComponent) can't be decoded")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (data, width, height)
    }

    // MARK: - Thumbnails

    /// A small picture of a scan file, as macOS reads it (DNG included), the longest side `size` pixels.
    static func thumbnail(of url: URL, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image made smaller, its longest side `size` pixels, in 8-bit sRGB.
    static func thumbnail(of image: CGImage, size: Int) -> CGImage? {
        let scale = min(1, Double(size) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Writing

    /// 16-bit sRGB RGB pixels (little-endian, as the converter makes them) as an image.
    static func image16(_ rgb: Data, width: Int, height: Int) throws -> CGImage {
        guard rgb.count >= width * height * 6, let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
                                  bytesPerRow: width * 6, space: sRGB,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                                           | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure(message: "Could not make the image")
        }
        return image
    }

    static func writeTIFF(_ image: CGImage, to url: URL, dpi: Double?) throws {
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5], // LZW, lossless
        ]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        try write(image, to: url, type: .tiff, properties: properties)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, dpi: Double?) throws {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        try write(image, to: url, type: .jpeg, properties: properties)
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "Could not write a PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Could not write a PNG") }
        return data as Data
    }

    /// Writes next to the destination first, then moves it into place, replacing what was there.
    private static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(message: "Could not write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure(message: "Could not write \(url.lastPathComponent)")
        }
        try replace(url, with: temporary)
    }

    static func replace(_ url: URL, with temporary: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temporary, to: url)
    }

    // MARK: - Compositor

    /// A Compositor project (.comp): a folder with the manifest and its layer images. The scan layer is
    /// `<layerIDs[0]>.png` (16-bit), the film base layer `<layerIDs[2]>.png`, one pixel of `baseColor`
    /// that Compositor stretches over the canvas.
    static func writeCompositorProject(to url: URL, manifest: Data, scan: Data, width: Int, height: Int,
                                       baseColor: [Double], layerIDs: [String]) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let images = temporary.appendingPathComponent("images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        do {
            try pngData(try image16(scan, width: width, height: height))
                .write(to: images.appendingPathComponent("\(layerIDs[0]).png"))
            var pixel = Data()
            for value in baseColor.prefix(3) {
                var sample = UInt16(max(0, min(65535, (value * 65535).rounded()))).littleEndian
                withUnsafeBytes(of: &sample) { pixel.append(contentsOf: $0) }
            }
            try pngData(try image16(pixel, width: 1, height: 1))
                .write(to: images.appendingPathComponent("\(layerIDs[2]).png"))
            try manifest.write(to: temporary.appendingPathComponent("manifest.json"))
            try replace(url, with: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }
}
