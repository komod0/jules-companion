import Foundation
import Metal
import simd

// MARK: - GPU Compute Culling

/// ComputeCuller handles GPU-side visibility testing for large line counts.
/// Uses a compute shader to determine which lines are visible, enabling
/// efficient culling without CPU iteration.
///
/// Usage:
/// 1. Upload line layouts via `updateLineLayouts(_:)`
/// 2. Call `computeVisibility(viewportTop:viewportBottom:)` before rendering
/// 3. Read visibility results from `visibilityBuffer` or use indirect draw
@MainActor
final class ComputeCuller {

    // MARK: - GPU Structures (must match Shaders.metal)

    struct LineLayout {
        var yMin: Float
        var yMax: Float
    }

    struct CullParams {
        var viewportTop: Float
        var viewportBottom: Float
        var lineCount: UInt32
        var padding: UInt32
    }

    struct VisibilityResult {
        var visible: UInt32
        var lineIndex: UInt32
    }

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Compute pipeline for visibility testing
    private var visibilityPipeline: MTLComputePipelineState?

    /// Compute pipeline for stream compaction
    private var compactPipeline: MTLComputePipelineState?

    /// Buffer containing line layout data (yMin, yMax per line)
    private var lineLayoutBuffer: MTLBuffer?

    /// Buffer containing visibility results
    private(set) var visibilityBuffer: MTLBuffer?

    /// Buffer containing culling parameters
    private var paramsBuffer: MTLBuffer?

    /// Maximum number of lines supported
    private let maxLineCount = 100_000

    /// Current line count
    private var lineCount: Int = 0

    // MARK: - Initialization

    init?(device: MTLDevice) {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.commandQueue.label = "ComputeCuller.commandQueue"

        // Create buffers
        createBuffers()

        // Build compute pipelines
        buildPipelines()
    }

    private func createBuffers() {
        // Line layout buffer
        let layoutSize = maxLineCount * MemoryLayout<LineLayout>.stride
        lineLayoutBuffer = device.makeBuffer(length: layoutSize, options: .storageModeShared)
        lineLayoutBuffer?.label = "ComputeCuller.lineLayoutBuffer"

        // Visibility result buffer
        let visibilitySize = maxLineCount * MemoryLayout<VisibilityResult>.stride
        visibilityBuffer = device.makeBuffer(length: visibilitySize, options: .storageModeShared)
        visibilityBuffer?.label = "ComputeCuller.visibilityBuffer"

        // Params buffer
        let paramsSize = MemoryLayout<CullParams>.stride
        paramsBuffer = device.makeBuffer(length: paramsSize, options: .storageModeShared)
        paramsBuffer?.label = "ComputeCuller.paramsBuffer"
    }

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            print("ComputeCuller: Failed to load default library")
            return
        }

        // Visibility compute pipeline
        if let visibilityFunc = library.makeFunction(name: "compute_visibility") {
            do {
                visibilityPipeline = try device.makeComputePipelineState(function: visibilityFunc)
            } catch {
                print("ComputeCuller: Failed to create visibility pipeline: \(error)")
            }
        }

        // Compaction compute pipeline
        if let compactFunc = library.makeFunction(name: "compact_visible_instances") {
            do {
                compactPipeline = try device.makeComputePipelineState(function: compactFunc)
            } catch {
                print("ComputeCuller: Failed to create compact pipeline: \(error)")
            }
        }
    }

    // MARK: - Layout Updates

    /// Update line layouts for GPU culling.
    /// - Parameter layouts: Array of (yMin, yMax) pairs for each line
    func updateLineLayouts(_ layouts: [SIMD2<Float>]) {
        self.lineCount = min(layouts.count, maxLineCount)
        guard lineCount > 0, let buffer = lineLayoutBuffer else { return }

        // Convert to LineLayout structs
        let lineLayouts = layouts.prefix(lineCount).map { LineLayout(yMin: $0.x, yMax: $0.y) }

        // Copy to GPU buffer
        let size = lineCount * MemoryLayout<LineLayout>.stride
        lineLayouts.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: size)
        }
    }

    // MARK: - Visibility Computation

    /// Compute visibility for all lines using GPU.
    /// - Parameters:
    ///   - viewportTop: Top of visible area (scroll offset)
    ///   - viewportBottom: Bottom of visible area
    /// - Returns: True if compute succeeded, false otherwise
    @discardableResult
    func computeVisibility(viewportTop: Float, viewportBottom: Float) -> Bool {
        guard lineCount > 0,
              let pipeline = visibilityPipeline,
              let layoutBuffer = lineLayoutBuffer,
              let visBuffer = visibilityBuffer,
              let pBuffer = paramsBuffer else {
            return false
        }

        // Update params
        var params = CullParams(
            viewportTop: viewportTop,
            viewportBottom: viewportBottom,
            lineCount: UInt32(lineCount),
            padding: 0
        )
        pBuffer.contents().copyMemory(from: &params, byteCount: MemoryLayout<CullParams>.stride)

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(layoutBuffer, offset: 0, index: 0)
        encoder.setBuffer(pBuffer, offset: 0, index: 1)
        encoder.setBuffer(visBuffer, offset: 0, index: 2)

        // Dispatch threads
        let threadGroupSize = min(pipeline.maxTotalThreadsPerThreadgroup, lineCount)
        let threadGroups = (lineCount + threadGroupSize - 1) / threadGroupSize

        encoder.dispatchThreadgroups(
            MTLSize(width: threadGroups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadGroupSize, height: 1, depth: 1)
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return true
    }

    // MARK: - Results Access

    /// Get visibility results from GPU buffer.
    /// - Returns: Array of (lineIndex, isVisible) pairs
    func getVisibilityResults() -> [(lineIndex: Int, visible: Bool)] {
        guard lineCount > 0, let buffer = visibilityBuffer else {
            return []
        }

        let results = buffer.contents().bindMemory(
            to: VisibilityResult.self,
            capacity: lineCount
        )

        return (0..<lineCount).map { i in
            (lineIndex: Int(results[i].lineIndex), visible: results[i].visible != 0)
        }
    }

    /// Get indices of visible lines.
    /// - Returns: Array of visible line indices, sorted
    func getVisibleLineIndices() -> [Int] {
        return getVisibilityResults()
            .filter { $0.visible }
            .map { $0.lineIndex }
            .sorted()
    }

    // MARK: - Cleanup

    deinit {
        lineLayoutBuffer = nil
        visibilityBuffer = nil
        paramsBuffer = nil
    }
}

// MARK: - Integration Helper

extension ComputeCuller {
    /// Check if GPU culling would be beneficial for the given line count.
    /// GPU culling has overhead, so it's only beneficial for large line counts.
    static func shouldUseGPUCulling(lineCount: Int) -> Bool {
        // GPU culling is beneficial for large diffs (>5000 lines)
        // Below this, CPU culling is faster due to GPU dispatch overhead
        return lineCount > 5000
    }
}
