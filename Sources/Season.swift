import simd

enum GlyphType: String, Codable { case image, glow, streak }

/// Species motion model (Phase C). Raw values match the MODEL_* defines in ShaderTypes.h.
enum MotionModel: String, Codable {
    case generic, leaf, petal, snow, firefly, rain, samara
    var raw: UInt32 {
        switch self {
        case .generic: return 0
        case .leaf: return 1
        case .petal: return 2
        case .snow: return 3
        case .firefly: return 4
        case .rain: return 5
        case .samara: return 6
        }
    }
}

/// One species inside a season (Phase F). Absent fields inherit the season's values.
struct SpeciesDef: Decodable {
    let spriteSet: String
    let spriteCount: Int
    let weight: Float
    let motionModel: MotionModel?
    let sizeMin: Float?
    let sizeMax: Float?
    let curl: CurlOverrides?
    let material: MaterialOverrides?
    let aero: AeroOverrides?
    let hueJitterDeg: Float?
}

struct CurlOverrides: Decodable {
    let cup: Float?
    let fold: Float?
    let curl: Float?
    let grid: Int?
}

/// Optional surface-material overrides (Phase E); absent fields use per-model defaults.
struct MaterialOverrides: Decodable {
    let sssColorP3: SIMD3<Float>?
    let sssStrength: Float?
    let specStrength: Float?
    let specPower: Float?
    let sparkle: Float?
    let normalStrength: Float?
    let aoStrength: Float?

    private enum K: String, CodingKey {
        case sssColor, sssStrength, specStrength, specPower, sparkle, normalStrength, aoStrength
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        if let o = try c.decodeIfPresent(OKLCHColor.self, forKey: .sssColor) {
            sssColorP3 = oklchToLinearP3(L: o.L, C: o.C, H: o.H)
        } else { sssColorP3 = nil }
        sssStrength = try c.decodeIfPresent(Float.self, forKey: .sssStrength)
        specStrength = try c.decodeIfPresent(Float.self, forKey: .specStrength)
        specPower = try c.decodeIfPresent(Float.self, forKey: .specPower)
        sparkle = try c.decodeIfPresent(Float.self, forKey: .sparkle)
        normalStrength = try c.decodeIfPresent(Float.self, forKey: .normalStrength)
        aoStrength = try c.decodeIfPresent(Float.self, forKey: .aoStrength)
    }
}

/// Optional choreography overrides (Phase D); absent fields use defaults.
struct ChoreoOverrides: Decodable {
    let depthBias: Float?          // depth = mix(min,max,pow(rnd,bias)); 1 = uniform
    let sizeDepthCoupling: Float?  // 0..1 size follows depth
    let baselineFraction: Float?   // fraction active in calm air; rest gust-released
    let releaseWind: Float?        // local wind (pt/s) that releases a parked reserve
    let heroCount: Int?            // scripted hero slots; 0 disables
    let heroEvery: [Float]?        // [min,max] mean seconds between hero crossings
}

/// Optional per-season aerodynamics overrides; absent fields use per-model defaults.
struct AeroOverrides: Decodable {
    let flutterAmp: Float?      // leaf/petal peak attack angle (radians)
    let flutterFreq: Float?     // rocking rate (Hz)
    let tumbleChance: Float?    // leaf: chance per mode-roll of autorotation
    let gyroRadius: Float?      // petal helix radius (points)
    let microTurb: Float?       // snow micro-turbulence (points/sec at smallest size)
    let flashOn: Float?         // firefly flash duration (s)
    let flashInterval: [Float]? // firefly dark-gap range [min, max] (s)
    let attractorWeight: Float? // firefly attraction strength
}

enum SeasonID: String, CaseIterable, Codable {
    case winter, spring, summer, autumn
    var effect: String {
        switch self {
        case .winter: return "snow"
        case .spring: return "petals"
        case .summer: return "fireflies"
        case .autumn: return "leaves"
        }
    }
}

enum SeasonSelection: Equatable {
    case auto
    case fixed(SeasonID)
    case off

    /// Round-trips through a defaults string. Unknown values fall back to `.auto`.
    init(storage: String) {
        switch storage {
        case "off": self = .off
        case "auto": self = .auto
        default:
            if let id = SeasonID(rawValue: storage) { self = .fixed(id) } else { self = .auto }
        }
    }

    var storage: String {
        switch self {
        case .auto: return "auto"
        case .off: return "off"
        case .fixed(let id): return id.rawValue
        }
    }
}

private struct OKLCHColor: Codable { let L, C, H, alpha: Float }

/// Optional per-season lighting overrides. Every field optional: absent fields keep the
/// engine defaults, so seasons are tunable in JSON without recompiling.
struct LightOverrides: Decodable {
    let keyDir: [Float]?
    let keyColorP3: SIMD3<Float>?
    let keyIntensity: Float?
    let ambientColorP3: SIMD3<Float>?
    let ambientIntensity: Float?
    let translucency: Float?
    let specular: Float?
    let rimDir: [Float]?
    let rimColorP3: SIMD3<Float>?
    let rimIntensity: Float?

    private enum K: String, CodingKey {
        case keyDir, keyColor, keyIntensity, ambientColor, ambientIntensity
        case translucency, specular, rimDir, rimColor, rimIntensity
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func color(_ k: K) throws -> SIMD3<Float>? {
            guard let o = try c.decodeIfPresent(OKLCHColor.self, forKey: k) else { return nil }
            return oklchToLinearP3(L: o.L, C: o.C, H: o.H)
        }
        keyDir = try c.decodeIfPresent([Float].self, forKey: .keyDir)
        keyColorP3 = try color(.keyColor)
        keyIntensity = try c.decodeIfPresent(Float.self, forKey: .keyIntensity)
        ambientColorP3 = try color(.ambientColor)
        ambientIntensity = try c.decodeIfPresent(Float.self, forKey: .ambientIntensity)
        translucency = try c.decodeIfPresent(Float.self, forKey: .translucency)
        specular = try c.decodeIfPresent(Float.self, forKey: .specular)
        rimDir = try c.decodeIfPresent([Float].self, forKey: .rimDir)
        rimColorP3 = try color(.rimColor)
        rimIntensity = try c.decodeIfPresent(Float.self, forKey: .rimIntensity)
    }
}

/// Optional per-season wind-field overrides; absent fields derive sensible values from the
/// legacy `windMax` so existing configs keep working.
struct WindOverrides: Decodable {
    let base: Float?
    let turbulence: Float?
    let fieldScale: Float?
    let evolve: Float?
    let gustEvery: [Float]?
    let gustStrength: Float?
    let gustWidth: Float?
    let relaxTau: Float?
}

/// Optional per-season grade overrides — same contract as LightOverrides.
struct GradeOverrides: Decodable {
    let exposure: Float?
    let saturation: Float?
    let vignette: Float?
    let grain: Float?
    let caStrength: Float?
    let filmicWhite: Float?
    let shadowTintP3: SIMD3<Float>?
    let highlightTintP3: SIMD3<Float>?
    let bloomMix: [Float]?

    private enum K: String, CodingKey {
        case exposure, saturation, vignette, grain, caStrength, filmicWhite
        case shadowTint, highlightTint, bloomMix
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func color(_ k: K) throws -> SIMD3<Float>? {
            guard let o = try c.decodeIfPresent(OKLCHColor.self, forKey: k) else { return nil }
            return oklchToLinearP3(L: o.L, C: o.C, H: o.H)
        }
        exposure = try c.decodeIfPresent(Float.self, forKey: .exposure)
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation)
        vignette = try c.decodeIfPresent(Float.self, forKey: .vignette)
        grain = try c.decodeIfPresent(Float.self, forKey: .grain)
        caStrength = try c.decodeIfPresent(Float.self, forKey: .caStrength)
        filmicWhite = try c.decodeIfPresent(Float.self, forKey: .filmicWhite)
        shadowTintP3 = try color(.shadowTint)
        highlightTintP3 = try color(.highlightTint)
        bloomMix = try c.decodeIfPresent([Float].self, forKey: .bloomMix)
    }
}

struct Season: Decodable {
    let name: String
    let glyphType: GlyphType
    let spriteSet: String?
    let spriteCount: Int
    let count: Int
    let sizeMin, sizeMax, vyMin, vyMax, vxMin, vxMax: Float
    let swayAmp, swayPeriodMin, swayPeriodMax: Float
    let rotate: Bool, rotateSpeed: Float
    let tumble: Bool, tumbleSpeed: Float
    let glow: Bool, pulse: Bool
    let spriteOpacity: Float
    let depthMin, depthMax: Float
    let bloomThreshold, bloomIntensity, dofStrength, edrHeadroom: Float
    let windMax: Float
    let colorP3: SIMD4<Float>   // linear P3 rgb + straight alpha
    let tintP3: SIMD4<Float>
    let light: LightOverrides?
    let grade: GradeOverrides?
    let wind: WindOverrides?
    let motionModel: MotionModel
    let aero: AeroOverrides?
    let choreo: ChoreoOverrides?
    let material: MaterialOverrides?
    let hueJitterDeg: Float
    let species: [SpeciesDef]?
    let heroSpecies: SpeciesDef?   // optional dedicated hero population (own sprites/range)

    private enum CodingKeys: String, CodingKey {
        case name, glyphType, spriteSet, spriteCount, count
        case sizeMin, sizeMax, vyMin, vyMax, vxMin, vxMax
        case swayAmp, swayPeriodMin, swayPeriodMax
        case rotate, rotateSpeed, tumble, tumbleSpeed, glow, pulse, spriteOpacity
        case depthMin, depthMax, bloomThreshold, bloomIntensity, dofStrength, edrHeadroom
        case windMax
        case color, tint
        case light, grade, wind, motionModel, aero, choreo, material, hueJitterDeg, species
        case heroSpecies
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        glyphType = try c.decode(GlyphType.self, forKey: .glyphType)
        spriteSet = try c.decodeIfPresent(String.self, forKey: .spriteSet)
        spriteCount = try c.decode(Int.self, forKey: .spriteCount)
        count = try c.decode(Int.self, forKey: .count)
        sizeMin = try c.decode(Float.self, forKey: .sizeMin)
        sizeMax = try c.decode(Float.self, forKey: .sizeMax)
        vyMin = try c.decode(Float.self, forKey: .vyMin)
        vyMax = try c.decode(Float.self, forKey: .vyMax)
        vxMin = try c.decode(Float.self, forKey: .vxMin)
        vxMax = try c.decode(Float.self, forKey: .vxMax)
        swayAmp = try c.decode(Float.self, forKey: .swayAmp)
        swayPeriodMin = try c.decode(Float.self, forKey: .swayPeriodMin)
        swayPeriodMax = try c.decode(Float.self, forKey: .swayPeriodMax)
        rotate = try c.decode(Bool.self, forKey: .rotate)
        rotateSpeed = try c.decode(Float.self, forKey: .rotateSpeed)
        tumble = try c.decode(Bool.self, forKey: .tumble)
        tumbleSpeed = try c.decode(Float.self, forKey: .tumbleSpeed)
        glow = try c.decode(Bool.self, forKey: .glow)
        pulse = try c.decode(Bool.self, forKey: .pulse)
        spriteOpacity = try c.decode(Float.self, forKey: .spriteOpacity)
        depthMin = try c.decode(Float.self, forKey: .depthMin)
        depthMax = try c.decode(Float.self, forKey: .depthMax)
        bloomThreshold = try c.decode(Float.self, forKey: .bloomThreshold)
        bloomIntensity = try c.decode(Float.self, forKey: .bloomIntensity)
        dofStrength = try c.decode(Float.self, forKey: .dofStrength)
        edrHeadroom = try c.decode(Float.self, forKey: .edrHeadroom)
        windMax = try c.decodeIfPresent(Float.self, forKey: .windMax) ?? 0
        let col = try c.decode(OKLCHColor.self, forKey: .color)
        let tnt = try c.decode(OKLCHColor.self, forKey: .tint)
        let crgb = oklchToLinearP3(L: col.L, C: col.C, H: col.H)
        let trgb = oklchToLinearP3(L: tnt.L, C: tnt.C, H: tnt.H)
        colorP3 = SIMD4(crgb, col.alpha)
        tintP3 = SIMD4(trgb, tnt.alpha)
        light = try c.decodeIfPresent(LightOverrides.self, forKey: .light)
        grade = try c.decodeIfPresent(GradeOverrides.self, forKey: .grade)
        wind = try c.decodeIfPresent(WindOverrides.self, forKey: .wind)
        motionModel = try c.decodeIfPresent(MotionModel.self, forKey: .motionModel) ?? .generic
        aero = try c.decodeIfPresent(AeroOverrides.self, forKey: .aero)
        choreo = try c.decodeIfPresent(ChoreoOverrides.self, forKey: .choreo)
        material = try c.decodeIfPresent(MaterialOverrides.self, forKey: .material)
        hueJitterDeg = try c.decodeIfPresent(Float.self, forKey: .hueJitterDeg) ?? 0
        species = try c.decodeIfPresent([SpeciesDef].self, forKey: .species)
        heroSpecies = try c.decodeIfPresent(SpeciesDef.self, forKey: .heroSpecies)
    }

    /// A fully-resolved species: everything the sim and renderer need for one sub-population.
    struct ResolvedSpecies {
        let spriteSet: String?
        let spriteCount: Int
        let weight: Float
        let motionModel: MotionModel
        let sizeMin, sizeMax: Float
        let curl: CurlOverrides?
        let material: MaterialParams
        let aero: Aero
        let hueJitterRad: Float
        let isHero: Bool   // dedicated hero range: count = heroCount, all slots scripted
    }

    private func resolve(_ sp: SpeciesDef, isHero: Bool = false) -> ResolvedSpecies {
        let model = sp.motionModel ?? motionModel
        var mat = Season.defaultMaterial(for: model)
        Season.applyMaterial(material, to: &mat)      // season-level overrides first
        Season.applyMaterial(sp.material, to: &mat)   // species-level wins
        return ResolvedSpecies(spriteSet: sp.spriteSet, spriteCount: sp.spriteCount,
                               weight: max(sp.weight, 0.01), motionModel: model,
                               sizeMin: sp.sizeMin ?? sizeMin, sizeMax: sp.sizeMax ?? sizeMax,
                               curl: sp.curl, material: mat,
                               aero: Season.resolveAero(model: model, species: sp.aero, season: aero),
                               hueJitterRad: (sp.hueJitterDeg ?? hueJitterDeg) * .pi / 180,
                               isHero: isHero)
    }

    /// The season's species list — the legacy single-set fields become a one-species array.
    /// A `heroSpecies` (if declared and heroes are enabled) is prepended as its own range so
    /// hero crossings can wear different art than the ambient fall (whole blossom, big crystal).
    var speciesResolved: [ResolvedSpecies] {
        var out: [ResolvedSpecies]
        if let species, !species.isEmpty {
            out = species.map { resolve($0) }
        } else {
            out = [ResolvedSpecies(spriteSet: spriteSet, spriteCount: spriteCount, weight: 1,
                                   motionModel: motionModel, sizeMin: sizeMin, sizeMax: sizeMax,
                                   curl: nil, material: materialResolved, aero: aeroResolved,
                                   hueJitterRad: hueJitterDeg * .pi / 180, isHero: false)]
        }
        if let heroSpecies, choreoResolved.heroCount > 0 {
            out.insert(resolve(heroSpecies, isHero: true), at: 0)
        }
        return out
    }

    static func defaultMaterial(for model: MotionModel) -> MaterialParams {
        var m = MaterialParams()
        switch model {
        case .leaf:
            m.sssColor = SIMD3(1.0, 0.42, 0.10); m.sssStrength = 0.9
            m.normalStrength = 0.8; m.aoStrength = 0.6; m.sparkle = 0
        case .petal:
            m.sssColor = SIMD3(1.0, 0.50, 0.55); m.sssStrength = 1.1
            m.normalStrength = 0.5; m.aoStrength = 0.4; m.sparkle = 0
        case .snow:
            m.sssColor = SIMD3(0.45, 0.65, 1.0); m.sssStrength = 0.5
            m.normalStrength = 0.6; m.aoStrength = 0.3; m.sparkle = 1.2
        case .samara:
            m.sssColor = SIMD3(1.0, 0.75, 0.40); m.sssStrength = 1.2   // papery translucent wing
            m.normalStrength = 0.6; m.aoStrength = 0.5; m.sparkle = 0
        default:
            m.sssColor = SIMD3(1, 1, 1); m.sssStrength = 0.4
            m.normalStrength = 0.5; m.aoStrength = 0.5; m.sparkle = 0
        }
        m.specStrength = 1.0
        m.specPower = model == .snow ? 180 : 60
        return m
    }

    static func applyMaterial(_ o: MaterialOverrides?, to m: inout MaterialParams) {
        guard let o else { return }
        if let v = o.sssColorP3 { m.sssColor = v }
        if let v = o.sssStrength { m.sssStrength = v }
        if let v = o.specStrength { m.specStrength = v }
        if let v = o.specPower { m.specPower = v }
        if let v = o.sparkle { m.sparkle = v }
        if let v = o.normalStrength { m.normalStrength = v }
        if let v = o.aoStrength { m.aoStrength = v }
    }

    /// MaterialParams resolved against per-model defaults (single-species path).
    var materialResolved: MaterialParams {
        var m = Season.defaultMaterial(for: motionModel)
        Season.applyMaterial(material, to: &m)
        return m
    }

    /// Choreography resolved against defaults. Heroes default ON only for the showcase-worthy
    /// flat-object models (leaf, petal); fireflies/snow/rain default to none.
    var choreoResolved: (depthBias: Float, sizeDepthCoupling: Float, baselineFraction: Float,
                         releaseWind: Float, heroCount: Int, heroEveryMin: Float, heroEveryMax: Float) {
        // Heroes perform a leaf/petal flutter-tumble showcase; other models would mime it
        // wrongly, so the count clamps to 0 — unless the season declares a dedicated
        // heroSpecies, which brings its own art and aero for the crossing.
        let heroAllowed = motionModel == .leaf || motionModel == .petal || heroSpecies != nil
        let heroDefault = heroAllowed ? 3 : 0
        let baselineDefault: Float
        switch motionModel {
        case .firefly, .generic: baselineDefault = 1.0   // populations that should never thin
        case .rain: baselineDefault = 0.8                // light squall variation
        default: baselineDefault = 0.6                   // calm field, gusts shake more loose
        }
        return (
            choreo?.depthBias ?? 2.2,
            choreo?.sizeDepthCoupling ?? 0.65,
            choreo?.baselineFraction ?? baselineDefault,
            choreo?.releaseWind ?? 90,
            heroAllowed ? (choreo?.heroCount ?? heroDefault) : 0,
            choreo?.heroEvery?.first ?? 25,
            choreo?.heroEvery?.last ?? 50
        )
    }

    typealias Aero = (flutterAmp: Float, flutterFreq: Float, tumbleChance: Float,
                      gyroRadius: Float, microTurb: Float, flashOn: Float,
                      flashIntervalMin: Float, flashIntervalMax: Float, attractorWeight: Float)

    /// Resolution chain per field: species override → season override → model default.
    /// Field-by-field, so a species tweaking one knob still inherits the season's others.
    static func resolveAero(model: MotionModel, species sp: AeroOverrides? = nil,
                            season o: AeroOverrides?) -> Aero {
        let defFlutterAmp: Float = model == .petal ? 0.4 : 0.55
        let defFlutterFreq: Float = model == .snow ? 0.3 : 0.55
        return (
            sp?.flutterAmp ?? o?.flutterAmp ?? defFlutterAmp,
            sp?.flutterFreq ?? o?.flutterFreq ?? defFlutterFreq,
            sp?.tumbleChance ?? o?.tumbleChance ?? 0.18,
            sp?.gyroRadius ?? o?.gyroRadius ?? 26,
            sp?.microTurb ?? o?.microTurb ?? 28,
            sp?.flashOn ?? o?.flashOn ?? 0.45,
            sp?.flashInterval?.first ?? o?.flashInterval?.first ?? 3.5,
            sp?.flashInterval?.last ?? o?.flashInterval?.last ?? 6.5,
            sp?.attractorWeight ?? o?.attractorWeight ?? 0.6
        )
    }

    /// Aero values resolved against per-model defaults (single-species path).
    var aeroResolved: Aero { Season.resolveAero(model: motionModel, season: aero) }

    /// Resolved wind-field configuration: JSON overrides where present, windMax-derived defaults
    /// otherwise. Tau defaults by glyph type — light things catch the air faster.
    var windConfig: WindModel.Config {
        WindModel.Config(
            base: wind?.base ?? windMax * 0.35,
            turbulence: wind?.turbulence ?? max(windMax * 0.8, swayAmp * 1.2),
            fieldScale: wind?.fieldScale ?? 0.0015,
            evolve: wind?.evolve ?? 0.12,
            gustEveryMin: wind?.gustEvery?.first ?? 25,
            gustEveryMax: wind?.gustEvery?.last ?? 60,
            gustStrength: wind?.gustStrength ?? windMax * 1.6,
            gustWidth: wind?.gustWidth ?? 900)
    }

    var relaxTau: Float {
        if let t = wind?.relaxTau { return t }
        switch glyphType {
        case .glow: return 0.25
        case .streak: return 0.1
        case .image: return tumble ? 0.8 : 0.35   // leaves heavier than petals/snow
        }
    }
}
