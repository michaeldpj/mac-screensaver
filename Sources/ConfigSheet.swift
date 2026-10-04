import AppKit
import SwiftUI

/// SwiftUI configuration panel hosted in an NSWindow for `ScreenSaverView.configureSheet`.
/// Mirrors the web `?effect=` override: Auto / four seasons / Off, plus quality toggles.
struct ConfigView: View {
    @State private var selection = Prefs.selection.storage
    @State private var bloom = Prefs.bloom
    @State private var dof = Prefs.depthOfField
    let onDone: () -> Void

    private let options: [(String, String)] = [
        ("auto", "Auto (by month)"),
        ("winter", "Winter — Snow"),
        ("spring", "Spring — Petals"),
        ("summer", "Summer — Fireflies"),
        ("autumn", "Autumn — Leaves"),
        ("off", "Off — Still backdrop"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Seasons").font(.title2.weight(.semibold))
            Picker("Season", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu)
            Toggle("Bloom", isOn: $bloom)
            Toggle("Depth of field", isOn: $dof)
            HStack {
                Spacer()
                Button("Done") {
                    Prefs.selection = SeasonSelection(storage: selection)
                    Prefs.bloom = bloom
                    Prefs.depthOfField = dof
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

enum ConfigSheet {
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Seasons"
        window.contentView = NSHostingView(rootView: ConfigView { NSApp.endSheet(window) })
        return window
    }
}
