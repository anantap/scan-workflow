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

    /// Whether a file is a scan this converter reads.
    static func isScan(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Scans in Finder's order.
    static func sorted(_ files: [URL]) -> [URL] {
        files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The scans in a roll folder (not in its subfolders), in Finder's order.
    static func scans(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return sorted(items.filter(isScan))
    }

    /// What the folder's name says about the film. A tag in brackets comes
    /// first: "(zw)", "(bw)", "(b&w)" or "(zwart-wit)" mean black and white, "(positief)" or "(positive)"
    /// already positive. Otherwise a film stock in the name says it: HP5 is black and white, Velvia a slide.
    static func film(forFolder folder: URL) -> Film? {
        let name = folder.lastPathComponent
        if name.range(of: #"\(\s*(zw|bw|b&w|zwart-?wit)(?![a-z0-9])[^)]*\)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .bw
        }
        if name.range(of: #"\(\s*(positief|positive)(?![a-z0-9])[^)]*\)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .positive
        }
        return stock(forFolder: folder)?.film
    }

    struct Stock: Equatable {
        let name: String
        let film: Film
    }

    /// Film stocks the folder name can mention: a pattern, the stock's full name ("#" is the speed in the
    /// name, if any) and what kind of film it is.
    private static let stocks: [(pattern: String, name: String, film: Film)] = [
        // Black and white
        (#"hp\s?5"#, "Ilford HP5 Plus #", .bw), (#"fp\s?4"#, "Ilford FP4 Plus #", .bw),
        (#"delta"#, "Ilford Delta #", .bw), (#"pan\s?f"#, "Ilford Pan F Plus #", .bw),
        (#"xp\s?2"#, "Ilford XP2 Super #", .bw), (#"sfx"#, "Ilford SFX #", .bw),
        (#"tri-?\s?x"#, "Kodak Tri-X #", .bw), (#"t-?\s?max|tmax|tmy|tmx"#, "Kodak T-Max #", .bw),
        (#"double-?\s?x"#, "Kodak Double-X #", .bw), (#"acros"#, "Fujifilm Acros #", .bw),
        (#"foma(pan)?"#, "Fomapan #", .bw), (#"kentmere"#, "Kentmere #", .bw),
        (#"rpx|retro|superpan"#, "Rollei #", .bw), (#"bergger"#, "Bergger Pancro #", .bw),
        (#"adox"#, "Adox #", .bw), (#"ultrafine"#, "Ultrafine #", .bw), (#"ilford"#, "Ilford #", .bw),
        // Slides
        (#"ektachrome|e100"#, "Kodak Ektachrome #", .positive), (#"velvia"#, "Fujifilm Velvia #", .positive),
        (#"provia"#, "Fujifilm Provia #", .positive), (#"kodachrome"#, "Kodachrome #", .positive),
        (#"fujichrome"#, "Fujichrome #", .positive), (#"precisa"#, "AgfaPhoto CT Precisa #", .positive),
        // Colour negative
        (#"portra"#, "Kodak Portra #", .color), (#"ektar"#, "Kodak Ektar #", .color),
        (#"ultra\s?max"#, "Kodak UltraMax #", .color), (#"color\s?plus"#, "Kodak ColorPlus #", .color),
        (#"pro\s?image"#, "Kodak ProImage #", .color), (#"kodak\s?gold|(?<![a-z])gold"#, "Kodak Gold #", .color),
        (#"vision\s?3"#, "Kodak Vision3 #", .color), (#"cinestill"#, "CineStill #", .color),
        (#"superia"#, "Fujifilm Superia #", .color), (#"400h"#, "Fujifilm Pro 400H", .color),
        (#"fujicolou?r|c200"#, "Fujicolor #", .color), (#"phoenix"#, "Harman Phoenix #", .color),
        (#"lomo(graphy)?"#, "Lomography #", .color),
    ]

    /// The film stock the folder's name mentions, as "2026-11 Portra 400" or "HP5 roll 3".
    static func stock(forFolder folder: URL) -> Stock? {
        let name = folder.lastPathComponent
        for stock in stocks {
            guard let range = name.range(of: #"(?<![a-z0-9])("# + stock.pattern + #")(?![a-z])"#,
                                         options: [.regularExpression, .caseInsensitive]) else { continue }
            // The speed: a number (and a letter, as 800T) right after the stock's name.
            let rest = name[range.upperBound...]
            var speed = ""
            if let match = rest.range(of: #"^[\s-]*(\d{2,4}[dt]?)(?![0-9])"#, options: [.regularExpression, .caseInsensitive]) {
                speed = rest[match].trimmingCharacters(in: CharacterSet(charactersIn: " -")).uppercased()
            }
            let full = stock.name.replacingOccurrences(of: "#", with: speed).trimmingCharacters(in: .whitespaces)
            return Stock(name: full, film: stock.film)
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
        return try run(files: files, folder: folder, options: options, progress: progress)
    }

    /// Converts just these scans, as a roll of their own: with one balance for them together when
    /// there are several. The files go to `folder`'s output folder (Positief next to the scans).
    func run(files: [URL], folder: URL, options: RollOptions, progress: (Int, FrameState, String?) -> Void) throws -> URL {
        guard !files.isEmpty else { throw Engine.Failure(message: "No scans to convert") }
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
