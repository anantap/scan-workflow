import Foundation
import JavaScriptCore

/// The converter's maths (converter-core.js and compositor/burke-core.js, the same code as the web
/// converter and the scripts) running in JavaScriptCore, so the colours match everywhere.
/// Not thread-safe: use one engine from one thread at a time.
final class Engine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Analysis {
        let id: Int
        let width: Int
        let height: Int
        /// Whether the scan has a colour negative's orange mask.
        let masked: Bool
    }

    struct Rendered {
        let width: Int
        let height: Int
        let dpi: Double?
        /// The positive: 16-bit sRGB RGB, little-endian, rows top to bottom.
        let positive: Data
        /// For a Compositor project: its manifest, the scan layer's pixels (as `positive`) and the
        /// film base colour for the Filmbasis layer.
        let manifest: Data?
        let scan: Data?
        let baseColor: [Double]?
    }

    /// The scripts, loaded in this order.
    static let scripts = ["pako_inflate.min.js", "utif.js", "converter-core.js", "burke-core.js", "engine.js"]

    private let context: JSContext
    private let engine: JSValue

    /// Looks for each script in these folders, and in their `vendor`, `compositor` and `mac/Engine`
    /// subfolders (the repository's layout, for the command-line tool).
    init(scriptFolders: [URL]) throws {
        guard let context = JSContext() else { throw Failure(message: "JavaScriptCore is not available") }
        self.context = context
        context.evaluateScript("var self = this;")
        let fm = FileManager.default
        for name in Self.scripts {
            let candidates = scriptFolders.flatMap { folder in
                ["", "vendor", "compositor", "mac/Engine", "Engine"].map {
                    folder.appendingPathComponent($0).appendingPathComponent(name)
                }
            }
            guard let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
                throw Failure(message: "The converter's script \(name) is missing")
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            context.exception = nil
            context.evaluateScript(source, withSourceURL: url)
            if let exception = context.exception {
                throw Failure(message: "\(name): \(exception.toString() ?? "error")")
            }
        }
        guard let engine = context.objectForKeyedSubscript("Engine"), engine.isObject else {
            throw Failure(message: "The converter's engine did not load")
        }
        self.engine = engine
    }

    // MARK: - Calls

    func analyze(_ url: URL, film: Film, compositor: Bool) throws -> Analysis {
        let source = try load(url)
        let options = try json(["film": film.rawValue, "compositor": compositor])
        let arguments: [Any] = [source.buffer, source.width, source.height, source.rgba, options]
        let result = try object(try call("analyze", arguments))
        collectGarbage()
        guard let id = result["id"] as? Int, let width = result["width"] as? Int,
              let height = result["height"] as? Int else { throw Failure(message: "Unexpected answer from the converter") }
        return Analysis(id: id, width: width, height: height, masked: result["masked"] as? Bool ?? true)
    }

    /// One colour balance for these frames together.
    func makeRoll(_ ids: [Int]) throws {
        _ = try call("makeRoll", [try json(ids)])
    }

    /// `layerIDs`: six uppercase UUIDs for a Compositor project with Burke's layers, or nil for none.
    func render(_ url: URL, id: Int, film: Film, useRoll: Bool, layerIDs: [String]?, documentID: String?) throws -> Rendered {
        let source = try load(url)
        let options = try json(["film": film.rawValue])
        var layers: Any = NSNull()
        if let layerIDs { layers = try json(layerIDs) }
        var document: Any = NSNull()
        if let documentID { document = documentID }
        let arguments: [Any] = [id, source.buffer, source.width, source.height, source.rgba, options, useRoll, layers, document]
        let answer = try call("render", arguments)
        let result = try object(answer)
        guard let width = result["width"] as? Int, let height = result["height"] as? Int else {
            throw Failure(message: "Unexpected answer from the converter")
        }
        let positive = try typedArray(engine.objectForKeyedSubscript("out"))
        var manifest: Data?
        var scan: Data?
        if let m = result["manifest"] {
            manifest = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
            scan = try typedArray(engine.objectForKeyedSubscript("outScan"))
        }
        _ = try call("release", [])
        collectGarbage()
        return Rendered(width: width, height: height, dpi: result["dpi"] as? Double, positive: positive,
                        manifest: manifest, scan: scan, baseColor: result["baseColor"] as? [Double])
    }

    /// Drops every frame's analysis.
    func forget() {
        _ = try? call("forget", [])
        collectGarbage()
    }

    // MARK: - Plumbing

    private struct Source {
        let buffer: JSValue
        let width: Int
        let height: Int
        let rgba: Bool
    }

    /// DNG and TIFF go to the converter as they are; JPEG and PNG are decoded here.
    private func load(_ url: URL) throws -> Source {
        let ext = url.pathExtension.lowercased()
        if ["dng", "tif", "tiff"].contains(ext) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return Source(buffer: try arrayBuffer(data), width: 0, height: 0, rgba: false)
        }
        let decoded = try ImageFiles.rgba8(url)
        return Source(buffer: try arrayBuffer(decoded.data), width: decoded.width, height: decoded.height, rgba: true)
    }

    private func call(_ method: String, _ arguments: [Any]) throws -> JSValue {
        context.exception = nil
        let result = engine.invokeMethod(method, withArguments: arguments)
        if let exception = context.exception {
            context.exception = nil
            throw Failure(message: exception.toString() ?? "The converter failed")
        }
        guard let result else { throw Failure(message: "The converter gave no answer") }
        return result
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func object(_ value: JSValue) throws -> [String: Any] {
        guard let text = value.toString(), let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected answer from the converter")
        }
        return object
    }

    /// The bytes as a JavaScript ArrayBuffer, handed over without a second copy.
    private func arrayBuffer(_ data: Data) throws -> JSValue {
        let count = max(1, data.count)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
        var exception: JSValueRef?
        guard let object = JSObjectMakeArrayBufferWithBytesNoCopy(context.jsGlobalContextRef, bytes, data.count,
                                                                  { bytes, _ in bytes?.deallocate() }, nil, &exception),
              exception == nil, let value = JSValue(jsValueRef: object, in: context) else {
            bytes.deallocate()
            throw Failure(message: "Could not hand the scan to the converter")
        }
        return value
    }

    /// A typed array's bytes, copied out.
    private func typedArray(_ value: JSValue?) throws -> Data {
        guard let value, !value.isNull, !value.isUndefined else { throw Failure(message: "The converter made no image") }
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSValueToObject(ctx, value.jsValueRef, &exception),
              let bytes = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else {
            throw Failure(message: "Could not read the converted image")
        }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        return Data(bytes: bytes, count: length)
    }

    private func collectGarbage() {
        JSGarbageCollect(context.jsGlobalContextRef)
    }
}
