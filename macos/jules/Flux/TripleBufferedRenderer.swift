import Foundation
import Metal
import MetalKit
import QuartzCore

// MARK: - Shader Structures (must match Shaders.metal)

struct TripleBufferVertexIn {
    let position: SIMD2<Float>
}

struct TripleBufferUniforms {
    var viewportSize: SIMD2<Float>
    var cameraX: Float
    var cameraY: Float
}

struct TripleBufferInstanceData {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvMin: SIMD2<Float>
    var uvMax: SIMD2<Float>
    var color: SIMD4<Float>
}

struct TripleBufferRectInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var cornerRadius: Float = 0
    var borderWidth: Float = 0
    var borderColor: SIMD4<Float> = [0, 0, 0, 0]
    var padding: Float = 0
}

// MARK: - Frame Resources

/// Phase 3: Container for per-frame GPU resources
/// Each frame has its own set of buffers to avoid CPU/GPU contention
final class FrameResources {
    /// Maximum instance capacity per buffer
    static let maxInstances = 100_000
    static let maxRects = 50_000

    /// Vertex buffer for text instances
    let instanceBuffer: MTLBuffer

    /// Vertex buffer for rect instances
    let rectBuffer: MTLBuffer

    /// Uniform buffer for viewport/camera data
    let uniformBuffer: MTLBuffer

    /// Current instance counts
    var instanceCount: Int = 0
    var rectCount: Int = 0

    init(device: MTLDevice) {
        // Phase 5: Use storageModeShared for UMA optimization
        // This allows CPU writes and GPU reads without explicit blits
        let instanceSize = FrameResources.maxInstances * MemoryLayout<TripleBufferInstanceData>.stride
        let rectSize = FrameResources.maxRects * MemoryLayout<TripleBufferRectInstance>.stride
        let uniformSize = MemoryLayout<TripleBufferUniforms>.stride

        guard let instBuf = device.makeBuffer(length: instanceSize, options: .storageModeShared),
              let rectBuf = device.makeBuffer(length: rectSize, options: .storageModeShared),
              let uniformBuf = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
            fatalError("Failed to create frame resource buffers")
        }

        self.instanceBuffer = instBuf
        self.rectBuffer = rectBuf
        self.uniformBuffer = uniformBuf

        // Label for debugging
        instanceBuffer.label = "FrameResources.instanceBuffer"
        rectBuffer.label = "FrameResources.rectBuffer"
        uniformBuffer.label = "FrameResources.uniformBuffer"
    }

    /// Update instance data
    func updateInstances(_ instances: [TripleBufferInstanceData]) {
        instanceCount = min(instances.count, FrameResources.maxInstances)
        guard instanceCount > 0 else { return }

        let size = instanceCount * MemoryLayout<TripleBufferInstanceData>.stride
        instances.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            instanceBuffer.contents().copyMemory(from: baseAddress, byteCount: size)
        }
    }

    /// Update rect data
    func updateRects(_ rects: [TripleBufferRectInstance]) {
        rectCount = min(rects.count, FrameResources.maxRects)
        guard rectCount > 0 else { return }

        let size = rectCount * MemoryLayout<TripleBufferRectInstance>.stride
        rects.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            rectBuffer.contents().copyMemory(from: baseAddress, byteCount: size)
        }
    }

    /// Update uniforms
    func updateUniforms(_ uniforms: TripleBufferUniforms) {
        var mutableUniforms = uniforms
        uniformBuffer.contents().copyMemory(
            from: &mutableUniforms,
            byteCount: MemoryLayout<TripleBufferUniforms>.stride
        )
    }
}

// MARK: - Triple Buffered Renderer

/// Phase 3: High-throughput renderer with triple buffering for 120Hz displays
///
/// Key features:
/// - Triple buffering prevents CPU from blocking on GPU
/// - Semaphore-based synchronization (value 3)
/// - Automatic buffer cycling: bufferIndex = (bufferIndex + 1) % 3
/// - GPU completion signaling via semaphore
@MainActor
final class TripleBufferedRenderer: NSObject {

    // MARK: - Metal Core

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let fontAtlasManager: FontAtlasManager

    /// Whether we own these resources (created them) or are borrowing shared ones
    /// When borrowing, we must not release them in deinit
    private let ownsResources: Bool

    // MARK: - Pipelines

    private var textPipelineState: MTLRenderPipelineState!
    private var rectPipelineState: MTLRenderPipelineState!

    // MARK: - Shared Resources

    /// Base quad geometry (2 triangles forming a unit quad)
    private var quadBuffer: MTLBuffer!

    // MARK: - Triple Buffering

    /// Pool of frame resources for triple buffering
    private let frameResources: [FrameResources]

    /// Semaphore for triple buffering synchronization
    /// Value 3 means up to 3 frames can be in flight simultaneously
    private let frameSemaphore = DispatchSemaphore(value: 3)

    /// Current buffer index for round-robin selection
    private var bufferIndex: Int = 0

    // MARK: - State

    /// Current clear color
    var clearColor: MTLClearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

    /// Camera/scroll offsets
    private var cameraX: Float = 0
    private var cameraY: Float = 0

    /// Last drawable size for change detection
    private var lastDrawableSize: CGSize = .zero
    private var lastScale: CGFloat = 0

    // MARK: - Initialization

    /// Initialize with shared resources to avoid context leaks during rapid tile recycling.
    /// Uses fluxSharedCommandQueue and fluxSharedFontAtlasManager when available.
    init?(device: MTLDevice) {
        self.device = device

        // Use shared resources when available to avoid context leaks from rapid creation/destruction
        if let sharedQueue = fluxSharedCommandQueue, let sharedAtlas = fluxSharedFontAtlasManager {
            self.commandQueue = sharedQueue
            self.fontAtlasManager = sharedAtlas
            self.ownsResources = false
        } else {
            // Fallback to creating our own resources
            guard let queue = device.makeCommandQueue() else { return nil }
            self.commandQueue = queue
            self.commandQueue.label = "TripleBufferedRenderer.commandQueue"
            self.fontAtlasManager = FontAtlasManager(device: device)
            self.ownsResources = true
        }

        // Create triple-buffered frame resources
        self.frameResources = [
            FrameResources(device: device),
            FrameResources(device: device),
            FrameResources(device: device)
        ]

        super.init()

        buildPipelines()
        buildQuadBuffer()
    }

    // MARK: - Pipeline Setup

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            print("TripleBufferedRenderer: Failed to load default library")
            return
        }

        // Text Pipeline
        let textDesc = MTLRenderPipelineDescriptor()
        textDesc.label = "TripleBuffered.TextPipeline"
        textDesc.vertexFunction = library.makeFunction(name: "text_vertex")
        textDesc.fragmentFunction = library.makeFunction(name: "text_fragment")
        textDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Alpha blending for text
        textDesc.colorAttachments[0].isBlendingEnabled = true
        textDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        textDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        textDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Vertex descriptor
        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float2
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.layouts[0].stride = MemoryLayout<TripleBufferVertexIn>.stride
        textDesc.vertexDescriptor = vertexDesc

        do {
            textPipelineState = try device.makeRenderPipelineState(descriptor: textDesc)
        } catch {
            print("TripleBufferedRenderer: Failed to create text pipeline: \(error)")
        }

        // Rect Pipeline
        let rectDesc = MTLRenderPipelineDescriptor()
        rectDesc.label = "TripleBuffered.RectPipeline"
        rectDesc.vertexFunction = library.makeFunction(name: "rect_vertex")
        rectDesc.fragmentFunction = library.makeFunction(name: "rect_fragment")
        rectDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Alpha blending for rects
        rectDesc.colorAttachments[0].isBlendingEnabled = true
        rectDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rectDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        rectDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        rectDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        rectDesc.vertexDescriptor = vertexDesc

        do {
            rectPipelineState = try device.makeRenderPipelineState(descriptor: rectDesc)
        } catch {
            print("TripleBufferedRenderer: Failed to create rect pipeline: \(error)")
        }
    }

    private func buildQuadBuffer() {
        // Unit quad: 2 triangles covering 0,0 to 1,1
        let vertices: [TripleBufferVertexIn] = [
            TripleBufferVertexIn(position: [0, 0]),
            TripleBufferVertexIn(position: [1, 0]),
            TripleBufferVertexIn(position: [0, 1]),

            TripleBufferVertexIn(position: [1, 0]),
            TripleBufferVertexIn(position: [0, 1]),
            TripleBufferVertexIn(position: [1, 1])
        ]

        quadBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<TripleBufferVertexIn>.stride,
            options: .storageModeShared
        )
        quadBuffer?.label = "TripleBuffered.QuadBuffer"
    }

    // MARK: - Scroll Control

    func setScroll(x: Float, y: Float) {
        cameraX = x
        cameraY = y
    }

    // MARK: - Instance Updates

    /// Update the current frame's instance data
    /// Call this before render() to update content
    func updateInstances(_ instances: [InstanceData], rects: [RectInstance]) {
        // Convert to triple buffer types (they have the same layout)
        let tripleInstances = instances.map { inst in
            TripleBufferInstanceData(
                origin: inst.origin,
                size: inst.size,
                uvMin: inst.uvMin,
                uvMax: inst.uvMax,
                color: inst.color
            )
        }

        let tripleRects = rects.map { rect in
            TripleBufferRectInstance(
                origin: rect.origin,
                size: rect.size,
                color: rect.color,
                cornerRadius: rect.cornerRadius,
                borderWidth: rect.borderWidth,
                borderColor: rect.borderColor,
                padding: rect.padding
            )
        }

        // Update the current frame's resources
        let frame = frameResources[bufferIndex]
        frame.updateInstances(tripleInstances)
        frame.updateRects(tripleRects)
    }

    // MARK: - Rendering

    /// Render a frame to the given drawable
    /// - Parameters:
    ///   - drawable: The CAMetalDrawable to render to
    ///   - viewportSize: Viewport size in points
    ///   - presentWithTransaction: Whether to present synchronously with CA transaction
    func render(
        to drawable: CAMetalDrawable,
        viewportSize: SIMD2<Float>,
        presentWithTransaction: Bool = false
    ) {
        // Wait for a frame slot to become available
        // This blocks if 3 frames are already in flight
        _ = frameSemaphore.wait(timeout: .distantFuture)

        // Get current frame resources
        let frame = frameResources[bufferIndex]

        // Advance to next buffer for the next frame
        bufferIndex = (bufferIndex + 1) % 3

        // Update uniforms for this frame
        let uniforms = TripleBufferUniforms(
            viewportSize: viewportSize,
            cameraX: cameraX,
            cameraY: cameraY
        )
        frame.updateUniforms(uniforms)

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }
        commandBuffer.label = "TripleBuffered.Frame"

        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor

        // Create render encoder
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            frameSemaphore.signal()
            return
        }
        encoder.label = "TripleBuffered.RenderEncoder"

        // Draw background rects first
        if frame.rectCount > 0 {
            encoder.setRenderPipelineState(rectPipelineState)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(frame.rectBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(frame.uniformBuffer, offset: 0, index: 2)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: frame.rectCount
            )
        }

        // Draw text instances
        if frame.instanceCount > 0, let atlas = fontAtlasManager.texture {
            encoder.setRenderPipelineState(textPipelineState)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(frame.instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(frame.uniformBuffer, offset: 0, index: 2)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: frame.instanceCount
            )
        }

        encoder.endEncoding()

        // Signal semaphore when GPU completes
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameSemaphore.signal()
        }

        // Present based on mode
        if presentWithTransaction {
            // Sync mode: wait for GPU, then present in CA transaction
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            // Async mode: present immediately (maximum throughput)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    // MARK: - Memory Management

    /// Clear all frame resource data to free memory.
    /// Call this when the view is being hidden or removed.
    func clearFrameData() {
        // Reset counts to indicate no data to render
        for frame in frameResources {
            frame.instanceCount = 0
            frame.rectCount = 0
        }
    }

    deinit {
        // Wait for all in-flight frames to complete
        for _ in 0..<3 {
            _ = frameSemaphore.wait(timeout: .now() + 1.0)
        }
    }
}

// MARK: - MTKViewDelegate Conformance

extension TripleBufferedRenderer: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Task { @MainActor in
            let scale = view.layer?.contentsScale ?? 1.0
            if scale != lastScale {
                lastScale = scale
                fontAtlasManager.updateScale(scale)
            }
            lastDrawableSize = size
        }
    }

    nonisolated func draw(in view: MTKView) {
        Task { @MainActor in
            guard let drawable = view.currentDrawable else { return }

            let scale = view.layer?.contentsScale ?? 1.0
            if scale != lastScale {
                lastScale = scale
                fontAtlasManager.updateScale(scale)
            }

            let viewportW = Float(view.drawableSize.width / scale)
            let viewportH = Float(view.drawableSize.height / scale)

            let presentsWithTransaction: Bool
            if let metalLayer = view.layer as? CAMetalLayer {
                presentsWithTransaction = metalLayer.presentsWithTransaction
            } else {
                presentsWithTransaction = false
            }

            render(
                to: drawable,
                viewportSize: SIMD2<Float>(viewportW, viewportH),
                presentWithTransaction: presentsWithTransaction
            )
        }
    }
}
