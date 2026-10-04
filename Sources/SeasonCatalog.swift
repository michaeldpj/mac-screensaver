import Foundation

// Must subclass NSObject: Bundle(for:) resolves a class's bundle via the ObjC runtime image.
// A pure-Swift class in a loaded plugin can misresolve to Bundle.main (the host process),
// which for a .saver is legacyScreenSaver and has none of our resources.
private final class CatalogMarker: NSObject {}

enum SeasonCatalog {
    static func seasonByMonth(_ m: Int) -> SeasonID {
        if m == 11 || m == 0 || m == 1 { return .winter }
        if m >= 2 && m <= 4 { return .spring }
        if m >= 5 && m <= 7 { return .summer }
        return .autumn
    }

    /// The season id to display, ignoring `.off`.
    static func resolve(_ sel: SeasonSelection, month: Int) -> SeasonID {
        switch sel {
        case .auto: return seasonByMonth(month)
        case .fixed(let id): return id
        case .off: return seasonByMonth(month)
        }
    }

    /// nil when selection is `.off` (caller renders static atmosphere only).
    static func resolveActive(_ sel: SeasonSelection, month: Int) -> SeasonID? {
        if case .off = sel { return nil }
        return resolve(sel, month: month)
    }

    /// Decodes <id>.json from the bundle's seasons/ folder. Returns nil if the file is missing
    /// or unreadable (never crashes — a missing season config must not take down the screensaver).
    static func load(_ id: SeasonID,
                     bundle: Bundle = Bundle(for: CatalogMarker.self)) -> Season? {
        return loadNamed(id.rawValue, bundle: bundle)
    }

    /// Loads any seasons/<name>.json, including non-seasonal styles like "rain".
    static func loadNamed(_ name: String,
                          bundle: Bundle = Bundle(for: CatalogMarker.self)) -> Season? {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "seasons"),
              let data = try? Data(contentsOf: url),
              let season = try? JSONDecoder().decode(Season.self, from: data) else { return nil }
        return season
    }

    /// The season to display for the given selection/month, falling back to any available
    /// config so an unauthored season never leaves the screen blank.
    static func displaySeason(_ sel: SeasonSelection, month: Int,
                              bundle: Bundle = Bundle(for: CatalogMarker.self)) -> Season? {
        guard let id = resolveActive(sel, month: month) else { return nil }
        if let s = load(id, bundle: bundle) { return s }
        for fallback in SeasonID.allCases where fallback != id {
            if let s = load(fallback, bundle: bundle) { return s }
        }
        return nil
    }
}
