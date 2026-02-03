import Foundation
import Metal
import MetalKit

struct VertexIn {
    let position: SIMD2<Float>
}

struct Uniforms {
    var viewportSize: SIMD2<Float>
    var cameraX: Float
    var cameraY: Float
    var scale: Float  // Retina scale factor for proper anti-aliasing
    var padding: Float = 0  // Padding to align struct to 16 bytes
}

struct InstanceData {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvMin: SIMD2<Float>
    var uvMax: SIMD2<Float>
    var color: SIMD4<Float>
}

struct RectInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var cornerRadius: Float = 0         // Corner radius for rounded rects
    var borderWidth: Float = 0          // Border width (0 = no border)
    var borderColor: SIMD4<Float> = [0, 0, 0, 0]  // Border color
    var padding: Float = 0              // Padding for memory alignment
}

@MainActor
class FluxRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let fontAtlasManager: FontAtlasManager

    /// Whether we own these resources (created them) or are borrowing shared ones
    /// When borrowing, we must not release them in deinit
    private let ownsResources: Bool

    // Pipelines
    var textPipelineState: MTLRenderPipelineState!
    var rectPipelineState: MTLRenderPipelineState!

    // MARK: - Buffer Sizing Constants
    /// Page size for buffer alignment (4KB is typical VM page size)
    private static let pageSize = 4096
    /// Headroom multiplier to avoid frequent reallocation (1.5x)
    private static let bufferHeadroomMultiplier: Double = 1.5
    /// Shrink threshold - only recreate if buffer is more than 2x needed size (50% utilization)
    private static let shrinkThreshold = 2

    // Data Buffers
    var quadBuffer: MTLBuffer!
    var instanceBuffer: MTLBuffer?
    var boldInstanceBuffer: MTLBuffer?  // Bold text instances (for header filenames)
    var rectInstanceBuffer: MTLBuffer?

    var instanceCount: Int = 0
    var boldInstanceCount: Int = 0
    var rectCount: Int = 0

    var uniforms = Uniforms(viewportSize: [100, 100], cameraX: 0, cameraY: 0, scale: 1.0)

    // Track last drawable size to avoid redundant scale updates
    private var lastDrawableSize: CGSize = .zero
    private var lastScale: CGFloat = 0

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
            self.fontAtlasManager = FontAtlasManager(device: device)
            self.ownsResources = true
        }
        super.init()

        buildPipelines()
        buildResources()
    }

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }

        // Text Pipeline
        let textDesc = MTLRenderPipelineDescriptor()
        textDesc.label = "Text Pipeline"
        textDesc.vertexFunction = library.makeFunction(name: "text_vertex")
        textDesc.fragmentFunction = library.makeFunction(name: "text_fragment")
        textDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        textDesc.colorAttachments[0].isBlendingEnabled = true
        textDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        textDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        // Vertex Layout
        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float2
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.layouts[0].stride = MemoryLayout<VertexIn>.stride
        textDesc.vertexDescriptor = vertexDesc

        do {
            self.textPipelineState = try device.makeRenderPipelineState(descriptor: textDesc)
        } catch {
            print("Failed to create text pipeline: \(error)")
        }

        // Rect Pipeline
        let rectDesc = MTLRenderPipelineDescriptor()
        rectDesc.label = "Rect Pipeline"
        rectDesc.vertexFunction = library.makeFunction(name: "rect_vertex")
        rectDesc.fragmentFunction = library.makeFunction(name: "rect_fragment")
        rectDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        rectDesc.colorAttachments[0].isBlendingEnabled = true
        rectDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rectDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        rectDesc.vertexDescriptor = vertexDesc

        do {
            self.rectPipelineState = try device.makeRenderPipelineState(descriptor: rectDesc)
        } catch {
            print("Failed to create rect pipeline: \(error)")
        }
    }

    private func buildResources() {
        let vertices: [VertexIn] = [
            VertexIn(position: [0, 0]),
            VertexIn(position: [1, 0]),
            VertexIn(position: [0, 1]),

            VertexIn(position: [1, 0]),
            VertexIn(position: [0, 1]),
            VertexIn(position: [1, 1])
        ]

        // Phase 5: Use storageModeShared for UMA optimization
        // On Apple Silicon, this allows CPU writes and GPU reads without explicit blits
        // The Unified Memory Architecture (UMA) means CPU and GPU share the same memory pool
        quadBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<VertexIn>.stride, options: .storageModeShared)
        quadBuffer?.label = "FluxRenderer.QuadBuffer"
    }

    /// Calculate optimal buffer size with headroom and page alignment.
    /// This reduces buffer recreation frequency by:
    /// 1. Adding 1.5x headroom so small size increases don't trigger reallocation
    /// 2. Aligning to page boundaries for efficient memory allocation
    private static func optimalBufferSize(for dataSize: Int) -> Int {
        guard dataSize > 0 else { return 0 }
        // Add headroom to avoid frequent reallocation
        let withHeadroom = Int(Double(dataSize) * bufferHeadroomMultiplier)
        // Round up to next page boundary
        let pages = (withHeadroom + pageSize - 1) / pageSize
        return pages * pageSize
    }

    func updateInstances(
        _ instances: [InstanceData],
        boldInstances: [InstanceData] = [],
        rects: [RectInstance],
        profilingSetViewportTime: Double = 0,
        profilingUpdateStart: Double = 0,
        profilingLineIterationTime: Double = 0,
        // Line iteration sub-phases
        profilingLineSetupTime: Double = 0,
        profilingLineNumbersTime: Double = 0,
        profilingDiffHighlightsTime: Double = 0,
        profilingSelectionTime: Double = 0,
        profilingCharRenderingTime: Double = 0
    ) {
        let updateInstancesStart = CACurrentMediaTime()
        var bufferCreationTime: Double = 0
        var memoryCopyTime: Double = 0

        self.instanceCount = instances.count
        self.boldInstanceCount = boldInstances.count
        self.rectCount = rects.count

        // Upload Text Instances
        if instanceCount > 0 {
            let size = instanceCount * MemoryLayout<InstanceData>.stride

            // Determine if we need to recreate the buffer:
            // - MUST recreate if size > buffer capacity (prevents overflow crash)
            // - SHOULD recreate if buffer is >2x needed size (50% threshold saves memory)
            // - Use headroom + page alignment when allocating to reduce future recreations
            let shouldRecreateInstanceBuffer: Bool
            if let existing = instanceBuffer {
                let currentSize = existing.length
                if size > currentSize {
                    // New data is larger than buffer - MUST recreate to avoid overflow
                    shouldRecreateInstanceBuffer = true
                } else {
                    // Only shrink if buffer is more than 2x needed size (50% utilization)
                    shouldRecreateInstanceBuffer = currentSize > size * Self.shrinkThreshold
                }
            } else {
                shouldRecreateInstanceBuffer = true
            }

            if shouldRecreateInstanceBuffer {
                let bufferStart = CACurrentMediaTime()
                // Calculate optimal size with headroom and page alignment
                let optimalSize = Self.optimalBufferSize(for: size)
                // CRITICAL: Create new buffer BEFORE releasing old one to avoid GPU stalls
                // If we release first, ARC may synchronize with GPU waiting for the old buffer
                let newBuffer = device.makeBuffer(length: optimalSize, options: .storageModeShared)
                newBuffer?.label = "FluxRenderer.InstanceBuffer"
                instanceBuffer = newBuffer  // Old buffer released here after new is ready
                bufferCreationTime += (CACurrentMediaTime() - bufferStart) * 1000
            }

            if let buffer = instanceBuffer {
                let copyStart = CACurrentMediaTime()
                // Copy instance data to GPU buffer
                instances.withUnsafeBytes { bufferPointer in
                    guard let baseAddress = bufferPointer.baseAddress,
                          bufferPointer.count >= size,
                          buffer.length >= size else {
                        print("⚠️ Invalid buffer for instances - source: \(bufferPointer.count), dest: \(buffer.length), expected: \(size)")
                        return
                    }
                    buffer.contents().copyMemory(from: baseAddress, byteCount: size)
                }
                memoryCopyTime += (CACurrentMediaTime() - copyStart) * 1000
            }
        } else {
            // Release buffer when no instances to free memory
            instanceBuffer = nil
        }

        // Upload Bold Text Instances (for header filenames)
        if boldInstanceCount > 0 {
            let size = boldInstanceCount * MemoryLayout<InstanceData>.stride

            let shouldRecreateBoldBuffer: Bool
            if let existing = boldInstanceBuffer {
                let currentSize = existing.length
                shouldRecreateBoldBuffer = size > currentSize || currentSize > size * Self.shrinkThreshold
            } else {
                shouldRecreateBoldBuffer = true
            }

            if shouldRecreateBoldBuffer {
                let bufferStart = CACurrentMediaTime()
                let optimalSize = Self.optimalBufferSize(for: size)
                let newBuffer = device.makeBuffer(length: optimalSize, options: .storageModeShared)
                newBuffer?.label = "FluxRenderer.BoldInstanceBuffer"
                boldInstanceBuffer = newBuffer
                bufferCreationTime += (CACurrentMediaTime() - bufferStart) * 1000
            }

            if let buffer = boldInstanceBuffer {
                let copyStart = CACurrentMediaTime()
                boldInstances.withUnsafeBytes { bufferPointer in
                    guard let baseAddress = bufferPointer.baseAddress,
                          bufferPointer.count >= size,
                          buffer.length >= size else {
                        print("⚠️ Invalid buffer for bold instances")
                        return
                    }
                    buffer.contents().copyMemory(from: baseAddress, byteCount: size)
                }
                memoryCopyTime += (CACurrentMediaTime() - copyStart) * 1000
            }
        } else {
            boldInstanceBuffer = nil
        }

        // Upload Rect Instances
        if rectCount > 0 {
            let size = rectCount * MemoryLayout<RectInstance>.stride

            // Same optimization logic as instance buffer
            let shouldRecreateRectBuffer: Bool
            if let existing = rectInstanceBuffer {
                let currentSize = existing.length
                if size > currentSize {
                    // New data is larger than buffer - MUST recreate to avoid overflow
                    shouldRecreateRectBuffer = true
                } else {
                    // Only shrink if buffer is more than 2x needed size (50% utilization)
                    shouldRecreateRectBuffer = currentSize > size * Self.shrinkThreshold
                }
            } else {
                shouldRecreateRectBuffer = true
            }

            if shouldRecreateRectBuffer {
                let bufferStart = CACurrentMediaTime()
                // Calculate optimal size with headroom and page alignment
                let optimalSize = Self.optimalBufferSize(for: size)
                // CRITICAL: Create new buffer BEFORE releasing old one to avoid GPU stalls
                let newBuffer = device.makeBuffer(length: optimalSize, options: .storageModeShared)
                newBuffer?.label = "FluxRenderer.RectBuffer"
                rectInstanceBuffer = newBuffer  // Old buffer released here after new is ready
                bufferCreationTime += (CACurrentMediaTime() - bufferStart) * 1000
            }

            if let buffer = rectInstanceBuffer {
                let copyStart = CACurrentMediaTime()
                // Copy rect data to GPU buffer
                rects.withUnsafeBytes { bufferPointer in
                    guard let baseAddress = bufferPointer.baseAddress,
                          bufferPointer.count >= size,
                          buffer.length >= size else {
                        print("⚠️ Invalid buffer for rects - source: \(bufferPointer.count), dest: \(buffer.length), expected: \(size)")
                        return
                    }
                    buffer.contents().copyMemory(from: baseAddress, byteCount: size)
                }
                memoryCopyTime += (CACurrentMediaTime() - copyStart) * 1000
            }
        } else {
            // Release buffer when no rects to free memory
            rectInstanceBuffer = nil
        }

        // Record profiling data
        let updateInstancesEnd = CACurrentMediaTime()
        let updateInstancesTime = (updateInstancesEnd - updateInstancesStart) * 1000
        let updateTotalTime = profilingUpdateStart > 0 ? (updateInstancesEnd - profilingUpdateStart) * 1000 : 0

        ScrollProfiler.shared.record(
            setViewport: profilingSetViewportTime,
            updateTotal: updateTotalTime,
            lineIteration: profilingLineIterationTime,
            updateInstances: updateInstancesTime,
            bufferCreation: bufferCreationTime,
            memoryCopy: memoryCopyTime,
            instanceCount: instanceCount,
            rectCount: rectCount,
            // Line iteration sub-phases
            lineSetup: profilingLineSetupTime,
            lineNumbers: profilingLineNumbersTime,
            diffHighlights: profilingDiffHighlightsTime,
            selectionHighlight: profilingSelectionTime,
            charRendering: profilingCharRenderingTime
        )
    }

    func setScroll(x: Float, y: Float) {
        uniforms.cameraX = x
        uniforms.cameraY = y
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Only update font atlas if scale actually changed
        // This avoids expensive atlas rebuilds during resize
        let scale = view.layer?.contentsScale ?? 1.0
        if scale != lastScale {
            lastScale = scale
            fontAtlasManager.updateScale(scale)
        }
        lastDrawableSize = size
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // 1. Handle Scale Factor - only update atlas if scale actually changed
        let scale = view.layer?.contentsScale ?? 1.0
        if scale != lastScale {
            lastScale = scale
            fontAtlasManager.updateScale(scale)
        }

        // 2. Viewport Calculation
        // Viewport Size must be in logical POINTS for the projection matrix
        // because our InstanceData (origin/size) is in Points.
        // drawableSize is in Pixels.
        // Points = Pixels / Scale.
        let viewportPointsW = Float(view.drawableSize.width / scale)
        let viewportPointsH = Float(view.drawableSize.height / scale)

        uniforms.viewportSize = SIMD2<Float>(viewportPointsW, viewportPointsH)
        uniforms.scale = Float(scale)

        // 3. Draw Backgrounds
        if rectCount > 0, let buf = rectInstanceBuffer {
            encoder.setRenderPipelineState(rectPipelineState)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: rectCount)
        }

        // 4. Draw Text (regular weight)
        if instanceCount > 0, let buf = instanceBuffer, let atlas = fontAtlasManager.texture {
            encoder.setRenderPipelineState(textPipelineState)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }

        // 5. Draw Bold Text (header filenames - uses bold font atlas)
        if boldInstanceCount > 0, let buf = boldInstanceBuffer, let boldAtlas = fontAtlasManager.boldTexture {
            encoder.setRenderPipelineState(textPipelineState)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.setFragmentTexture(boldAtlas, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: boldInstanceCount)
        }

        encoder.endEncoding()

        // When presentsWithTransaction is enabled, we need to synchronize
        // the Metal rendering with the Core Animation transaction for smooth resize
        if let metalLayer = view.layer as? CAMetalLayer, metalLayer.presentsWithTransaction {
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
    
    // MARK: - Memory Management

    /// Explicitly release all GPU resources to free memory.
    /// Call this when the view is being removed from the hierarchy.
    func releaseBuffers() {
        instanceBuffer = nil
        boldInstanceBuffer = nil
        rectInstanceBuffer = nil
        quadBuffer = nil
        textPipelineState = nil
        rectPipelineState = nil
        instanceCount = 0
        boldInstanceCount = 0
        rectCount = 0
    }

    deinit {
        // Release all Metal resources
        instanceBuffer = nil
        boldInstanceBuffer = nil
        rectInstanceBuffer = nil
        quadBuffer = nil
        textPipelineState = nil
        rectPipelineState = nil
    }
}
