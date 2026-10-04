import Foundation
import simd

/// A Metal-independent description of how a rendered frame must be encoded for presentation.
/// Platform code maps these values to MTLPixelFormat and CGColorSpace at the final boundary.
enum PresentationPixelEncoding: Equatable {
    case bgra8UnormSRGB
    case bgra10XRSRGB
    case rgba16Float
}

enum PresentationColorSpace: Equatable {
    case displayP3
    case extendedLinearDisplayP3
}

struct PresentationColorPlan: Equatable {
    let pixelEncoding: PresentationPixelEncoding
    let colorSpace: PresentationColorSpace
    let extendedDynamicRange: Bool
}

enum PresentationColorPolicy {
    /// Ultra-Lite is a deliberately fixed SDR safety envelope. An ambient EDR request must not
    /// leak into an external Ultra-Lite surface.
    static func plan(ultraLite: Bool, edrRequested: Bool) -> PresentationColorPlan {
        if ultraLite {
            return PresentationColorPlan(pixelEncoding: .bgra8UnormSRGB,
                                         colorSpace: .displayP3,
                                         extendedDynamicRange: false)
        }
        if edrRequested {
            return PresentationColorPlan(pixelEncoding: .rgba16Float,
                                         colorSpace: .extendedLinearDisplayP3,
                                         extendedDynamicRange: true)
        }
        return PresentationColorPlan(pixelEncoding: .bgra10XRSRGB,
                                     colorSpace: .displayP3,
                                     extendedDynamicRange: false)
    }
}

enum SDRColorMath {
    /// IEC 61966-2-1 sRGB opto-electronic transfer function. Inputs outside the SDR range are
    /// clamped because this helper describes an SDR presentation boundary, not scene storage.
    static func srgbEncode(_ linear: Float) -> Float {
        let value = finiteUnit(linear)
        if value <= 0.0031308 { return 12.92 * value }
        return 1.055 * pow(value, 1.0 / 2.4) - 0.055
    }

    /// IEC 61966-2-1 sRGB electro-optical transfer function.
    static func srgbDecode(_ encoded: Float) -> Float {
        let value = finiteUnit(encoded)
        if value <= 0.04045 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    /// Converts decoded linear-sRGB sprite samples to the renderer's linear Display-P3 space.
    static func linearSRGBToLinearP3(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let r = color.x, g = color.y, b = color.z
        return SIMD3<Float>(
            0.82246197 * r + 0.17753803 * g,
            0.03319420 * r + 0.96680580 * g,
            0.01708263 * r + 0.07239744 * g + 0.91051993 * b
        )
    }

    private static func finiteUnit(_ value: Float) -> Float {
        guard value.isFinite else { return value.sign == .minus ? 0 : 1 }
        return min(max(value, 0), 1)
    }
}

/// Conservative SDR-only image treatment. Procedural glows and streaks already have authored
/// intensity/opacity behavior and therefore bypass this profile completely.
struct VividSDRProfile {
    let imageOpacity: Float
    let exposure: Float
    let chroma: Float

    static let standard = VividSDRProfile(imageOpacity: 0.92, exposure: 1.08, chroma: 1.18)

    func effectiveOpacity(configured: Float, isImage: Bool) -> Float {
        guard isImage else { return configured }
        return imageOpacity
    }

    func apply(to color: SIMD3<Float>, isImage: Bool) -> SIMD3<Float> {
        guard isImage else { return color }
        let clean = SIMD3<Float>(sanitize(color.x), sanitize(color.y), sanitize(color.z))
        guard clean != .zero else { return .zero }

        // Display-P3 relative luminance. Expanding distance from this neutral axis lifts color
        // without changing hue; the small exposure gain restores midtones lost in SDR grading.
        let luminance = 0.22897456 * clean.x + 0.69173852 * clean.y + 0.07928691 * clean.z
        let neutral = SIMD3<Float>(repeating: luminance)
        let vivid = (neutral + (clean - neutral) * chroma) * exposure
        return SIMD3<Float>(unit(vivid.x), unit(vivid.y), unit(vivid.z))
    }

    private func sanitize(_ value: Float) -> Float {
        guard value.isFinite else { return value.sign == .minus ? 0 : 1 }
        return unit(value)
    }

    private func unit(_ value: Float) -> Float {
        guard value.isFinite else { return value.sign == .minus ? 0 : 1 }
        return min(max(value, 0), 1)
    }
}
