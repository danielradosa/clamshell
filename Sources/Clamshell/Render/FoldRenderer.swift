import Foundation
import Metal
import QuartzCore
import simd

final class FoldRenderer {
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

    private static let blurDownsample: CGFloat = 4
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

        let mipped = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(scaled.width), height: Int(scaled.height), mipmapped: true
        )
        mipped.usage = [.renderTarget, .shaderRead]
        mipped.storageMode = .private
        blurB = device.makeTexture(descriptor: mipped)
    }

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

    func render(source: MTLTexture, fold: Double, softness: Double,
                style: FoldStyle, drawable: CAMetalDrawable) {
        encode(source: source, fold: fold, softness: softness,
               style: style, target: drawable.texture) { buffer in
            buffer.present(drawable)
        }
    }

    func render(source: MTLTexture, fold: Double, softness: Double? = nil,
                style: FoldStyle, into target: MTLTexture,
                waitForCompletion: Bool = false) {
        encode(source: source, fold: fold, softness: softness ?? fold,
               style: style, target: target) { buffer in
            if waitForCompletion {
                buffer.commit()
                buffer.waitUntilCompleted()
            }
        }
    }

    private func encode(source: MTLTexture, fold: Double, softness: Double,
                        style: FoldStyle, target: MTLTexture,
                        finish: (MTLCommandBuffer) -> Void) {
        let size = CGSize(width: target.width, height: target.height)
        ensureBlurTextures(for: size)
        guard let blurA, let blurB,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let foldAmount = Float(min(max(fold, 0), 1))
        let softAmount = Float(min(max(softness, 0), 1))
        blurPass(commandBuffer: commandBuffer, from: source, to: blurA,
                 step: SIMD2(1.0 / Float(blurA.width), 0), radius: 1.0)
        blurPass(commandBuffer: commandBuffer, from: blurA, to: blurB,
                 step: SIMD2(0, 1.0 / Float(blurB.height)), radius: 1.0)

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: blurB)
            blit.endEncoding()
        }

        let reachInTexels = Float(style.blurRadius) / Float(Self.blurDownsample)
        let maxLOD = log2(max(reachInTexels, 1))
        let lod = maxLOD * softAmount

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
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
            blurMix: min(softAmount * 2.5, 1.0),
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
