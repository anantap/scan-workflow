import AppKit
import CoreGraphics
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
                Button("Open…") { model.chooseFolder() }
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
    /// Small pictures: the scan as it is (the negative), and the positive once it's converted.
    var negative: CGImage?
    var positive: CGImage?
    var id: URL { url }
}

@MainActor
final class RollModel: ObservableObject {
    /// The roll's folder; for scans picked one by one, the folder they're in.
    @Published var folder: URL?
    /// Scans picked one by one, or nil for the whole roll in `folder`.
    @Published var picked: [URL]?
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
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .tiff, .jpeg, .png] + Roll.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Choose"
        panel.message = "Choose a roll's folder, or one or more scans"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(panel.urls)
    }

    func open(_ url: URL) { open([url]) }

    /// A folder is a roll: all its scans. Files are just those scans.
    func open(_ urls: [URL]) {
        guard !running, let first = urls.first else { return }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isFolder) else { return }
        let roll: URL
        if urls.count == 1 && isFolder.boolValue {
            roll = first
            picked = nil
            frames = Roll.scans(in: roll).map { FrameRow(url: $0) }
            error = frames.isEmpty ? "No scans (DNG, TIFF, JPEG or PNG) in this folder." : nil
        } else {
            let scans = Roll.sorted(urls.filter(Roll.isScan))
            roll = (scans.first ?? first).deletingLastPathComponent()
            picked = scans
            frames = scans.map { FrameRow(url: $0) }
            error = scans.isEmpty ? "These aren't scans: drop DNG, TIFF, JPEG or PNG files, or a roll's folder." : nil
        }
        folder = roll
        stock = Roll.stock(forFolder: roll)
        options.film = Roll.film(forFolder: roll) ?? .color
        options.output = nil
        finishedFolder = nil
        loadThumbnails()
    }

    /// Reads a small picture of each scan, a few at a time, in the background.
    private func loadThumbnails() {
        let urls = frames.map(\.url)
        Task.detached(priority: .utility) { [weak self] in
            let load = { (url: URL) async in
                let image = ImageFiles.thumbnail(of: url, size: 480)
                await MainActor.run {
                    guard let self, let index = self.frames.firstIndex(where: { $0.url == url }) else { return }
                    self.frames[index].negative = image
                }
            }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < min(4, urls.count) {
                    let url = urls[next]
                    next += 1
                    group.addTask { await load(url) }
                }
                while await group.next() != nil, next < urls.count {
                    let url = urls[next]
                    next += 1
                    group.addTask { await load(url) }
                }
            }
        }
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
        for index in frames.indices {
            frames[index].state = .waiting
            frames[index].note = nil
            frames[index].positive = nil
        }
        let options = self.options
        let files = frames.map(\.url)
        let scripts = [Bundle.main.resourceURL].compactMap { $0 }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let engine = try Engine(scriptFolders: scripts)
                let converter = RollConverter(engine: engine)
                converter.preview = { index, image in
                    Task { @MainActor in
                        guard let self, self.frames.indices.contains(index) else { return }
                        self.frames[index].positive = image
                    }
                }
                let output = try converter.run(files: files, folder: folder, options: options) { index, state, note in
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
        picked = nil
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
            guard !model.running, !providers.isEmpty else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.url(from: provider) { urls.append(url) }
                }
                model.open(urls)
            }
            return true
        }
    }
}

extension ContentView {
    /// The file a dropped item stands for.
    static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
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
            TwoTone(first: targeted ? "Let go to open them" : "Drop a roll folder here", second: "or just a few scans")
            Text("A folder converts the whole roll with one colour balance; scans you pick convert on their own. Each becomes a 16-bit TIFF and a JPEG.")
                .foregroundStyle(p.dim)
                .lineSpacing(4)
                .frame(maxWidth: 320)
                .padding(.top, 14)
                .padding(.bottom, 26)
            Button("Choose…") { model.chooseFolder() }
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
        .scaleEffect(targeted ? 1.01 : 1)
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
                Text(title)
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
        .scaleEffect(targeted ? 1.01 : 1)
        .animation(.easeOut(duration: 0.2), value: targeted)
    }

    private var title: String {
        guard let picked = model.picked else { return model.folder?.lastPathComponent ?? "" }
        return picked.count == 1 ? picked[0].lastPathComponent : "\(picked.count) scans"
    }

    private var subtitle: String {
        let scans = "\(model.frames.count) scan\(model.frames.count == 1 ? "" : "s")"
        let what = model.picked == nil ? scans : "from \(model.folder?.lastPathComponent ?? "")"
        return model.running ? what : "\(what) · drop others to switch"
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 16) {
                        ForEach(Array(model.frames.enumerated()), id: \.element.id) { index, frame in
                            FrameTile(index: index, frame: frame).id(index)
                        }
                    }
                    .padding(.vertical, 16)
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
}

/// A frame: the negative while it waits, the positive once it's converted.
struct FrameTile: View {
    @Environment(\.palette) private var p
    let index: Int
    let frame: FrameRow

    private var working: Bool { frame.state == .measuring || frame.state == .converting }
    private var converted: Bool { frame.state == .done && frame.positive != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(p.dotRest)
                picture(frame.negative)
                picture(frame.positive).opacity(converted ? 1 : 0)
                if working { Shimmer() }
                if case .failed = frame.state {
                    Rectangle().fill(.black.opacity(0.35))
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.white)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeInOut(duration: 0.6), value: converted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", index + 1))
                    .font(Theme.pixel(13))
                    .foregroundStyle(frame.state == .done ? p.accentText : p.faint)
                Text(frame.url.lastPathComponent)
                    .font(Theme.s)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if case .failed(let message) = frame.state {
                Text(message).font(Theme.s).foregroundStyle(p.error).lineLimit(2)
            } else if let note = frame.note {
                Text(note).font(Theme.s).foregroundStyle(p.accentText).lineLimit(2)
            }
        }
        .help(help)
    }

    @ViewBuilder
    private func picture(_ image: CGImage?) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        }
    }

    private var help: String {
        switch frame.state {
        case .failed(let message): "\(frame.url.lastPathComponent): \(message)"
        default: frame.note.map { "\(frame.url.lastPathComponent): \($0)" } ?? frame.url.lastPathComponent
        }
    }
}

/// A light sweep across the frame being converted.
struct Shimmer: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, p.paper.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.6)
                .offset(x: moving ? geo.size.width : -geo.size.width * 0.6)
        }
        .opacity(reduceMotion ? 0 : 1)
        .overlay(reduceMotion ? p.paper.opacity(0.18) : .clear)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { moving = true }
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
