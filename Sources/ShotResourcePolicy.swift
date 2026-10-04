import Foundation

/// Parsed command line for the headless renderer. `deprecatedSpriteCount` remains accepted only
/// so existing scripts fail predictably instead of shifting every following positional argument.
struct ShotArguments {
    static let usage = "usage: seasons-shot <seasonJSON> <spriteBaseDir|-> <deprecatedCount> <out.png> <w> <h> <frames> [seqEvery]"
    static let maximumDimension = 8_192
    // The harness holds the GPU target plus half-float and byte readback buffers concurrently.
    // Keep that diagnostic path comfortably below a multi-gigabyte allocation while allowing 5K.
    static let maximumPixels = 16_777_216

    let seasonURL: URL
    let spriteBaseDirectory: String
    let deprecatedSpriteCount: Int
    let outputURL: URL
    let width: Int
    let height: Int
    let frames: Int
    let sequenceEvery: Int

    static func parse(_ arguments: [String]) throws -> ShotArguments {
        guard arguments.count == 8 || arguments.count == 9 else {
            throw ShotPolicyError.invalidArguments(usage)
        }
        guard let legacyCount = Int(arguments[3]), legacyCount >= 0 else {
            throw ShotPolicyError.invalidArguments("deprecatedCount must be a non-negative integer")
        }
        guard let width = Int(arguments[5]), width > 0,
              let height = Int(arguments[6]), height > 0,
              let frames = Int(arguments[7]), frames > 0 else {
            throw ShotPolicyError.invalidArguments("w, h, and frames must be positive integers")
        }
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else {
            throw ShotPolicyError.invalidArguments(
                "output exceeds headless pixel budget (max \(maximumDimension) per edge and "
                + "\(maximumPixels) total pixels)"
            )
        }
        let sequenceEvery: Int
        if arguments.count == 9 {
            guard let parsed = Int(arguments[8]), parsed >= 0 else {
                throw ShotPolicyError.invalidArguments("seqEvery must be a non-negative integer")
            }
            sequenceEvery = parsed
        } else {
            sequenceEvery = 0
        }
        return ShotArguments(
            seasonURL: URL(fileURLWithPath: arguments[1]),
            spriteBaseDirectory: arguments[2],
            deprecatedSpriteCount: legacyCount,
            outputURL: URL(fileURLWithPath: arguments[4]),
            width: width,
            height: height,
            frames: frames,
            sequenceEvery: sequenceEvery
        )
    }
}

struct ShotPanoramaConfiguration: Equatable {
    let worldSize: SIMD2<Float>
    let cameraOrigin: SIMD2<Float>
    let cameraSize: SIMD2<Float>
    let windOrigin: SIMD2<Float>
    let worldSeed: UInt32

    static func parse(environment: [String: String]) throws -> ShotPanoramaConfiguration? {
        let worldRaw = environment["SEASONS_PANORAMA_WORLD"]
        let cameraRaw = environment["SEASONS_PANORAMA_CAMERA"]
        guard worldRaw != nil || cameraRaw != nil else { return nil }
        guard let worldRaw, let cameraRaw else {
            throw ShotPolicyError.invalidPanorama(
                "SEASONS_PANORAMA_WORLD and SEASONS_PANORAMA_CAMERA must be supplied together"
            )
        }

        let world = try parseFloats(worldRaw, count: 2, name: "SEASONS_PANORAMA_WORLD")
        let camera = try parseFloats(cameraRaw, count: 4, name: "SEASONS_PANORAMA_CAMERA")
        guard world[0] > 0, world[1] > 0, camera[2] > 0, camera[3] > 0 else {
            throw ShotPolicyError.invalidPanorama("panorama world and camera sizes must be positive")
        }
        let wind: [Float]
        if let raw = environment["SEASONS_PANORAMA_WIND"] {
            wind = try parseFloats(raw, count: 2, name: "SEASONS_PANORAMA_WIND")
        } else {
            wind = [0, 0]
        }
        let seed: UInt32
        if let raw = environment["SEASONS_PANORAMA_SEED"] {
            guard let parsed = UInt32(raw) else {
                throw ShotPolicyError.invalidPanorama(
                    "SEASONS_PANORAMA_SEED must be an unsigned 32-bit integer"
                )
            }
            seed = parsed
        } else {
            seed = 1
        }
        return ShotPanoramaConfiguration(
            worldSize: SIMD2(world[0], world[1]),
            cameraOrigin: SIMD2(camera[0], camera[1]),
            cameraSize: SIMD2(camera[2], camera[3]),
            windOrigin: SIMD2(wind[0], wind[1]),
            worldSeed: seed
        )
    }

    private static func parseFloats(_ raw: String, count: Int, name: String) throws -> [Float] {
        let components = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == count else {
            throw ShotPolicyError.invalidPanorama("\(name) must contain exactly \(count) comma-separated numbers")
        }
        let values = components.compactMap { Float($0) }
        guard values.count == count, values.allSatisfy(\.isFinite) else {
            throw ShotPolicyError.invalidPanorama("\(name) must contain only finite numbers")
        }
        return values
    }
}

enum ShotWorldOriginPolicy {
    static func parse(environment: [String: String]) throws -> SIMD2<Float> {
        guard let raw = environment["SEASONS_WORLD_ORIGIN"] else { return .zero }
        let components = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2,
              let x = Float(components[0]), x.isFinite,
              let y = Float(components[1]), y.isFinite else {
            throw ShotPolicyError.invalidArguments(
                "SEASONS_WORLD_ORIGIN must contain exactly two finite comma-separated numbers"
            )
        }
        return SIMD2(x, y)
    }
}

struct ShotSpriteRequirement {
    let set: String?
    let count: Int
    let imageBacked: Bool
}

struct ShotSpritePlan {
    let directory: URL
    let imageURLs: [URL]
}

enum ShotPolicyError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case spritesDisabledForImageSpecies
    case invalidImageSpecies(set: String?, count: Int)
    case unloadableImage(URL)
    case invalidPanorama(String)

    var description: String {
        switch self {
        case .invalidArguments(let detail):
            return detail
        case .spritesDisabledForImageSpecies:
            return "spriteBaseDir '-' is valid only when every species is procedural"
        case .invalidImageSpecies(let set, let count):
            return "image species has invalid spriteSet/count; spriteSet must be a simple name: "
                + "set=\(set ?? "nil") count=\(count)"
        case .unloadableImage(let url):
            return "missing or unloadable sprite image: \(url.path)"
        case .invalidPanorama(let detail):
            return detail
        }
    }
}

enum ShotResourcePolicy {
    /// Resolve each species relative to the common `Resources/sprites` directory and require every
    /// declared image to be decodable. This prevents partially populated texture arrays from making
    /// an apparently successful screenshot that does not represent the configured season.
    static func resolve(baseDirectoryArgument: String,
                        requirements: [ShotSpriteRequirement],
                        canLoad: (URL) -> Bool) throws -> [ShotSpritePlan?] {
        let hasImages = requirements.contains(where: \.imageBacked)
        if baseDirectoryArgument == "-" && hasImages {
            throw ShotPolicyError.spritesDisabledForImageSpecies
        }

        let base = URL(fileURLWithPath: baseDirectoryArgument, isDirectory: true).standardizedFileURL
        return try requirements.map { requirement in
            guard requirement.imageBacked else { return nil }
            guard let set = requirement.set,
                  set.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$",
                            options: .regularExpression) != nil,
                  requirement.count > 0 else {
                throw ShotPolicyError.invalidImageSpecies(set: requirement.set, count: requirement.count)
            }
            let directory = base.appendingPathComponent(set, isDirectory: true)
            let urls = (1...requirement.count).map {
                directory.appendingPathComponent("\($0).png", isDirectory: false)
            }
            if let bad = urls.first(where: { !canLoad($0) }) {
                throw ShotPolicyError.unloadableImage(bad)
            }
            return ShotSpritePlan(directory: directory, imageURLs: urls)
        }
    }
}
