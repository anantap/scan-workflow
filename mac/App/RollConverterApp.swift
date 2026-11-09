import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RollConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RollModel()

    var body: some Scene {
        Window("Roll Converter", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 560)
        }
        .defaultSize(width: 640, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Roll…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.running)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Model

struct FrameRow: Identifiable {
    let url: URL
    var state: FrameState = .waiting
    var note: String?
    var id: URL { url }
}

@MainActor
final class RollModel: ObservableObject {
    @Published var folder: URL?
    @Published var frames: [FrameRow] = []
    @Published var options = RollOptions()
    @Published var running = false
    @Published var finishedFolder: URL?
    @Published var error: String?

    var done: Int { frames.filter { $0.state == .done }.count }
    var failed: Int { frames.filter { if case .failed = $0.state { return true } else { return false } }.count }
    var outputFolder: URL? { folder.map { Roll.outputFolder(for: $0, options: options) } }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Roll"
        panel.message = "Choose the folder with the roll's scans"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard !running else { return }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        let roll = isFolder.boolValue ? url : url.deletingLastPathComponent()
        folder = roll
        frames = Roll.scans(in: roll).map { FrameRow(url: $0) }
        options.film = Roll.film(forFolder: roll) ?? .color
        options.output = nil
        finishedFolder = nil
        error = frames.isEmpty ? "No scans (DNG, TIFF, JPEG or PNG) in this folder." : nil
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        options.output = url
    }

    func convert() {
        guard let folder, !running, !frames.isEmpty else { return }
        running = true
        finishedFolder = nil
        error = nil
        for index in frames.indices { frames[index].state = .waiting; frames[index].note = nil }
        let options = self.options
        let scripts = [Bundle.main.resourceURL].compactMap { $0 }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let engine = try Engine(scriptFolders: scripts)
                let output = try RollConverter(engine: engine).run(folder: folder, options: options) { index, state, note in
                    Task { @MainActor in
                        guard let self, self.frames.indices.contains(index) else { return }
                        self.frames[index].state = state
                        if let note { self.frames[index].note = note }
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.finishedFolder = output
                    self.running = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard let self else { return }
                    self.error = message
                    self.running = false
                }
            }
        }
    }

    func revealOutput() {
        guard let finishedFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finishedFolder])
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var model: RollModel
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.folder == nil {
                dropZone
            } else {
                rollView
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a roll folder here")
                .font(.title2.weight(.semibold))
            Text("Every scan in it becomes a positive: a 16-bit TIFF for Compositor, Photoshop and the like, and a JPEG.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Choose Roll…") { model.chooseFolder() }
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(16)
        )
    }

    private var rollView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            settings
            Divider()
            frameList
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folder?.lastPathComponent ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(model.frames.count) scan\(model.frames.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Another Roll…") { model.chooseFolder() }
                .disabled(model.running)
        }
        .padding(16)
    }

    private var settings: some View {
        Form {
            Picker("Film", selection: $model.options.film) {
                ForEach(Film.allCases) { Text($0.title).tag($0) }
            }
            Toggle("One colour balance for the whole roll", isOn: $model.options.rollBalance)
            LabeledContent("Make") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("16-bit TIFF (Compositor, Photoshop, Lightroom…)", isOn: $model.options.tiff)
                    Toggle("JPEG, to view and share", isOn: $model.options.jpeg)
                    Toggle("Compositor project with Alex Burke's layers", isOn: $model.options.compositor)
                        .disabled(model.options.film != .color)
                }
            }
            LabeledContent("Save to") {
                HStack {
                    Text(model.options.output == nil ? "Positief folder inside the roll" : (model.outputFolder?.path ?? ""))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.options.output != nil {
                        Button("Reset") { model.options.output = nil }
                    }
                    Button("Choose…") { model.chooseOutput() }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.running)
        .frame(maxHeight: 250)
    }

    private var frameList: some View {
        List(model.frames) { frame in
            HStack(spacing: 10) {
                icon(for: frame.state)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(frame.url.lastPathComponent)
                    if case .failed(let message) = frame.state {
                        Text(message).font(.caption).foregroundStyle(.red)
                    } else if let note = frame.note {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(label(for: frame.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.running {
                ProgressView(value: Double(model.done + model.failed), total: Double(max(1, model.frames.count)))
                    .frame(maxWidth: 220)
                Text("\(model.done) of \(model.frames.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let error = model.error {
                Text(error).foregroundStyle(.red)
            } else if model.finishedFolder != nil {
                Text(model.failed == 0 ? "Done: \(model.done) positives" : "Done: \(model.done) positives, \(model.failed) failed")
                Button("Show in Finder") { model.revealOutput() }
            } else {
                Text("Existing files with the same name in the output folder are replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Convert") { model.convert() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.running || model.frames.isEmpty || !model.options.hasOutput)
        }
        .padding(16)
    }

    @ViewBuilder
    private func icon(for state: FrameState) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .measuring, .converting: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func label(for state: FrameState) -> String {
        switch state {
        case .waiting: ""
        case .measuring: "Measuring"
        case .converting: "Converting"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}
