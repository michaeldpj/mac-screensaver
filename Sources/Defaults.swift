import Foundation

/// Persisted preferences shared by the menu-bar app, the preview tool, and the .saver.
///
/// Backing store is a plain UserDefaults suite (~/Library/Preferences/me.mdpj.Seasons.plist),
/// NOT ScreenSaverDefaults: that class only persists reliably inside the legacy screensaver
/// host — written from the menu-bar app its values silently vanished (no ByHost domain was
/// ever created), so every picker choice reverted to Auto.
enum Prefs {
    private static let store = UserDefaults(suiteName: "me.mdpj.Seasons")!

    static var selection: SeasonSelection {
        get { SeasonSelection(storage: store.string(forKey: "selection") ?? "auto") }
        set { store.set(newValue.storage, forKey: "selection") }
    }

    /// Raw selection string. Non-season styles (rain, embers, stars) are not representable in
    /// SeasonSelection — they load by name — so pickers that offer them must use this.
    static var selectionName: String {
        get { store.string(forKey: "selection") ?? "auto" }
        set { store.set(newValue, forKey: "selection") }
    }

    static var bloom: Bool {
        get { store.object(forKey: "bloom") == nil ? true : store.bool(forKey: "bloom") }
        set { store.set(newValue, forKey: "bloom") }
    }

    static var depthOfField: Bool {
        get { store.object(forKey: "dof") == nil ? true : store.bool(forKey: "dof") }
        set { store.set(newValue, forKey: "dof") }
    }

    /// Explicit opt-in used only when Seasons.app passes it into DisplayPolicy. Merely storing
    /// this value does not authorize the legacy saver or preview, whose calls default to false.
    static var externalUltraLite: Bool {
        get { store.bool(forKey: "externalUltraLite") }
        set { store.set(newValue, forKey: "externalUltraLite") }
    }
}
