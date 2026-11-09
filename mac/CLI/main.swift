import Foundation

// rollconvert: Roll Converter from the command line. The app's own conversion, for scripts and tests.

let usage = """
Usage: rollconvert <roll folder> [options]

Converts every scan (DNG, TIFF, JPEG, PNG) in the folder to a positive.

Options:
  --out <folder>        where the files go (default: Positief inside the roll)
  --film color|bw|positive
                        default: from the folder name ("(zw)", "(positief)"), else color
  --no-roll             balance each frame on its own instead of the roll together
  --no-tiff             no 16-bit TIFF
  --no-jpeg             no JPEG
  --compositor          also a Compositor project with Alex Burke's layers (colour only)
  --scripts <folder>    where the converter's scripts are (default: next to this tool,
                        or the repository it was built from)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rollconvert: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var folder: URL?
var options = RollOptions()
var filmGiven = false
var scriptFolders: [URL] = []

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("\(argument) needs a value") }
        return arguments.removeFirst()
    }
    switch argument {
    case "-h", "--help": print(usage); exit(0)
    case "--out": options.output = URL(fileURLWithPath: value(), isDirectory: true)
    case "--film":
        guard let film = Film(rawValue: value()) else { fail("--film is color, bw or positive") }
        options.film = film
        filmGiven = true
    case "--no-roll": options.rollBalance = false
    case "--no-tiff": options.tiff = false
    case "--no-jpeg": options.jpeg = false
    case "--compositor": options.compositor = true
    case "--scripts": scriptFolders.append(URL(fileURLWithPath: value(), isDirectory: true))
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)\n\n\(usage)") }
        folder = URL(fileURLWithPath: argument, isDirectory: true)
    }
}

guard let folder else { print(usage); exit(1) }
if !filmGiven, let film = Roll.film(forFolder: folder) { options.film = film }
guard options.hasOutput else { fail("nothing to write: TIFF and JPEG are off") }

// Next to the tool, then the repository two levels up from a build in mac/build/…
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
scriptFolders += [executable, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]

do {
    let engine = try Engine(scriptFolders: scriptFolders)
    let files = Roll.scans(in: folder)
    var failed = 0
    print("\(files.count) scan\(files.count == 1 ? "" : "s") in \(folder.lastPathComponent), \(options.film.title.lowercased())")
    let output = try RollConverter(engine: engine).run(folder: folder, options: options) { index, state, note in
        let name = files[index].lastPathComponent
        switch state {
        case .done: print("  \(name) ✓")
        case .failed(let message): failed += 1; print("  \(name) failed: \(message)")
        default: break
        }
        if let note { print("  \(name): \(note)") }
    }
    print("Written to \(output.path)")
    exit(failed == 0 ? 0 : 2)
} catch {
    fail(error.localizedDescription)
}
