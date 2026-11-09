import Foundation

enum Film: String, CaseIterable, Identifiable {
    case color, bw, positive
    var id: Self { self }
    var title: String {
        switch self {
        case .color: "Colour negative"
        case .bw: "Black & white negative"
        case .positive: "Already positive"
        }
    }
}

struct RollOptions {
    var film: Film = .color
    /// One white point and colour balance for every frame of the roll.
    var rollBalance = true
    var tiff = true
    var jpeg = true
    /// A Compositor project with Alex Burke's layers (colour negatives only).
    var compositor = false
    /// Where the files go; nil = a `Positief` folder inside the roll.
    var output: URL?

    var hasOutput: Bool { tiff || jpeg || (compositor && film == .color) }
}

enum FrameState: Equatable {
    case waiting, measuring, converting, done, failed(String)
}

enum Roll {
    static let extensions: Set<String> = ["dng", "tif", "tiff", "jpg", "jpeg", "png"]

    /// The scans in a roll folder (not in its subfolders), in Finder's order.
    static func scans(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// What the folder's name says about the film, as the scan inbox reads it: brackets that start with
    /// "zw", "bw", "b&w" or "zwart-wit" mean black and white, "positief" or "positive" already positive.
    static func film(forFolder folder: URL) -> Film? {
        let name = folder.lastPathComponent
        if name.range(of: #"\(\s*(zw|bw|b&w|zwart-?wit)(?![a-z0-9])[^)]*\)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .bw
        }
        if name.range(of: #"\(\s*(positief|positive)(?![a-z0-9])[^)]*\)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .positive
        }
        return nil
    }

    static func outputFolder(for folder: URL, options: RollOptions) -> URL {
        options.output ?? folder.appendingPathComponent("Positief", isDirectory: true)
    }
}

/// Converts a roll: measures every frame, then converts each one, with one balance for the roll.
final class RollConverter {
    private let engine: Engine

    init(engine: Engine) {
        self.engine = engine
    }

    /// `progress(index, state, note)` reports each frame; a note says something worth knowing about
    /// it (no orange mask). Returns the output folder. Frames that fail are reported and skipped.
    func run(folder: URL, options: RollOptions, progress: (Int, FrameState, String?) -> Void) throws -> URL {
        let files = Roll.scans(in: folder)
        guard !files.isEmpty else { throw Engine.Failure(message: "No scans in \(folder.lastPathComponent)") }
        let output = Roll.outputFolder(for: folder, options: options)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let compositor = options.compositor && options.film == .color
        defer { engine.forget() }

        // 1. Measure every frame
        var measured: [(index: Int, url: URL, analysis: Engine.Analysis)] = []
        for (index, url) in files.enumerated() {
            progress(index, .measuring, nil)
            do {
                let analysis = try engine.analyze(url, film: options.film, compositor: compositor)
                measured.append((index, url, analysis))
                let note = options.film == .color && !analysis.masked
                    ? "No orange mask: already positive, or black and white?" : nil
                progress(index, .waiting, note)
            } catch {
                progress(index, .failed(error.localizedDescription), nil)
            }
        }
        let useRoll = options.rollBalance && measured.count > 1
        if useRoll { try engine.makeRoll(measured.map { $0.analysis.id }) }

        // 2. Convert and write each frame
        for frame in measured {
            progress(frame.index, .converting, nil)
            do {
                try autoreleasepool {
                    let ids = compositor ? (0..<6).map { _ in UUID().uuidString } : nil
                    let rendered = try engine.render(frame.url, id: frame.analysis.id, film: options.film, useRoll: useRoll,
                                                     layerIDs: ids, documentID: compositor ? UUID().uuidString : nil)
                    let name = frame.url.deletingPathExtension().lastPathComponent
                    if options.tiff || options.jpeg {
                        let image = try ImageFiles.image16(rendered.positive, width: rendered.width, height: rendered.height)
                        if options.tiff {
                            try ImageFiles.writeTIFF(image, to: output.appendingPathComponent("\(name).tif"), dpi: rendered.dpi)
                        }
                        if options.jpeg {
                            try ImageFiles.writeJPEG(image, to: output.appendingPathComponent("\(name).jpg"), dpi: rendered.dpi)
                        }
                    }
                    if compositor, let ids, let manifest = rendered.manifest, let scan = rendered.scan, let base = rendered.baseColor {
                        try ImageFiles.writeCompositorProject(to: output.appendingPathComponent("\(name).comp"), manifest: manifest,
                                                              scan: scan, width: rendered.width, height: rendered.height,
                                                              baseColor: base, layerIDs: ids)
                    }
                }
                progress(frame.index, .done, nil)
            } catch {
                progress(frame.index, .failed(error.localizedDescription), nil)
            }
        }
        return output
    }
}
