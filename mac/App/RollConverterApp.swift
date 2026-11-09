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
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check(userInitiated: true) }
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
    /// The film stock the folder's name mentions, if any.
    @Published var stock: Roll.Stock?
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
        stock = Roll.stock(forFolder: roll)
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

    /// Back to the start, for the next roll. The settings you chose stay.
    func nextRoll() {
        guard !running else { return }
        folder = nil
        stock = nil
        frames = []
        finishedFolder = nil
        error = nil
        options.output = nil
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

    /// The window is a negative until a roll is converted, then develops into the positive.
    private var developed: Double { model.finishedFolder != nil ? 1 : 0 }

    var body: some View {
        ZStack {
            MistBackground()
            VStack(spacing: 16) {
                UpdateCard(updater: updater)
                HStack(alignment: .top, spacing: 16) {
                    FilesColumn(model: model, targeted: dropTargeted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    SettingsColumn(model: model)
                        .frame(width: 360)
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 36)
            .padding(.bottom, 20)
        }
        .font(Theme.m)
        .modifier(Develop(developed: developed))
        .animation(.easeInOut(duration: 2), value: developed)
        .onAppear {
            // A roll folder given when the app is started:  open -a "Roll Converter" --args <folder>
            if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                model.open(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.running, let provider = providers.first else { return false }
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
    @Environment(\.palette) private var p
    let first: String
    let second: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(first).foregroundStyle(p.text)
            if let second { Text(second).foregroundStyle(p.dim) }
        }
        .font(Theme.font(22))
        .tracking(-0.33)
        .lineSpacing(8)
    }
}

// MARK: Update

struct UpdateCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var updater: Updater

    var body: some View {
        if case .downloading(let build) = updater.state {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Downloading build \(build)…").font(Theme.s).foregroundStyle(p.dim)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glass()
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if case .ready(let build) = updater.state {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update").font(Theme.s).foregroundStyle(p.accentText)
                    Text("Build \(build) is ready").font(Theme.font(16))
                    Text(updater.installProblem ?? "It goes in place when you restart or quit the app.")
                        .font(Theme.s).foregroundStyle(p.dim)
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

// MARK: Files (left)

/// The file side: the drop area, which becomes the roll's card once a roll is in, and its frames.
struct FilesColumn: View {
    @ObservedObject var model: RollModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            if model.folder == nil {
                DropArea(model: model, targeted: targeted)
            } else {
                RollCard(model: model, targeted: targeted)
                FramesCard(model: model)
            }
        }
    }
}

/// The dashed edge of the drop area: quiet, in the accent colour while something is dragged over it.
struct DropEdge: View {
    @Environment(\.palette) private var p
    let targeted: Bool
    var radius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(targeted ? p.accent : p.faint.opacity(0.7),
                          style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [8, 6]))
            .padding(8)
            .allowsHitTesting(false)
    }
}

struct FilmIcon: View {
    @Environment(\.palette) private var p
    let size: CGFloat
    let targeted: Bool

    var body: some View {
        Image(systemName: targeted ? "film.stack.fill" : "film.stack")
            .font(.system(size: size * 0.46, weight: .light))
            .foregroundStyle(targeted ? p.accentText : p.text)
            .frame(width: size, height: size)
            .background(Circle().fill(p.paper.opacity(0.6)))
    }
}

/// Nothing in yet: a glass file catcher, everything centred.
struct DropArea: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RollModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            FilmIcon(size: 80, targeted: targeted).padding(.bottom, 24)
            TwoTone(first: targeted ? "Let go to open the roll" : "Drop a roll folder here", second: "or a scan from it")
            Text("Every scan becomes a positive: a 16-bit TIFF for Compositor, Photoshop and the like, and a JPEG to share.")
                .foregroundStyle(p.dim)
                .lineSpacing(4)
                .frame(maxWidth: 320)
                .padding(.top, 14)
                .padding(.bottom, 26)
            Button("Choose Roll…") { model.chooseFolder() }
                .buttonStyle(.chip(.primary, height: 48))
                .keyboardShortcut("o")
            Text("DNG, TIFF, JPEG or PNG").font(Theme.s).foregroundStyle(p.faint).padding(.top, 12)
            if let error = model.error {
                Text(error).font(Theme.s).foregroundStyle(p.error).padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(paper: targeted ? 0.55 : 0.35)
        .overlay(DropEdge(targeted: targeted))
        .contentShape(Rectangle())
        .onTapGesture { model.chooseFolder() }
        .animation(.easeOut(duration: 0.2), value: targeted)
    }
}

/// A roll is in: its name and scans, and still a place to drop the next one.
struct RollCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RollModel
    let targeted: Bool

    var body: some View {
        HStack(spacing: 16) {
            FilmIcon(size: 52, targeted: targeted)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folder?.lastPathComponent ?? "")
                    .font(Theme.font(18))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle).font(Theme.s).foregroundStyle(p.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .glass(paper: targeted ? 0.55 : 0.35)
        .overlay(DropEdge(targeted: targeted))
        .animation(.easeOut(duration: 0.2), value: targeted)
    }

    private var subtitle: String {
        let scans = "\(model.frames.count) scan\(model.frames.count == 1 ? "" : "s")"
        return model.running ? scans : "\(scans) · drop another roll to switch"
    }
}

struct FramesCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RollModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(status)
                .font(Theme.s)
                .foregroundStyle(model.error != nil && !model.running ? p.error : p.dim)
                .lineLimit(2)
                .padding(.bottom, 12)
            Rectangle().fill(p.line).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.frames.enumerated()), id: \.element.id) { index, frame in
                            if index > 0 { Rectangle().fill(p.line).frame(height: 1) }
                            row(index, frame).id(index)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: current) { index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.3)) { scroller.scrollTo(index, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glass()
    }

    /// The frame being worked on, to keep it in view.
    private var current: Int? {
        model.frames.firstIndex { $0.state == .measuring || $0.state == .converting }
    }

    private var status: String {
        if let index = current {
            let name = model.frames[index].url.lastPathComponent
            return model.frames[index].state == .measuring ? "Measuring \(name)…" : "Converting \(name)…"
        }
        if let error = model.error { return error }
        if let folder = model.finishedFolder {
            let failed = model.failed == 0 ? "" : ", \(model.failed) failed"
            return "Done\(failed): saved in \(folder.lastPathComponent)"
        }
        return "Each scan is measured first, then converted. Files with the same name are replaced."
    }

    private func row(_ index: Int, _ frame: FrameRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", index + 1))
                .font(Theme.pixel(14))
                .foregroundStyle(frame.state == .done ? p.accentText : p.faint)
            VStack(alignment: .leading, spacing: 2) {
                Text(frame.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if case .failed(let message) = frame.state {
                    Text(message).font(Theme.s).foregroundStyle(p.error)
                } else if let note = frame.note {
                    Text(note).font(Theme.s).foregroundStyle(p.accentText)
                }
            }
            Spacer(minLength: 8)
            Text(label(for: frame.state)).font(Theme.s).foregroundStyle(p.dim)
        }
        .padding(.vertical, 12)
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

// MARK: Settings (right)

/// The configuration side: the counter, the settings, and the button.
struct SettingsColumn: View {
    @ObservedObject var model: RollModel

    var body: some View {
        VStack(spacing: 12) {
            if model.folder != nil { Counter(model: model) }
            SettingsCard(model: model)
            Spacer(minLength: 0)
            Actions(model: model)
        }
    }
}

/// The big number in Geist Pixel, its words on the same baseline (the digits sit right on it).
struct Counter: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RollModel

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(number)
                .font(Theme.pixel(72))
                .monospacedDigit()
                .contentTransition(.numericText())
                .fixedSize()
            Text(words)
                .font(Theme.font(20))
                .foregroundStyle(p.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .glass()
    }

    private var finished: Bool { model.finishedFolder != nil && !model.running }
    private var number: String { model.running || finished ? "\(model.done)" : "\(model.frames.count)" }
    private var words: String {
        if model.running { return "of \(model.frames.count) converted" }
        if finished { return model.done == 1 ? "positive" : "positives" }
        return model.frames.count == 1 ? "scan" : "scans"
    }
}

struct SettingsCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: RollModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(Theme.s).foregroundStyle(p.dim).padding(.top, 18).padding(.bottom, 4)
            row("Film") {
                ForEach(Film.allCases) { film in
                    ChoiceChip(title: film.short, on: model.options.film == film) { model.options.film = film }
                }
            }
            divider
            row("Stock") {
                Text(model.stock.map { "\($0.name), from the folder name" } ?? (model.folder == nil ? "Read from the folder name" : "Not in the folder name"))
                    .font(Theme.s)
                    .foregroundStyle(p.dim)
                    .lineLimit(2)
            }
            divider
            Toggle(isOn: $model.options.rollBalance) {
                Text("One colour balance for the roll")
            }
            .toggleStyle(AccentToggleStyle())
            .help("Every frame gets the same white point and colour, so the roll matches")
            .padding(.vertical, 14)
            divider
            row("Make") {
                ChoiceChip(title: "TIFF", on: model.options.tiff) { model.options.tiff.toggle() }
                    .help("16-bit TIFF with an sRGB profile, for Compositor, Photoshop, Lightroom…")
                ChoiceChip(title: "JPEG", on: model.options.jpeg) { model.options.jpeg.toggle() }
                ChoiceChip(title: "Compositor", on: model.options.compositor && model.options.film == .color) {
                    model.options.compositor.toggle()
                }
                .disabled(model.options.film != .color)
                .help("A Compositor project with Alex Burke's layers, for colour negatives")
            }
            divider
            HStack(spacing: 8) {
                Text("Save").frame(width: 48, alignment: .leading)
                Text(model.options.output?.path ?? "Positief folder in the roll")
                    .font(Theme.s)
                    .foregroundStyle(p.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if model.options.output != nil {
                    Button("Reset") { model.options.output = nil }.buttonStyle(.chip(.plain, height: 30))
                }
                Button("Choose…") { model.chooseOutput() }.buttonStyle(.chip(.plain, height: 30))
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 22)
        .glass()
        .disabled(model.running)
    }

    private var divider: some View { Rectangle().fill(p.line).frame(height: 1) }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 48, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }
}

/// Convert; once the roll is saved, Next Roll and Show in Finder.
struct Actions: View {
    @ObservedObject var model: RollModel

    var body: some View {
        if model.finishedFolder != nil && !model.running {
            HStack(spacing: 10) {
                Button("Show in Finder") { model.revealOutput() }
                    .buttonStyle(.chip(.plain, height: 52))
                Button { model.nextRoll() } label: {
                    Text("Next Roll").frame(maxWidth: .infinity)
                }
                .buttonStyle(.chip(.primary, height: 52))
                .keyboardShortcut(.defaultAction)
            }
        } else {
            Button { model.convert() } label: {
                Text(model.running ? "Converting…" : "Convert").frame(maxWidth: .infinity)
            }
            .buttonStyle(.chip(.primary, height: 52))
            .keyboardShortcut(.defaultAction)
            .disabled(model.running || model.frames.isEmpty || !model.options.hasOutput)
        }
    }
}

extension Film {
    var short: String {
        switch self {
        case .color: "Colour"
        case .bw: "B&W"
        case .positive: "Positive"
        }
    }
}
