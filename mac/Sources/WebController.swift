import AppKit
import UniformTypeIdentifiers
import WebKit

/// Host for the converter page: loads it from the app bundle, opens scans
/// with the Mac file picker and saves exports into a chosen folder.
@MainActor
final class WebController: NSObject, ObservableObject {
    let webView: WKWebView
    private let schemeHandler: AppSchemeHandler
    /// Where each running download is being written.
    private var destinations: [ObjectIdentifier: URL] = [:]

    private static let exportFolderKey = "exportFolder"
    private static let scanExtensions: Set<String> = ["dng", "tif", "tiff", "jpg", "jpeg", "png"]

    /// Folder that exports go into; remembered between launches.
    private var exportFolder: URL? {
        didSet { UserDefaults.standard.set(exportFolder?.path, forKey: Self.exportFolderKey) }
    }

    override init() {
        let handler = AppSchemeHandler()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: AppSchemeHandler.scheme)
        let content = WKUserContentController()
        config.userContentController = content
        schemeHandler = handler
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        if let path = UserDefaults.standard.string(forKey: Self.exportFolderKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                exportFolder = URL(fileURLWithPath: path, isDirectory: true)
            }
        }

        content.addScriptMessageHandler(self, contentWorld: .page, name: "nc")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.067, alpha: 1)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.load(URLRequest(url: AppSchemeHandler.pageURL))
    }

    // MARK: - Openen

    func openScans() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Self.scanTypes
        panel.prompt = "Openen"
        panel.message = "Kies scans, of een map met scans"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.send(files: self.expand(panel.urls))
        }
    }

    private static var scanTypes: [UTType] {
        var types: [UTType] = [.tiff, .jpeg, .png]
        if let dng = UTType(filenameExtension: "dng") { types.append(dng) }
        return types
    }

    /// Folders become the scans inside them, sorted like the Finder does.
    private func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                files += items.filter { Self.scanExtensions.contains($0.pathExtension.lowercased()) }
            } else if Self.scanExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Hands the files to the page as URLs it can fetch, so nothing is read
    /// into memory until a frame needs it.
    private func send(files: [URL]) {
        guard !files.isEmpty else { return }
        let items = files.map { ["name": $0.lastPathComponent, "url": schemeHandler.register($0)] }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.ncOpenNative && window.ncOpenNative(\(json))", completionHandler: nil)
    }

    // MARK: - Exportmap

    /// Asks for an export folder. `reply` gets its path, or nil if cancelled.
    func chooseExportFolder(reply: ((String?) -> Void)?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Exporteer hierheen"
        panel.message = "Kies de map voor de omgezette bestanden"
        if let exportFolder { panel.directoryURL = exportFolder }
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                self.exportFolder = url
                self.notifyPage("window.ncExportFolder && window.ncExportFolder(\(Self.jsString(url.path)))")
            }
            reply?(response == .OK ? panel.url?.path : nil)
        }
    }

    func revealExportFolder() {
        if let exportFolder {
            NSWorkspace.shared.activateFileViewerSelecting([exportFolder])
        } else {
            chooseExportFolder(reply: nil)
        }
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    private func notifyPage(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

// MARK: - Berichten van de pagina

extension WebController: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "Onbekend bericht")
            return
        }
        switch type {
        case "open":
            openScans()
            replyHandler(nil, nil)
        case "exportFolder":
            // Map voor een export: de onthouden map, of eerst vragen.
            if let exportFolder, FileManager.default.fileExists(atPath: exportFolder.path) {
                replyHandler(exportFolder.path, nil)
            } else {
                chooseExportFolder { path in replyHandler(path, nil) }
            }
        case "chooseExportFolder":
            chooseExportFolder { path in replyHandler(path, nil) }
        case "reveal":
            revealExportFolder()
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Onbekend bericht: \(type)")
        }
    }
}

// MARK: - Navigatie en downloads

extension WebController: WKNavigationDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Links naar websites openen in de browser, niet in de app.
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        if let exportFolder {
            let url = Self.uniqueURL(in: exportFolder, name: suggestedFilename)
            destinations[key] = url
            completionHandler(url)
        } else {
            chooseExportFolder { [weak self] path in
                guard let self, let path else { completionHandler(nil); return }
                let url = Self.uniqueURL(in: URL(fileURLWithPath: path, isDirectory: true), name: suggestedFilename)
                self.destinations[key] = url
                completionHandler(url)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        notifyPage("window.ncSaved && window.ncSaved(\(Self.jsString(url.lastPathComponent)), \(Self.jsString(url.deletingLastPathComponent().path)))")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        notifyPage("window.ncSaveFailed && window.ncSaveFailed(\(Self.jsString(error.localizedDescription)))")
    }
}

// MARK: - Bestanden kiezen via <input type=file>

extension WebController: WKUIDelegate {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.scanTypes
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

/// Keeps the web view filling the window.
final class WKWebViewContainer: NSView {
    init(webView: WKWebView) {
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
