// Seasons — standalone menu-bar screensaver. Tahoe's legacy host loads third-party .saver
// bundles unreliably, so this app IS the product: it watches for idle, fades the seasonal
// engine in fullscreen, and dismisses on any input.
//
// Display policy (docs/CRASH-ANALYSIS.md): the built-in display animates; other displays get
// plain black cover windows — simultaneous multi-display pipelines panic the M5's display
// power rail. The persisted External Ultra-Lite menu item opts into the bounded 2880/30 FPS
// path; `SEASONS_ALL_DISPLAYS=1` remains a separate dangerous crash-reproduction mode.
import AppKit
import ScreenSaver
import ServiceManagement

final class SaverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var idleTimer: Timer?
    private var windows: [SaverWindow] = []
    private var savers: [SeasonsView] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var running = false
    private var startedAt: CFTimeInterval = 0

    private let defaults = UserDefaults.standard
    private var idleMinutes: Int {
        get { defaults.object(forKey: "idleMinutes") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "idleMinutes"); rebuildMenu() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "leaf.fill",
                                           accessibilityDescription: "Seasons")
        rebuildMenu()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.displayTopologyChanged()
        }
    }

    deinit {
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }

    // MARK: menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Start Now", action: #selector(startNow), keyEquivalent: "s").target = self

        let seasonMenu = NSMenu()
        let current = Prefs.selectionName
        for (title, value) in [("Auto (by month)", "auto"), ("Winter", "winter"), ("Spring", "spring"),
                               ("Summer", "summer"), ("Autumn", "autumn"), ("Rain", "rain"),
                               ("Embers", "embers"), ("Stars", "stars"), ("Off (backdrop)", "off")] {
            let item = NSMenuItem(title: title, action: #selector(pickSeason(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state = value == current ? .on : .off
            item.target = self
            seasonMenu.addItem(item)
        }
        let seasonItem = NSMenuItem(title: "Season", action: nil, keyEquivalent: "")
        seasonItem.submenu = seasonMenu
        menu.addItem(seasonItem)

        let idleMenu = NSMenu()
        for (title, mins) in [("Never", 0), ("5 minutes", 5), ("10 minutes", 10),
                              ("15 minutes", 15), ("30 minutes", 30)] {
            let item = NSMenuItem(title: title, action: #selector(pickIdle(_:)), keyEquivalent: "")
            item.representedObject = mins
            item.state = mins == idleMinutes ? .on : .off
            item.target = self
            idleMenu.addItem(item)
        }
        let idleItem = NSMenuItem(title: "Start After Idle", action: nil, keyEquivalent: "")
        idleItem.submenu = idleMenu
        menu.addItem(idleItem)

        let external = NSMenuItem(
            title: "External Displays — Ultra-Lite 30 FPS",
            action: #selector(toggleExternalUltraLite),
            keyEquivalent: ""
        )
        external.state = Prefs.externalUltraLite ? .on : .off
        external.target = self
        menu.addItem(external)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Seasons", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func pickSeason(_ sender: NSMenuItem) {
        // raw string, not SeasonSelection: named styles (rain/embers/stars) round-trip by name
        Prefs.selectionName = sender.representedObject as? String ?? "auto"
        rebuildMenu()
    }

    @objc private func pickIdle(_ sender: NSMenuItem) {
        idleMinutes = sender.representedObject as? Int ?? 10
    }

    @objc private func toggleExternalUltraLite() {
        Prefs.externalUltraLite.toggle()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Seasons: launch-at-login toggle failed: \(error)")
        }
        rebuildMenu()
    }

    // MARK: idle watch

    private func systemIdleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    private func checkIdle() {
        guard !running, idleMinutes > 0 else { return }
        if systemIdleSeconds() >= Double(idleMinutes * 60) { startNow() }
    }

    // MARK: run / dismiss

    @objc func startNow() {
        guard !running else { return }
        running = true
        startedAt = CACurrentMediaTime()

        for surface in DisplayPolicy.surfaces(appExternalUltraLite: Prefs.externalUltraLite) {
            let window = DisplayPolicy.makeWindow(SaverWindow.self, on: surface.screen)
            let size = surface.screen.frame.size
            if surface.animated,
               let view = SeasonsView(frame: NSRect(origin: .zero, size: size), isPreview: false) {
                view.tier = surface.tier
                view.isSecondary = surface.isSecondary
                view.isMultiDisplay = surface.isMultiDisplay
                view.panorama = surface.panorama
                window.contentView = view
                savers.append(view)
            } else {
                window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
            }
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKey()
        savers.forEach { $0.startAnimation() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            windows.forEach { $0.animator().alphaValue = 1 }
        }

        // any input dismisses — but ignore the first moments so the launching click doesn't
        let dismiss: (NSEvent) -> Void = { [weak self] _ in self?.dismiss() }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel],
            handler: dismiss)
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] e in
            self?.dismiss()
            return nil
        }
    }

    private func displayTopologyChanged() {
        guard running else { return }
        // Do not rebuild/migrate active Metal views while WindowServer is changing ownership.
        // The next idle/start request obtains a fresh DisplayPolicy plan for the new topology.
        NSLog("Seasons: display topology changed; ending the active session fail-closed")
        dismiss(force: true)
    }

    private func dismiss(force: Bool = false) {
        guard running, force || CACurrentMediaTime() - startedAt > 1.0 else { return }
        running = false
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        savers.forEach { $0.stopAnimation() }
        let toClose = windows
        windows = []; savers = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            toClose.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            toClose.forEach { $0.orderOut(nil) }
        })
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
