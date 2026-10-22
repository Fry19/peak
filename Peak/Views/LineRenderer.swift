import Metal
import PeakCore
import QuartzCore
import UIKit

/// One line segment of the overlay, in points. Matches `LineSegment` in Lines.metal; a
/// segment whose ends are the same point draws a round dot.
struct LineSegment {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    /// Straight (not premultiplied) color; alpha is the line's opacity.
    var color: SIMD4<Float>
    var width: Float
    /// How far the glow spreads around the line, and its opacity at the line.
    var glow: Float
    var glowAlpha: Float
    var pad: Float = 0
}

/// The terrain seen from above (`PanoramaMesh`), drawn under the lines: the camera it's seen
/// through, in the overlay's own terms (`Camera.Projector`, in points), and how it looks.
struct TerrainCamera {
    var right: SIMD3<Float>
    var down: SIMD3<Float>
    var forward: SIMD3<Float>
    /// fx, fy, cx, cy, in points.
    var lens: SIMD4<Float>
    /// How far above the mesh's center the eye is, meters.
    var lift: Float
    var opacity: Float
    /// The night sky high up, and the paler sky along the horizon, which haze takes: level
    /// and below, turning to `sky` by `skyHeight` up (the sine of that elevation).
    var sky: SIMD3<Float>
    var horizon: SIMD3<Float>
    var skyHeight: Float
    /// The ground facing away from and toward the light.
    var dark: SIMD3<Float>
    var light: SIMD3<Float>
    /// Distance at which haze has covered about two thirds of the ground, at the height of
    /// the ground under the eye, and the height over which it thins by e, meters.
    var haze: Float
    var hazeHeight: Float
}

/// Matches `TerrainUniforms` in Terrain.metal.
private struct TerrainUniforms {
    var right: SIMD4<Float>
    var down: SIMD4<Float>
    var forward: SIMD4<Float>
    var eye: SIMD4<Float>
    var lens: SIMD4<Float>
    var view: SIMD4<Float>
    var haze: SIMD4<Float>
    var sky: SIMD4<Float>
    var horizon: SIMD4<Float>
    var dark: SIMD4<Float>
    var light: SIMD4<Float>
}

/// Draws the overlay's lines on the GPU: every segment is an instanced quad, shaded with its
/// line and glow. Three passes: a faint dark halo under everything, so pale lines still read
/// on snow or a white sky; the ridgelines, blended by taking the brighter, so joins don't
/// double up; then the trail and dots laid over them with ordinary alpha blending, so the
/// trail stays orange where it crosses a white ridge. Thousands of segments cost the CPU
/// only the copying.
final class LineRenderer {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Takes the brighter of overlapping quads (halo and ridgelines).
    private let brightest: MTLRenderPipelineState
    /// Lays one over the other, premultiplied (trail and dots).
    private let over: MTLRenderPipelineState
    /// Three buffers in turn, so the CPU never writes one the GPU is still reading.
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var next = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var all: [LineSegment] = []
    /// The terrain seen from above: drawn on its own with depth, then laid under the lines.
    private let terrainPipeline: MTLRenderPipelineState?
    private let compositePipeline: MTLRenderPipelineState?
    private let terrainDepthState: MTLDepthStencilState?
    private var terrainVertices: MTLBuffer?
    private var terrainIndices: MTLBuffer?
    private var terrainIndexCount = 0
    private var terrainID: Int?
    /// Where the mesh ends, meters.
    private var terrainReach: Float = 0
    private var terrainColor: MTLTexture?
    private var terrainDepth: MTLTexture?
    /// The terrain can be drawn (its shaders are there).
    var drawsTerrain: Bool { terrainPipeline != nil && compositePipeline != nil && terrainDepthState != nil }

    /// Nil where Metal or the shaders aren't available; the overlay then draws with shape layers.
    init?() {
        guard MemoryLayout<LineSegment>.stride == 48,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "lineVertex"),
              let fragment = library.makeFunction(name: "lineFragment") else { return nil }
        func pipeline(_ operation: MTLBlendOperation, destination: MTLBlendFactor) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            guard let attachment = descriptor.colorAttachments[0] else { return nil }
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = operation
            attachment.alphaBlendOperation = operation
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = destination
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = destination
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let brightest = pipeline(.max, destination: .one),
              let over = pipeline(.add, destination: .oneMinusSourceAlpha) else { return nil }
        self.device = device
        self.queue = queue
        self.brightest = brightest
        self.over = over
        // The terrain: opaque on its own target, depth reversed (nearer is greater).
        let terrain = MTLRenderPipelineDescriptor()
        terrain.vertexFunction = library.makeFunction(name: "terrainVertex")
        terrain.fragmentFunction = library.makeFunction(name: "terrainFragment")
        terrain.colorAttachments[0].pixelFormat = .bgra8Unorm
        terrain.depthAttachmentPixelFormat = .depth32Float
        terrainPipeline = terrain.vertexFunction != nil && terrain.fragmentFunction != nil
            ? try? device.makeRenderPipelineState(descriptor: terrain) : nil
        // Laid in behind what's drawn: what's there keeps its share, the terrain fills the rest.
        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = library.makeFunction(name: "compositeVertex")
        composite.fragmentFunction = library.makeFunction(name: "compositeFragment")
        if let attachment = composite.colorAttachments[0] {
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
            attachment.destinationAlphaBlendFactor = .one
        }
        compositePipeline = composite.vertexFunction != nil && composite.fragmentFunction != nil
            ? try? device.makeRenderPipelineState(descriptor: composite) : nil
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        terrainDepthState = device.makeDepthStencilState(descriptor: depth)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.clear.cgColor
    }

    /// Sizes the drawing surface to the view.
    func resize(to size: CGSize, scale: CGFloat) {
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }

    /// The mesh to draw `terrain` cameras with, uploaded once per `id`; nil lets it go.
    func setTerrain(_ mesh: PanoramaMesh?, id: Int) {
        guard let mesh else {
            terrainVertices = nil
            terrainIndices = nil
            terrainIndexCount = 0
            terrainID = nil
            terrainColor = nil
            terrainDepth = nil
            return
        }
        guard id != terrainID, drawsTerrain, !mesh.indices.isEmpty else { return }
        terrainVertices = mesh.vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        terrainIndices = mesh.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        terrainIndexCount = terrainIndices == nil ? 0 : mesh.indices.count
        terrainReach = Float(mesh.rings.last ?? 0)
        terrainID = id
    }

    /// The terrain's own color target and depth, at the drawable's size.
    private func terrainTargets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let color = terrainColor, let depth = terrainDepth, color.width == width, color.height == height {
            return (color, depth)
        }
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depth.usage = .renderTarget
        // Kept on the GPU's tiles where it can be: it's never read back.
        depth.storageMode = device.supportsFamily(.apple2) ? .memoryless : .private
        guard let c = device.makeTexture(descriptor: color), let d = device.makeTexture(descriptor: depth) else { return nil }
        terrainColor = c
        terrainDepth = d
        return (c, d)
    }

    /// Draws the terrain alone into its target, returning what it was drawn with, for laying
    /// it under the lines; nil when there's nothing to draw.
    private func encodeTerrain(_ camera: TerrainCamera, into commands: MTLCommandBuffer, size: CGSize, width: Int,
                               height: Int) -> TerrainUniforms? {
        guard camera.opacity > 0, terrainIndexCount > 0, let vertices = terrainVertices, let indices = terrainIndices,
              let pipeline = terrainPipeline, let depthState = terrainDepthState,
              let (color, depth) = terrainTargets(width: width, height: height) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = TerrainUniforms(
            right: SIMD4(camera.right, 0), down: SIMD4(camera.down, 0), forward: SIMD4(camera.forward, 0),
            eye: SIMD4(0, 0, camera.lift, terrainReach), lens: camera.lens,
            view: SIMD4(Float(size.width), Float(size.height), 1, 0), haze: SIMD4(camera.haze, camera.hazeHeight, 0, 0),
            sky: SIMD4(camera.sky, camera.opacity), horizon: SIMD4(camera.horizon, camera.skyHeight),
            dark: SIMD4(camera.dark, 1), light: SIMD4(camera.light, 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TerrainUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerrainUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: terrainIndexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding()
        return uniforms
    }

    /// Draws `lines` (ridgelines, blended brightest) and `overlay` (trail and dots, laid
    /// over them), in points over a view of `size`, in place of the last ones, each with a
    /// dark halo of `halo` opacity under it; with `terrain`, over the terrain seen from above.
    func draw(lines: [LineSegment], overlay: [LineSegment] = [], halo: Float = 0.3, terrain: TerrainCamera? = nil,
              size: CGSize, scale: CGFloat) {
        let pixels = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if layer.drawableSize != pixels { resize(to: size, scale: scale) }
        // Never hold up the screen waiting for the GPU: skip this frame if it's behind.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let underlay = terrain.flatMap {
            encodeTerrain($0, into: commands, size: size, width: drawable.texture.width, height: drawable.texture.height)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        // The halo: each segment again, dark, a little wider and softer. Drawn brightest-of
        // like the lines, so it doesn't darken where pieces overlap.
        all.removeAll(keepingCapacity: true)
        if halo > 0 {
            for s in lines where s.color.w > 0 {
                all.append(Self.halo(of: s, alpha: halo * min(1, s.color.w + 0.2)))
            }
            for s in overlay where s.color.w > 0 { all.append(Self.halo(of: s, alpha: halo)) }
        }
        all.append(contentsOf: lines)
        let brightCount = all.count
        all.append(contentsOf: overlay)
        if !all.isEmpty {
            let stride = MemoryLayout<LineSegment>.stride
            let length = all.count * stride
            if (buffers[next]?.length ?? 0) < length {
                buffers[next] = device.makeBuffer(length: max(length, 64 * 1024), options: .storageModeShared)
            }
            if let buffer = buffers[next] {
                all.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
                var uniforms = SIMD4<Float>(Float(size.width), Float(size.height), Float(scale), 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                if brightCount > 0 {
                    encoder.setRenderPipelineState(brightest)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: brightCount)
                }
                if all.count > brightCount {
                    encoder.setRenderPipelineState(over)
                    encoder.setVertexBufferOffset(brightCount * stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                           instanceCount: all.count - brightCount)
                }
            }
            next = (next + 1) % buffers.count
        }
        if var uniforms = underlay, let composite = compositePipeline, let color = terrainColor {
            encoder.setRenderPipelineState(composite)
            encoder.setFragmentTexture(color, index: 0)
            // In place of the lines' own uniforms, for the sky where there's no terrain.
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerrainUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
    }

    /// A dark, soft stroke under a segment.
    private static func halo(of s: LineSegment, alpha: Float) -> LineSegment {
        LineSegment(a: s.a, b: s.b, color: SIMD4(0, 0, 0, alpha), width: s.width + 2.5, glow: 2.5, glowAlpha: alpha * 0.5)
    }
}
