import Foundation
import Metal
import QuartzCore
import simd

/// Draws the folded desktop panel into a CAMetalLayer.
///
/// Three passes per frame: blur the captured desktop horizontally into a
/// half-resolution texture, blur that vertically, then draw the subdivided panel
/// mesh sampling both the sharp and blurred versions. Half resolution for the
/// blur is free quality — the result is only ever seen through a mix that is
/// itself blurry, so the lost detail is invisible.
final class FoldRenderer {

    /// Panel subdivision. The bend is smooth as long as the grid is fine enough
    /// that no single quad spans a visible slice of the curve; 48 is comfortably
    /// past that on a Retina display and still trivial for the GPU.
    private static let gridResolution = 48

    private struct FoldUniforms {
        var fold: Float = 0
        var perspective: Float = 0
        var darkening: Float = 0
        var shadowStrength: Float = 0
        var sheen: Float = 0
        var curvature: Float = 0
        var blurMix: Float = 0
        var aspect: Float = 1
    }

    private struct BlurUniforms {
        var texelStep: SIMD2<Float> = .zero
        var radius: Float = 0
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blurPipeline: MTLRenderPipelineState
    private let foldPipeline: MTLRenderPipelineState
    private let gridBuffer: MTLBuffer
    private let gridVertexCount: Int

    private var blurA: MTLTexture?
    private var blurB: MTLTexture?
    private var blurSize: CGSize = .zero

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        commandQueue = queue

        let library = try device.makeLibrary(source: Shaders.source, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                // Premultiplied alpha: the shader already multiplies colour by alpha.
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].sourceRGBBlendFactor = .one
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        blurPipeline = try pipeline("fullscreenVertex", "blurFragment", blending: false)
        foldPipeline = try pipeline("foldVertex", "foldFragment", blending: true)

        let grid = Self.makeGrid(resolution: Self.gridResolution)
        gridVertexCount = grid.count
        guard let buffer = device.makeBuffer(
            bytes: grid, length: MemoryLayout<SIMD2<Float>>.stride * grid.count, options: .storageModeShared
        ) else { throw RendererError.noBuffer }
        gridBuffer = buffer
    }

    /// Builds a triangle list covering [-1, 1] in both axes.
    private static func makeGrid(resolution n: Int) -> [SIMD2<Float>] {
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(n * n * 6)
        let step = 2.0 / Float(n)
        for row in 0..<n {
            for column in 0..<n {
                let x0 = -1 + Float(column) * step
                let x1 = x0 + step
                let y0 = -1 + Float(row) * step
                let y1 = y0 + step
                vertices.append(SIMD2(x0, y0))
                vertices.append(SIMD2(x1, y0))
                vertices.append(SIMD2(x0, y1))
                vertices.append(SIMD2(x1, y0))
                vertices.append(SIMD2(x1, y1))
                vertices.append(SIMD2(x0, y1))
            }
        }
        return vertices
    }

    private func ensureBlurTextures(for size: CGSize) {
        let half = CGSize(width: max(size.width / 2, 1), height: max(size.height / 2, 1))
        guard half != blurSize || blurA == nil else { return }
        blurSize = half

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(half.width), height: Int(half.height), mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        blurA = device.makeTexture(descriptor: desc)
        blurB = device.makeTexture(descriptor: desc)
    }

    /// Renders one frame into a drawable and presents it.
    func render(source: MTLTexture, fold: Double, style: FoldStyle, drawable: CAMetalDrawable) {
        encode(source: source, fold: fold, style: style, target: drawable.texture) { buffer in
            buffer.present(drawable)
        }
    }

    /// Renders one frame into an arbitrary texture.
    ///
    /// Split out from the drawable path so the pipeline can be driven offscreen
    /// with no window, no display and no screen-recording permission — which is
    /// the only way to check the fold maths without a human watching a screen.
    func render(source: MTLTexture, fold: Double, style: FoldStyle,
                into target: MTLTexture, waitForCompletion: Bool = false) {
        encode(source: source, fold: fold, style: style, target: target) { buffer in
            if waitForCompletion {
                buffer.commit()
                buffer.waitUntilCompleted()
            }
        }
    }

    /// - Parameters:
    ///   - source: the captured desktop.
    ///   - fold: fold progress, 0...1.
    ///   - style: look parameters, already scaled by the user's multipliers.
    ///   - target: where the folded panel is drawn.
    ///   - finish: runs after encoding, before the shared commit.
    private func encode(source: MTLTexture, fold: Double, style: FoldStyle,
                        target: MTLTexture, finish: (MTLCommandBuffer) -> Void) {
        let size = CGSize(width: target.width, height: target.height)
        ensureBlurTextures(for: size)
        guard let blurA, let blurB,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let foldAmount = Float(min(max(fold, 0), 1))
        // Blur radius ramps with the square of the fold so the image stays crisp
        // through the early travel and softens fast at the end.
        let radius = Float(style.blurRadius) * foldAmount * foldAmount

        // Pass 1 and 2: separable blur into blurB.
        blurPass(commandBuffer: commandBuffer, from: source, to: blurA,
                 step: SIMD2(1.0 / Float(blurA.width), 0), radius: radius)
        blurPass(commandBuffer: commandBuffer, from: blurA, to: blurB,
                 step: SIMD2(0, 1.0 / Float(blurB.height)), radius: radius)

        // Pass 3: the fold itself.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        // Clear to opaque black: the overlay hides the real desktop, so whatever
        // the folded panel does not cover must read as empty space, not as a
        // window onto the desktop underneath.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = FoldUniforms(
            fold: foldAmount,
            perspective: Float(style.perspective),
            darkening: Float(style.darkening),
            shadowStrength: Float(style.shadowStrength),
            sheen: Float(style.sheen),
            curvature: Float(style.curvature),
            blurMix: min(foldAmount * 1.4, 1.0),
            aspect: Float(size.width / max(size.height, 1))
        )
        encoder.setRenderPipelineState(foldPipeline)
        encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(blurB, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridVertexCount)
        encoder.endEncoding()

        finish(commandBuffer)
        // A drawable path presents inside `finish` and still needs committing;
        // the offscreen path commits there itself so it can wait. Committing an
        // already-committed buffer is a no-op guarded by its status.
        if commandBuffer.status == .notEnqueued {
            commandBuffer.commit()
        }
    }

    private func blurPass(commandBuffer: MTLCommandBuffer, from source: MTLTexture,
                          to destination: MTLTexture, step: SIMD2<Float>, radius: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = BlurUniforms(texelStep: step, radius: max(radius, 0.001))
        encoder.setRenderPipelineState(blurPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    enum RendererError: LocalizedError {
        case noCommandQueue, noBuffer
        var errorDescription: String? {
            switch self {
            case .noCommandQueue: return "Could not create a Metal command queue."
            case .noBuffer: return "Could not allocate the panel mesh."
            }
        }
    }
}
