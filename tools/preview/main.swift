// Seasons Preview — a minimal standalone app that runs the real SeasonsView/Renderer as a
// stop-gap "screensaver" (Tahoe's host does not currently load the .saver). Press Esc, any
// key, or click to quit.
//
// Display policy (see docs/CRASH-ANALYSIS.md — three SoC panics): simultaneous full pipelines
// on every display panic the M5's display power rail even in SDR, while a single animated
// display is proven stable. Default is therefore ONE animated display (the built-in panel) with
// plain black cover windows on the rest — zero GPU work, and pure black matches the art
// direction anyway. `SEASONS_ALL_DISPLAYS=1` opts into the known-dangerous simultaneous mode.
// `SEASONS_SINGLE_DISPLAY=1` animates the built-in panel with no covers (ladder isolation).
import AppKit
import ScreenSaver

final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { NSApp.terminate(nil) }
    override func mouseDown(with event: NSEvent) { NSApp.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [PreviewWindow] = []
    var savers: [ScreenSaverView] = []
    private var screenChangeObserver: NSObjectProtocol?

    private func makeWindow(on screen: NSScreen) -> PreviewWindow {
        let window = PreviewWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver          // cover everything, like a real screensaver
        window.isOpaque = true
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        window.setFrame(screen.frame, display: true)   // this screen's global coordinates
        return window
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // optional season override: `Seasons Preview <winter|spring|summer|autumn|rain|off>`
        if CommandLine.arguments.count > 1 {
            setenv("SEASONS_FORCE", CommandLine.arguments[1], 1)
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            // A preview is disposable. Terminating is safer than migrating or rebuilding a
            // renderer while WindowServer is reassigning screens and drawable ownership.
            NSLog("Seasons Preview: display topology changed; terminating fail-closed")
            NSApp.terminate(nil)
        }

        for surface in DisplayPolicy.surfaces() {
            let window = DisplayPolicy.makeWindow(PreviewWindow.self, on: surface.screen)
            let size = surface.screen.frame.size
            if surface.animated,
               let view = SeasonsView(frame: NSRect(origin: .zero, size: size), isPreview: false) {
                view.tier = surface.tier
                view.isSecondary = surface.isSecondary
                view.isMultiDisplay = surface.isMultiDisplay
                view.panorama = surface.panorama
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                view.startAnimation()
                savers.append(view)
            } else {
                // plain black cover: no Metal layer, no display link, no per-frame work
                window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
            }
            window.orderFrontRegardless()
            windows.append(window)
        }

        if windows.isEmpty { NSApp.terminate(nil); return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        savers.forEach { $0.stopAnimation() }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    deinit {
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
