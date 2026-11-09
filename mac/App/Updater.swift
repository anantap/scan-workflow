import AppKit
import Foundation

/// Keeps the app up to date from the repository's GitHub releases. Every push builds the app and
/// publishes it as the latest release, tagged `build-<number>`. The app looks for a newer one at launch
/// and every few hours, downloads it in the background, and puts it in place when you restart (or
/// quit) the app.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, downloading(Int), upToDate
        /// A newer build is downloaded and ready to put in place.
        case ready(Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    static let repository = "anantap/scan-workflow"
    static let assetName = "Roll-Converter.zip"

    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    private var staged: URL?
    private var timer: Timer?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
    }

    // MARK: - Checking and downloading

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let assets: [Asset]
    }

    func check() {
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        Task {
            do {
                let latest = try await Self.latestRelease()
                guard let latest, latest.build > currentBuild else { state = .upToDate; return }
                state = .downloading(latest.build)
                staged = try await Self.download(latest.url, build: latest.build)
                state = .ready(latest.build)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private static func latestRelease() async throws -> (build: Int, url: URL)? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RollConverter", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.tag_name.hasPrefix("build-"), let build = Int(release.tag_name.dropFirst(6)),
              let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
        return (build, asset.browser_download_url)
    }

    /// Downloads and unpacks the build; returns the new app, checked to be that build.
    private static func download(_ url: URL, build: Int) async throws -> URL {
        let (file, _) = try await URLSession.shared.download(from: url)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollConverterUpdate-\(build)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
        try? FileManager.default.removeItem(at: file)
        let app = folder.appendingPathComponent("Roll Converter.app")
        guard let bundle = Bundle(url: app),
              Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == build else {
            throw Updater.Failure(message: "The downloaded update isn't build \(build)")
        }
        return app
    }

    // MARK: - Installing

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Why the app can't replace itself where it is, if it can't.
    var installProblem: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "Move Roll Converter to your Applications folder to update it."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "Roll Converter can't update itself in \(app.deletingLastPathComponent().lastPathComponent)."
        }
        return nil
    }

    /// Puts the downloaded build in place once this app has quit, then opens it if `relaunch`.
    func install(relaunch: Bool) {
        guard let staged, installProblem == nil else { return }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        old="$2"; new="$3"; aside="$4"
        if mv "$old" "$aside"; then
          if mv "$new" "$old"; then rm -rf "$aside"; else mv "$aside" "$old"; fi
        fi
        xattr -dr com.apple.quarantine "$old" 2>/dev/null
        if [ "$5" = 1 ]; then open "$old"; fi
        """
        let app = Bundle.main.bundleURL
        let aside = staged.deletingLastPathComponent().appendingPathComponent("previous.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             app.path, staged.path, aside.path, relaunch ? "1" : "0"]
        do {
            try process.run()
            self.staged = nil
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func restartNow() {
        guard staged != nil, installProblem == nil else { return }
        install(relaunch: true)
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "Could not unpack the update") }
    }
}
