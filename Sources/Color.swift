import simd

/// OKLCH (L in 0...1, C chroma, H degrees) → linear Display P3 (unclamped; values may exceed 1 for EDR).
func oklchToLinearP3(L: Float, C: Float, H: Float) -> SIMD3<Float> {
    let h = H * Float.pi / 180
    let a = C * cos(h)
    let b = C * sin(h)
    // OKLab → LMS'
    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b
    let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
    // LMS → linear sRGB (Björn Ottosson matrix)
    let rLin =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let gLin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bLin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    // linear sRGB → linear Display P3 (D65, Bradford-adapted)
    let srgb = SIMD3<Float>(rLin, gLin, bLin)
    let m1 = SIMD3<Float>(0.82246197, 0.17753803, 0.0)
    let m2 = SIMD3<Float>(0.03319420, 0.96680580, 0.0)
    let m3 = SIMD3<Float>(0.01708263, 0.07239744, 0.91051993)
    return SIMD3<Float>(dot(m1, srgb), dot(m2, srgb), dot(m3, srgb))
}
