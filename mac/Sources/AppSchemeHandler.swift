import Foundation
import WebKit

/// Serves the converter from the app bundle under ncapp://app/, plus the
/// scans the user opened (and only those) under ncapp://app/__file/<token>/.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ncapp"
    static let pageURL = URL(string: "ncapp://app/converter.html")!

    private var files: [String: URL] = [:]
    private let lock = NSLock()

    /// Makes a file fetchable by the page and returns its URL.
    func register(_ file: URL) -> String {
        let token = UUID().uuidString
        lock.lock()
        files[token] = file
        lock.unlock()
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "scan"
        return "\(Self.scheme)://app/__file/\(token)/\(name)"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        var fileURL: URL?
        let parts = url.pathComponents // ["/", "__file", token, name]
        if parts.count >= 3, parts[1] == "__file" {
            lock.lock()
            fileURL = files[parts[2]]
            lock.unlock()
        } else if let root = Bundle.main.resourceURL?.standardizedFileURL {
            let relative = url.path.count > 1 ? String(url.path.dropFirst()) : "converter.html"
            let candidate = root.appendingPathComponent(relative).standardizedFileURL
            // Never serve anything outside the bundle's resources.
            if candidate.path.hasPrefix(root.path + "/") {
                fileURL = candidate
            }
        }

        guard let fileURL, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let headers = [
            "Content-Type": Self.mimeType(for: fileURL.pathExtension),
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "woff2": return "font/woff2"
        case "tif", "tiff": return "image/tiff"
        case "dng": return "image/x-adobe-dng"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
