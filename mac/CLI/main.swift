import Foundation

// rollconvert: Roll Converter from the command line. The app's own conversion, for scripts and tests.

let usage = """
Usage: rollconvert <roll folder> [options]
       rollconvert <scan> [<scan>…] [options]

Converts every scan (DNG, TIFF, JPEG, PNG) in the folder to a positive, with one colour balance for
the roll. Given scans, converts just those, into Positief next to them.

Options:
  --out <folder>        where the files go (default: Positief inside the roll)
  --film color|bw|positive
                        default: from the folder name, a tag ("(zw)", "(positief)") or a
                        film stock in it ("HP5", "Velvia"), else color
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
var inputs: [URL] = []
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
        inputs.append(URL(fileURLWithPath: argument))
    }
}

guard let first = inputs.first else { print(usage); exit(1) }
var isFolder: ObjCBool = false
guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isFolder) else { fail("\(first.path) doesn't exist") }
// One folder is a roll; otherwise these scans, from the folder they're in.
let wholeRoll = inputs.count == 1 && isFolder.boolValue
let folder = wholeRoll ? first : first.deletingLastPathComponent()
if !filmGiven, let film = Roll.film(forFolder: folder) { options.film = film }
guard options.hasOutput else { fail("nothing to write: TIFF and JPEG are off") }

// Next to the tool, then the repository two levels up from a build in mac/build/…
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
scriptFolders += [executable, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]

do {
    let engine = try Engine(scriptFolders: scriptFolders)
    let files = wholeRoll ? Roll.scans(in: folder) : Roll.sorted(inputs.filter(Roll.isScan))
    guard !files.isEmpty else { fail("no scans (DNG, TIFF, JPEG or PNG) to convert") }
    var failed = 0
    let stock = Roll.stock(forFolder: folder).map { " (\($0.name))" } ?? ""
    print("\(files.count) scan\(files.count == 1 ? "" : "s") in \(folder.lastPathComponent), \(options.film.title.lowercased())\(stock)")
    let output = try RollConverter(engine: engine).run(files: files, folder: folder, options: options) { index, state, note in
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
