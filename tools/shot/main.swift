// Headless render harness: renders N frames of a season into an offscreen texture and
// writes a PNG, so the engine can be visually verified without the screensaver host or a GUI.
//
// usage: seasons-shot <seasonJSON> <spriteBaseDir|-> <deprecatedCount> <out.png> <w> <h> <frames> [seqEvery]
//   [seqEvery]              also write out_NNN.png every `seqEvery` frames (motion strips)
//   SEASONS_WORLD_ORIGIN    "x,y" display origin in desktop points (cross-display seam QA)
//   SEASONS_PANORAMA_WORLD  "w,h" deterministic global particle-world extent
//   SEASONS_PANORAMA_CAMERA "x,y,w,h" camera crop within that world
//   SEASONS_PANORAMA_SEED   shared UInt32 seed (default 1)
//   SEASONS_TIME_OFFSET     seconds added to the clock (land on a deterministic gust)
//   SEASONS_STATIC          render the backdrop only
//   SEASONS_PERF_WARMUP     completed frames to discard before GPU timing (default 10, retaining one sample)
//   SEASONS_PERF_ENFORCE    "1" makes the conservative >=25ms/zero-sample timing gate exit nonzero
import Metal
import MetalKit
import Foundation
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

/// IEEE 754 half-precision (UInt16 bits) → Float, without depending on Float16 inits.
func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exp = UInt32(h & 0x7C00) >> 10
    let mant = UInt32(h & 0x03FF)
    var bits: UInt32
    if exp == 0 {
        if mant == 0 { bits = sign }                       // ±0
        else {                                             // subnormal
            var e: UInt32 = 127 - 15 + 1
            var m = mant
            while (m & 0x400) == 0 { m <<= 1; e -= 1 }
            m &= 0x3FF
            bits = sign | (e << 23) | (m << 13)
        }
    } else if exp == 0x1F {
        bits = sign | 0x7F800000 | (mant << 13)            // Inf/NaN
    } else {
        bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13)
    }
    return Float(bitPattern: bits)
}

let arguments: ShotArguments
do {
    arguments = try ShotArguments.parse(CommandLine.arguments)
} catch {
    die("\(error)\n\(ShotArguments.usage)")
}
let seasonURL = arguments.seasonURL
let spriteDirArg = arguments.spriteBaseDirectory
let outURL = arguments.outputURL
let W = arguments.width
let H = arguments.height
let frames = arguments.frames
let seqEvery = arguments.sequenceEvery
FileHandle.standardError.write(Data(
    "note: deprecatedCount=\(arguments.deprecatedSpriteCount) is accepted for compatibility but ignored; each species' spriteCount in season JSON is authoritative\n".utf8
))

guard let device = MTLCreateSystemDefaultDevice() else { die("no Metal device") }
guard let library = device.makeDefaultLibrary() else { die("no default.metallib next to executable") }
let season: Season
do {
    season = try JSONDecoder().decode(Season.self, from: Data(contentsOf: seasonURL))
} catch {
    die("cannot decode season json: \(error)")
}
// spriteBaseDir is the common sprites directory (e.g. Resources/sprites); each species' set
// name is joined onto it. Validate the complete declared set before allocating render resources.
let resolvedSpecies = season.speciesResolved
let spritePlans: [ShotSpritePlan?]
do {
    spritePlans = try ShotResourcePolicy.resolve(
        baseDirectoryArgument: spriteDirArg,
        requirements: resolvedSpecies.map {
            ShotSpriteRequirement(set: $0.spriteSet, count: $0.spriteCount,
                                  imageBacked: season.glyphType == .image)
        },
        canLoad: {
            guard let source = CGImageSourceCreateWithURL($0 as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        }
    )
} catch {
    die("sprite validation failed: \(error)")
}
let sprites: [SpriteTextures?] = zip(resolvedSpecies, spritePlans).map { species, plan in
    guard let plan else { return nil }
    guard let loaded = SpriteLoader.loadArray(fromDirectory: plan.directory,
                                               count: species.spriteCount,
                                               device: device, library: library) else {
        die("sprite texture upload failed for: \(plan.directory.path)")
    }
    return loaded
}
let allImageSpeciesLoaded = season.glyphType != .image
    || (sprites.count == resolvedSpecies.count && sprites.allSatisfy { $0 != nil })

let pointSize = SIMD2<Float>(Float(W), Float(H))
let panoramaProjection: PanoramaProjection?
do {
    if let panorama = try ShotPanoramaConfiguration.parse(
        environment: ProcessInfo.processInfo.environment
    ) {
        panoramaProjection = PanoramaProjection(
            displayID: 1,
            worldSize: panorama.worldSize,
            cameraOrigin: panorama.cameraOrigin,
            cameraSize: panorama.cameraSize,
            windOrigin: panorama.windOrigin,
            worldSeed: panorama.worldSeed
        )
    } else {
        panoramaProjection = nil
    }
} catch {
    die("invalid panorama environment: \(error)")
}
// SEASONS_LITE=1 exercises the legacy secondary tier; SEASONS_ULTRA_LITE=1 matches the
// three-external safety envelope (15% particles, no bloom/DoF, native internal scale).
let lite = ProcessInfo.processInfo.environment["SEASONS_LITE"] != nil
let ultraLite = ProcessInfo.processInfo.environment["SEASONS_ULTRA_LITE"] != nil
guard let renderer = Renderer(device: device, library: library, season: season, viewport: pointSize,
                              sprites: sprites,
                              countScale: ultraLite ? 0.15 : (lite ? 0.5 : 1.0),
                              bloom: !ultraLite, dof: !lite && !ultraLite,
                              litePost: lite || ultraLite, forcedScale: lite ? 0.5 : nil,
                              panoramaProjection: panoramaProjection) else {
    die("cannot initialize renderer")
}

let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
td.usage = [.renderTarget, .shaderRead]
td.storageMode = .shared
guard let target = device.makeTexture(descriptor: td) else { die("cannot make target texture") }

let animate = ProcessInfo.processInfo.environment["SEASONS_STATIC"] == nil
let worldOrigin: SIMD2<Float>
do {
    worldOrigin = try ShotWorldOriginPolicy.parse(environment: ProcessInfo.processInfo.environment)
} catch {
    die("invalid headless environment: \(error)")
}
let environment = ProcessInfo.processInfo.environment
if let rawTimeOffset = environment["SEASONS_TIME_OFFSET"],
   !(Double(rawTimeOffset)?.isFinite ?? false) {
    die("SEASONS_TIME_OFFSET must be a finite number")
}
let warmupFrames: Int
if let rawWarmup = environment["SEASONS_PERF_WARMUP"] {
    guard let parsed = Int(rawWarmup), parsed >= 0 else {
        die("SEASONS_PERF_WARMUP must be a non-negative integer")
    }
    warmupFrames = parsed
} else {
    warmupFrames = min(10, max(frames - 1, 0))
}
let enforcePerformance = ["1", "true", "yes"].contains(
    environment["SEASONS_PERF_ENFORCE", default: ""].lowercased()
)
func writePNG(_ url: URL) {
    var half = [UInt16](repeating: 0, count: W * H * 4)
    target.getBytes(&half, bytesPerRow: W * 8, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    // The renderer works in linear Display-P3. Encode the exact IEC sRGB transfer while retaining
    // Display-P3 primaries in the PNG profile, matching an SDR CAMetalLayer presentation.
    var rgba = [UInt8](repeating: 0, count: W * H * 4)
    var blackPixels = 0
    var litPixels = 0
    var clippedChannels = 0
    var lumaSum: Double = 0
    var chromaSum: Double = 0
    for p in 0..<(W * H) {
        var linear = SIMD3<Float>()
        for c in 0..<3 {
            var lin = halfToFloat(half[p * 4 + c])
            if lin < 0 { lin = 0 }
            linear[c] = lin
            if lin >= 0.999 { clippedChannels += 1 }
            let unit = min(lin, 1.0)
            let enc = unit <= 0.0031308
                ? 12.92 * unit
                : 1.055 * powf(unit, 1.0 / 2.4) - 0.055
            rgba[p * 4 + c] = UInt8(enc * 255 + 0.5)
        }
        let peak = max(linear.x, max(linear.y, linear.z))
        if peak <= 1.0 / 65535.0 {
            blackPixels += 1
        } else {
            litPixels += 1
            lumaSum += Double(0.22897456 * linear.x + 0.69173852 * linear.y
                + 0.07928691 * linear.z)
            chromaSum += Double(peak - min(linear.x, min(linear.y, linear.z)))
        }
        rgba[p * 4 + 3] = 255
    }
    guard let cs = CGColorSpace(name: CGColorSpace.displayP3),
          let ctx = CGContext(data: &rgba, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { die("cannot create image context") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { die("cannot write png") }
    let total = max(W * H, 1)
    let lit = max(litPixels, 1)
    print(String(format: "metrics black=%.5f lit=%.5f meanLitLuma=%.5f meanLitChroma=%.5f clippedChannels=%.5f",
                 Double(blackPixels) / Double(total), Double(litPixels) / Double(total),
                 lumaSum / Double(lit), chromaSum / Double(lit),
                 Double(clippedChannels) / Double(total * 3)))
}

var gpuSamples: [Float] = []
gpuSamples.reserveCapacity(max(frames - warmupFrames, 0))
var renderFailures = 0
for f in 0..<max(frames, 1) {
    let panoramaFrame = panoramaProjection.map {
        PanoramaRenderFrame(projection: $0, targetTick: f, startTime: 0)
    }
    let rendered = renderer.renderFrame(into: target, pointSize: pointSize, animate: animate,
                                        worldOrigin: worldOrigin, panoramaFrame: panoramaFrame)
    if !rendered { renderFailures += 1 }
    if let gpuTime = renderer.consumeHealthGPUTime(), f >= warmupFrames {
        gpuSamples.append(gpuTime)
    }
    if rendered, seqEvery > 0, f % seqEvery == 0 {
        let base = outURL.deletingPathExtension()
        writePNG(base.appendingPathExtension("f\(String(format: "%04d", f)).png"))
    }
}
if renderFailures > 0 {
    die("headless render failed for \(renderFailures) of \(frames) frame(s)")
}
let performance = ShotPerformancePolicy.analyze(gpuSeconds: gpuSamples,
                                                renderFailures: 0)
func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "n/a"
}
writePNG(outURL)
print("performance samples=\(performance.sampleCount) warmup=\(warmupFrames) failures=\(performance.renderFailures) p50GPUms=\(milliseconds(performance.p50Milliseconds)) p95GPUms=\(milliseconds(performance.p95Milliseconds)) maxGPUms=\(milliseconds(performance.maxMilliseconds)) verdict=\(performance.verdict.rawValue) preferredP95ms<\(Int(ShotPerformancePolicy.preferredP95Milliseconds)) hardStopP95ms>=\(Int(ShotPerformancePolicy.hardStopP95Milliseconds)) enforced=\(enforcePerformance)")
print("wrote \(outURL.path) output=\(W)x\(H) frames=\(frames) allImageSpeciesLoaded=\(allImageSpeciesLoaded) origin=\(worldOrigin) panorama=\(panoramaProjection != nil)")
if enforcePerformance && performance.shouldHardFail {
    die("performance hard stop: verdict=\(performance.verdict.rawValue) failures=\(performance.renderFailures) p95GPUms=\(milliseconds(performance.p95Milliseconds))")
}
