import Foundation
import Metal
import QuartzCore
import simd

/// Draws the folded desktop panel into a CAMetalLayer.
///
/// Per frame: blur the captured desktop into a quarter-resolution texture with
/// two separable ping-pong passes, then draw the subdivided panel mesh sampling
/// both the sharp and blurred versions.
///
/// Quarter resolution is not a compromise here, it is what makes the blur wide.
/// A nine-tap kernel reaches about seven texels; at quarter resolution those are
/// twenty-eight full-resolution pixels, and running the pair twice widens it
/// again while smoothing the profile toward a real gaussian. A single half-res
/// pass with the radius cranked up instead produces visible ringing, because
/// nine taps cannot represent a kernel that wide.
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
        var blurLOD: Float = 0
        var vignette: Float = 0
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

    /// How far down the blur chain runs. Four gives a wide, smooth blur for the
    /// cost of a sixteenth of the pixels.
    private static let blurDownsample: CGFloat = 4
    /// Separable passes run twice; each pair roughly doubles the effective width
    /// and pulls the kernel shape closer to a gaussian.
    private static let blurIterations = 2

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
        let scaled = CGSize(
            width: max(size.width / Self.blurDownsample, 1),
            height: max(size.height / Self.blurDownsample, 1)
        )
        guard scaled != blurSize || blurA == nil else { return }
        blurSize = scaled

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(scaled.width), height: Int(scaled.height), mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        blurA = device.makeTexture(descriptor: desc)

        // The final blur target carries a full mip chain; the levels are what
        // supply blur width.
        let mipped = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(scaled.width), height: Int(scaled.height), mipmapped: true
        )
        mipped.usage = [.renderTarget, .shaderRead]
        mipped.storageMode = .private
        blurB = device.makeTexture(descriptor: mipped)
    }

    /// Copies a texture into a private one this renderer owns, allocating the
    /// destination if needed. Used to keep a desktop snapshot that outlives the
    /// capture stream.
    func copy(_ source: MTLTexture, into existing: MTLTexture?) -> MTLTexture? {
        var destination = existing
        if destination == nil
            || destination?.width != source.width
            || destination?.height != source.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width, height: source.height, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            destination = device.makeTexture(descriptor: desc)
        }
        guard let destination,
              let buffer = commandQueue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else { return existing }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
        buffer.commit()
        return destination
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
        // A light separable prefilter, one texel wide. Its job is only to stop
        // the mip chain aliasing on the way down; the width comes from the mips.
        blurPass(commandBuffer: commandBuffer, from: source, to: blurA,
                 step: SIMD2(1.0 / Float(blurA.width), 0), radius: 1.0)
        blurPass(commandBuffer: commandBuffer, from: blurA, to: blurB,
                 step: SIMD2(0, 1.0 / Float(blurB.height)), radius: 1.0)

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: blurB)
            blit.endEncoding()
        }

        // Map the style's reach, expressed in screen pixels, onto a mip level.
        // The chain starts at a quarter resolution and every level doubles the
        // blur, so the level is the log of the reach in chain texels.
        let reachInTexels = Float(style.blurRadius) / Float(Self.blurDownsample)
        let maxLOD = log2(max(reachInTexels, 1))
        // Slightly sub-linear, so softening is clearly underway early rather
        // than arriving all at once near the end of the travel.
        let lod = maxLOD * pow(foldAmount, 0.85)

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
            // Fully crossed over to the blurred copy by a third of the way in.
            // Past that the radius alone carries the effect, which is what makes
            // the last stretch go properly soft rather than merely hazy.
            blurMix: min(foldAmount * 3.0, 1.0),
            blurLOD: lod,
            vignette: Float(style.vignette),
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
