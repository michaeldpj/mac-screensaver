import Metal
import MetalKit

/// A sprite set's GPU textures: photoreal albedo plus surface maps baked from it at load
/// time (RG = normal.xy, B = thinness, A = AO) — see Shaders/Bake.metal.
struct SpriteTextures {
    let albedo: MTLTexture
    let maps: MTLTexture
}

enum SpriteLoader {
    /// Loads sprites/<set>/1..N.png into a mip-mapped texture2d_array. Returns nil for glow seasons.
    static func loadArray(set: String?, count: Int, device: MTLDevice, library: MTLLibrary,
                          bundle: Bundle = Bundle(for: SeasonsView.self)) -> SpriteTextures? {
        guard let set, count > 0 else { return nil }
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 1...count {
            guard let url = bundle.url(forResource: "\(index)", withExtension: "png",
                                       subdirectory: "sprites/\(set)") else { return nil }
            urls.append(url)
        }
        return assemble(urls: urls, device: device, library: library)
    }

    /// Loads <dir>/1..N.png into a mip-mapped texture2d_array (filesystem path, for the headless harness).
    static func loadArray(fromDirectory dir: URL, count: Int, device: MTLDevice,
                          library: MTLLibrary) -> SpriteTextures? {
        guard count > 0 else { return nil }
        let urls = (1...count).map { dir.appendingPathComponent("\($0).png") }
        return assemble(urls: urls, device: device, library: library)
    }

    private static func assemble(urls: [URL], device: MTLDevice, library: MTLLibrary) -> SpriteTextures? {
        guard !urls.isEmpty else { return nil }
        let loader = MTKTextureLoader(device: device)
        var slices: [MTLTexture] = []
        slices.reserveCapacity(urls.count)
        for url in urls {
            // Sprite art is authored gamma-encoded (sRGB). Decode to linear at sample time
            // (.SRGB: true) so it composites correctly in the linear-P3 HDR pipeline — otherwise
            // the values are treated as linear and blow out toward white.
            guard let tex = try? loader.newTexture(URL: url, options: [
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .generateMipmaps: false,
                .SRGB: true]),
                  tex.textureType == .type2D,
                  tex.pixelFormat == .rgba8Unorm_srgb || tex.pixelFormat == .bgra8Unorm_srgb,
                  tex.width == 1024, tex.height == 1024,
                  tex.depth == 1, tex.arrayLength == 1 else { return nil }
            if let first = slices.first,
               tex.width != first.width || tex.height != first.height ||
               tex.pixelFormat != first.pixelFormat {
                return nil
            }
            slices.append(tex)
        }
        guard slices.count == urls.count, let first = slices.first else { return nil }
        let mipLevelCount = Int(floor(log2(Double(max(first.width, first.height))))) + 1

        func makeArray(_ format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2DArray
            desc.pixelFormat = format
            desc.width = first.width
            desc.height = first.height
            desc.mipmapLevelCount = mipLevelCount
            desc.arrayLength = slices.count
            desc.storageMode = .private
            desc.usage = usage
            return device.makeTexture(descriptor: desc)
        }
        let mipPipelineDescriptor = MTLRenderPipelineDescriptor()
        mipPipelineDescriptor.vertexFunction = library.makeFunction(name: "spriteMipVS")
        mipPipelineDescriptor.fragmentFunction = library.makeFunction(name: "spriteMipFS")
        mipPipelineDescriptor.inputPrimitiveTopology = .triangle
        mipPipelineDescriptor.colorAttachments[0].pixelFormat = first.pixelFormat

        guard let albedo = makeArray(first.pixelFormat, usage: [.shaderRead, .renderTarget]) else {
            NSLog("SpriteLoader rejected set: cannot allocate albedo array")
            return nil
        }
        guard let maps = makeArray(.rgba8Unorm, usage: [.shaderRead, .shaderWrite]) else {
            NSLog("SpriteLoader rejected set: cannot allocate surface-map array")
            return nil
        }
        let mipPSO: MTLRenderPipelineState
        do {
            mipPSO = try device.makeRenderPipelineState(descriptor: mipPipelineDescriptor)
        } catch {
            NSLog("SpriteLoader rejected set: cannot create sprite mip pipeline: %@",
                  error.localizedDescription)
            return nil
        }
        guard let bakeFunction = library.makeFunction(name: "bakeSurfaceMaps"),
              let bakePSO = try? device.makeComputePipelineState(function: bakeFunction) else {
            NSLog("SpriteLoader rejected set: cannot create surface-map pipeline")
            return nil
        }
        guard let q = device.makeCommandQueue(), let cb = q.makeCommandBuffer() else {
            NSLog("SpriteLoader rejected set: cannot create upload command buffer")
            return nil
        }

        if let blit = cb.makeBlitCommandEncoder() {
            for (s, tex) in slices.enumerated() {
                blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                          to: albedo, destinationSlice: s, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
        } else {
            return nil
        }

        // Downsample every array slice in one layered render pass per level. Sampling an sRGB
        // source decodes to linear; writing the sRGB render target re-encodes after the
        // alpha-weighted filter in spriteMipFS.
        for mip in 1..<mipLevelCount {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = albedo
            pass.colorAttachments[0].level = mip
            pass.colorAttachments[0].slice = 0
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            pass.renderTargetArrayLength = slices.count
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else {
                NSLog("SpriteLoader rejected set: cannot encode albedo mip %d", mip)
                return nil
            }
            encoder.setRenderPipelineState(mipPSO)
            encoder.setFragmentTexture(albedo, index: 0)
            var sourceLevel = UInt32(mip - 1)
            encoder.setFragmentBytes(&sourceLevel, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3,
                                   instanceCount: slices.count)
            encoder.endEncoding()
        }

        // Derive and normalize surface detail independently from every filtered albedo mip.
        // This avoids blit-averaging encoded normal vectors and keeps their length meaningful.
        struct BakeLevel {
            let source: MTLTexture
            let destination: MTLTexture
            let width: Int
            let height: Int
        }
        var bakeLevels: [BakeLevel] = []
        bakeLevels.reserveCapacity(mipLevelCount * slices.count)
        for mip in 0..<mipLevelCount {
            let width = max(1, albedo.width >> mip)
            let height = max(1, albedo.height >> mip)
            for slice in 0..<slices.count {
                guard let source = albedo.makeTextureView(pixelFormat: first.pixelFormat,
                                                          textureType: .type2D,
                                                          levels: mip..<(mip + 1),
                                                          slices: slice..<(slice + 1)),
                      let destination = maps.makeTextureView(pixelFormat: .rgba8Unorm,
                                                             textureType: .type2D,
                                                             levels: mip..<(mip + 1),
                                                             slices: slice..<(slice + 1)) else {
                    NSLog("SpriteLoader rejected set: cannot create mip views at level %d slice %d",
                          mip, slice)
                    return nil
                }
                bakeLevels.append(BakeLevel(source: source, destination: destination,
                                            width: width, height: height))
            }
        }
        guard let compute = cb.makeComputeCommandEncoder() else {
            NSLog("SpriteLoader rejected set: cannot encode surface-map bake")
            return nil
        }
        compute.setComputePipelineState(bakePSO)
        let threadWidth = bakePSO.threadExecutionWidth
        let threadHeight = max(bakePSO.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        for level in bakeLevels {
            compute.setTexture(level.source, index: 0)
            compute.setTexture(level.destination, index: 1)
            compute.dispatchThreads(MTLSize(width: level.width, height: level.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: threadWidth,
                                                                   height: threadHeight, depth: 1))
        }
        compute.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else {
            if let error = cb.error {
                NSLog("SpriteLoader mip/map bake failed: %@", error.localizedDescription)
            }
            return nil
        }
        return SpriteTextures(albedo: albedo, maps: maps)
    }
}
