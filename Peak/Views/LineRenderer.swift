import Metal
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

/// Draws the overlay's lines on the GPU: every segment is an instanced quad, shaded with its
/// line and glow in one pass. Thousands of segments cost the CPU only the copying.
final class LineRenderer {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Three buffers in turn, so the CPU never writes one the GPU is still reading.
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var next = 0
    private let inFlight = DispatchSemaphore(value: 3)

    /// Nil where Metal or the shaders aren't available; the overlay then draws with shape layers.
    init?() {
        guard MemoryLayout<LineSegment>.stride == 48,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "lineVertex"),
              let fragment = library.makeFunction(name: "lineFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .max
        attachment.alphaBlendOperation = .max
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
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

    /// Draws the segments (in points, over a view of `size`) in place of the last ones.
    func draw(_ segments: [LineSegment], size: CGSize, scale: CGFloat) {
        let pixels = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if layer.drawableSize != pixels { resize(to: size, scale: scale) }
        // Never hold up the screen waiting for the GPU: skip this frame if it's behind.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
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
        if !segments.isEmpty {
            let length = segments.count * MemoryLayout<LineSegment>.stride
            if (buffers[next]?.length ?? 0) < length {
                buffers[next] = device.makeBuffer(length: max(length, 64 * 1024), options: .storageModeShared)
            }
            if let buffer = buffers[next] {
                segments.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
                var uniforms = SIMD4<Float>(Float(size.width), Float(size.height), Float(scale), 0)
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segments.count)
            }
            next = (next + 1) % buffers.count
        }
        encoder.endEncoding()
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
    }
}
