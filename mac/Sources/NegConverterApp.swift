import AppKit
import SwiftUI
import WebKit

@main
struct NegConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var web = WebController()

    var body: some Scene {
        Window("Negatief Converter", id: "main") {
            WebView(controller: web)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scans openen…") { web.openScans() }
                    .keyboardShortcut("o")
                Divider()
                Button("Exportmap kiezen…") { web.chooseExportFolder(reply: nil) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Exportmap tonen in Finder") { web.revealExportFolder() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // De interface is donker; laat de titelbalk en menu's meedoen.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct WebView: NSViewRepresentable {
    let controller: WebController

    func makeNSView(context: Context) -> WKWebViewContainer {
        WKWebViewContainer(webView: controller.webView)
    }

    func updateNSView(_ nsView: WKWebViewContainer, context: Context) {}
}
