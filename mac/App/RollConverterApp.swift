import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RollConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RollModel()
    @StateObject private var updater = Updater.shared

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        Window("Roll Converter", id: "main") {
            ContentView(model: model, updater: updater)
                .frame(minWidth: 560, minHeight: 640)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Roll…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.running)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        Updater.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A downloaded update goes in place when the app quits, so the next start is the new version.
    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.install(relaunch: false)
    }
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
    @ObservedObject var updater: Updater
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            MistBackground()
            VStack(spacing: 16) {
                UpdateCard(updater: updater)
                if model.folder == nil {
                    DropCard(model: model, targeted: dropTargeted)
                } else {
                    RollScreen(model: model)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 24)
        }
        .font(Theme.m)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .onAppear {
            // A roll folder given when the app is started:  open -a "Roll Converter" --args <folder>
            if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                model.open(URL(fileURLWithPath: path, isDirectory: true))
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
}

/// A two-line title: the second line dim, as on the CPC cards.
struct TwoTone: View {
    let first: String
    let second: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(first).foregroundStyle(Theme.text)
            if let second { Text(second).foregroundStyle(Theme.dim) }
        }
        .font(Theme.l)
        .tracking(-0.36)
        .lineSpacing(8)
    }
}

// MARK: Update

struct UpdateCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if case .ready(let build) = updater.state {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update").font(Theme.s).foregroundStyle(Theme.accentText)
                    Text("Build \(build) is ready").font(Theme.font(16))
                    Text(updater.installProblem ?? "It goes in place when you restart or quit the app.")
                        .font(Theme.s).foregroundStyle(Theme.dim)
                }
                Spacer()
                if updater.installProblem == nil {
                    Button("Restart") { updater.restartNow() }.buttonStyle(.chip(.primary))
                }
            }
            .padding(20)
            .glass()
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: Start

struct DropCard: View {
    @ObservedObject var model: RollModel
    let targeted: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Blob(size: 420).offset(x: 80, y: -60)
            VStack(alignment: .leading, spacing: 0) {
                TwoTone(first: "Drop a roll folder here", second: "and every scan becomes a positive.")
                Spacer()
                Text("A 16-bit TIFF for Compositor, Photoshop and the like, and a JPEG to share. Black and white and slides too.")
                    .font(Theme.font(16))
                    .foregroundStyle(Theme.dim)
                    .lineSpacing(6)
                    .frame(maxWidth: 380, alignment: .leading)
                    .padding(.bottom, 24)
                Button("Choose Roll…") { model.chooseFolder() }
                    .buttonStyle(.chip(.primary, height: 56))
                    .keyboardShortcut("o")
                if let error = model.error {
                    Text(error).font(Theme.s).foregroundStyle(Theme.error).padding(.top, 12)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .glass(.white.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.accent.opacity(targeted ? 1 : 0), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

// MARK: Roll

struct RollScreen: View {
    @ObservedObject var model: RollModel

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SunCard(model: model)
                    section("Settings")
                    SettingsCard(model: model)
                    section("Scans")
                    FramesCard(model: model)
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            Footer(model: model)
        }
    }

    private func section(_ text: String) -> some View {
        Text(text).font(Theme.s).tracking(0.12).padding(.top, 8).padding(.leading, 4)
    }
}

/// The big card: the roll, its film, and a number in Geist Pixel, over the blob.
struct SunCard: View {
    @ObservedObject var model: RollModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Blob(size: 320).offset(x: 64, y: -48)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    TwoTone(first: model.folder?.lastPathComponent ?? "", second: model.options.film.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 16)
                    Button("Other Roll…") { model.chooseFolder() }
                        .buttonStyle(.chip(.plain))
                        .disabled(model.running)
                }
                Spacer(minLength: 32)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(bigNumber)
                        .font(Theme.pixel(76))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(bigLabel).font(Theme.l).foregroundStyle(Theme.dim)
                }
                DotField(frames: model.frames)
                    .padding(.top, 16)
            }
            .padding(24)
        }
        .frame(minHeight: 300)
        .glass(.white.opacity(0.35))
    }

    private var bigNumber: String {
        if model.running || model.finishedFolder != nil { return "\(model.done)" }
        return "\(model.frames.count)"
    }

    private var bigLabel: String {
        if model.running { return "of \(model.frames.count)" }
        if model.finishedFolder != nil { return model.done == 1 ? "positive" : "positives" }
        return model.frames.count == 1 ? "scan" : "scans"
    }
}

/// A dot per frame: orange when done, peach while it's being worked on, a ring when it failed.
struct DotField: View {
    let frames: [FrameRow]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 6), count: 18), alignment: .leading, spacing: 6) {
            ForEach(frames) { frame in
                dot(frame.state).frame(width: 12, height: 12)
            }
        }
        .animation(.easeOut(duration: 0.2), value: frames.map(\.state))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dot(_ state: FrameState) -> some View {
        switch state {
        case .waiting: Circle().fill(Theme.dotRest)
        case .measuring, .converting: Circle().fill(Theme.dotNext)
        case .done: Circle().fill(Theme.accent)
        case .failed: Circle().strokeBorder(Theme.dotRing, lineWidth: 1.5)
        }
    }
}

struct SettingsCard: View {
    @ObservedObject var model: RollModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Film") {
                ForEach(Film.allCases) { film in
                    ChoiceChip(title: film.short, on: model.options.film == film) { model.options.film = film }
                }
            }
            divider
            Toggle(isOn: $model.options.rollBalance) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("One colour balance for the roll")
                    Text("Every frame gets the same white point and colour, so the roll matches.")
                        .font(Theme.s).foregroundStyle(Theme.dim)
                }
            }
            .toggleStyle(AccentToggleStyle())
            .padding(.vertical, 16)
            divider
            row("Make") {
                ChoiceChip(title: "16-bit TIFF", on: model.options.tiff) { model.options.tiff.toggle() }
                ChoiceChip(title: "JPEG", on: model.options.jpeg) { model.options.jpeg.toggle() }
                ChoiceChip(title: "Compositor project", on: model.options.compositor && model.options.film == .color) {
                    model.options.compositor.toggle()
                }
                .disabled(model.options.film != .color)
                .help("A Compositor project with Alex Burke's layers, for colour negatives")
            }
            divider
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save to")
                    Text(model.options.output == nil ? "A Positief folder inside the roll" : (model.outputFolder?.path ?? ""))
                        .font(Theme.s)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if model.options.output != nil {
                    Button("Reset") { model.options.output = nil }.buttonStyle(.chip(.plain, height: 32))
                }
                Button("Choose…") { model.chooseOutput() }.buttonStyle(.chip(.plain, height: 32))
            }
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
        .glass()
        .disabled(model.running)
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }
}

struct FramesCard: View {
    @ObservedObject var model: RollModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.frames.enumerated()), id: \.element.id) { index, frame in
                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.pixel(14))
                        .foregroundStyle(frame.state == .done ? Theme.accentText : Theme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(frame.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if case .failed(let message) = frame.state {
                            Text(message).font(Theme.s).foregroundStyle(Theme.error)
                        } else if let note = frame.note {
                            Text(note).font(Theme.s).foregroundStyle(Theme.accentText)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(label(for: frame.state)).font(Theme.s).foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
        .glass()
    }

    private func label(for state: FrameState) -> String {
        switch state {
        case .waiting: ""
        case .measuring: "Measuring…"
        case .converting: "Converting…"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

struct Footer: View {
    @ObservedObject var model: RollModel

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if model.running {
                    Text("\(model.done) of \(model.frames.count) done…")
                } else if let error = model.error {
                    Text(error).foregroundStyle(Theme.error)
                } else if model.finishedFolder != nil {
                    Text(model.failed == 0 ? "Done: \(model.done) positives" : "Done: \(model.done) positives, \(model.failed) failed")
                } else {
                    Text("Files with the same name in the output folder are replaced.").foregroundStyle(Theme.dim)
                }
            }
            .font(Theme.s)
            .lineLimit(2)
            Spacer(minLength: 8)
            if model.finishedFolder != nil && !model.running {
                Button("Show in Finder") { model.revealOutput() }.buttonStyle(.chip(.plain, height: 56))
            }
            Button(model.running ? "Converting…" : "Convert") { model.convert() }
                .buttonStyle(.chip(.primary, height: 56))
                .keyboardShortcut(.defaultAction)
                .disabled(model.running || model.frames.isEmpty || !model.options.hasOutput)
        }
    }
}

extension Film {
    var short: String {
        switch self {
        case .color: "Colour"
        case .bw: "Black & white"
        case .positive: "Positive"
        }
    }
}
