import Metal
import simd

/// A curved, tessellated patch mesh used as the 3D body of a particle. The sprite texture
/// (with alpha) cuts the silhouette; the curvature + computed normals give real 3D form and
/// light response as the particle tumbles.
struct Mesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    /// Curvature recipe per particle body.
    struct Curl {
        var cup: Float      // concave bowl (petals)
        var fold: Float     // midrib V-fold across width (leaves)
        var curl: Float     // lengthwise curl
        var grid: Int
    }

    static func curl(for model: MotionModel, overrides: CurlOverrides? = nil) -> Curl {
        var c: Curl
        switch model {
        case .petal:  c = Curl(cup: 0.45, fold: 0.0, curl: 0.22, grid: 24)
        case .leaf:   c = Curl(cup: 0.10, fold: 0.34, curl: 0.40, grid: 24)
        case .snow:   c = Curl(cup: 0.06, fold: 0.0, curl: 0.0, grid: 16)
        case .samara: c = Curl(cup: 0.02, fold: 0.16, curl: 0.06, grid: 16)  // near-flat blade
        default:      c = Curl(cup: 0.20, fold: 0.0, curl: 0.15, grid: 16)
        }
        if let o = overrides {
            if let v = o.cup { c.cup = v }
            if let v = o.fold { c.fold = v }
            if let v = o.curl { c.curl = v }
            if let v = o.grid { c.grid = v }
        }
        return c
    }

    private static func height(_ u: Float, _ v: Float, _ c: Curl) -> Float {
        let uu = (2 * u) * (2 * u), vv = (2 * v) * (2 * v)
        return -c.cup * (uu + vv) * 0.25 + c.fold * abs(u) + c.curl * vv * 0.25
    }

    static func make(device: MTLDevice, curl c: Curl) -> Mesh? {
        let n = c.grid
        let side = n + 1
        let h: (Float, Float) -> Float = { height($0, $1, c) }
        let eps: Float = 0.5 / Float(n)

        var verts: [MeshVertex] = []
        verts.reserveCapacity(side * side)
        for j in 0...n {
            for i in 0...n {
                let u = Float(i) / Float(n) - 0.5
                let v = Float(j) / Float(n) - 0.5
                let p = SIMD3<Float>(u, v, h(u, v))
                // normal from finite differences of the height field
                let du = SIMD3<Float>(2 * eps, 0, h(u + eps, v) - h(u - eps, v))
                let dv = SIMD3<Float>(0, 2 * eps, h(u, v + eps) - h(u, v - eps))
                let nrm = normalize(cross(du, dv))
                let uv = SIMD2<Float>(Float(i) / Float(n), 1.0 - Float(j) / Float(n))
                verts.append(MeshVertex(pos: p, normal: nrm, uv: uv))
            }
        }

        var idx: [UInt16] = []
        idx.reserveCapacity(n * n * 6)
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt16(j * side + i)
                let b = UInt16(j * side + i + 1)
                let cc = UInt16((j + 1) * side + i)
                let d = UInt16((j + 1) * side + i + 1)
                idx.append(contentsOf: [a, b, cc, b, d, cc])
            }
        }

        guard let vb = device.makeBuffer(bytes: verts,
                                         length: MemoryLayout<MeshVertex>.stride * verts.count),
              let ib = device.makeBuffer(bytes: idx,
                                         length: MemoryLayout<UInt16>.stride * idx.count) else {
            return nil
        }
        return Mesh(vertexBuffer: vb, indexBuffer: ib, indexCount: idx.count)
    }
}
