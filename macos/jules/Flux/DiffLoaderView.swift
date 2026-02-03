import SwiftUI
import MetalKit
import QuartzCore

struct DiffLoaderView: NSViewRepresentable {
    var isClosing: Bool = false
    /// When true, skips the intro animation (sky/sun/waves descent) and starts directly
    /// in the underwater scene with bubbles and fish. Use this when returning from pagination.
    var skipIntro: Bool = false

    func makeNSView(context: Context) -> MetalDiffLoaderView {
        // Use shared Metal device to avoid context leaks (msgtracer error)
        guard let device = fluxSharedMetalDevice else {
            return MetalDiffLoaderView(device: nil, isClosing: isClosing, skipIntro: skipIntro)
        }
        return MetalDiffLoaderView(device: device, isClosing: isClosing, skipIntro: skipIntro)
    }

    func updateNSView(_ nsView: MetalDiffLoaderView, context: Context) {
        nsView.renderer?.isClosing = isClosing
    }
}

class MetalDiffLoaderView: MTKView {
    var renderer: DiffLoaderRenderer?

    // OPTIMIZATION: Fixed intrinsic content size to prevent layout recalculation
    // This stops the Metal view from triggering layout invalidation in parent views
    // during continuous animation rendering.
    override var intrinsicContentSize: NSSize {
        return NSSize(width: 90, height: 200)
    }

    init(device: MTLDevice?, isClosing: Bool, skipIntro: Bool = false) {
        // Frame: 200w x 300h
        super.init(frame: CGRect(x: 0, y: 0, width: 90, height: 200), device: device)

        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0) // Transparent
        self.framebufferOnly = true
        self.preferredFramesPerSecond = 60
        self.enableSetNeedsDisplay = false
        self.isPaused = false // Continuous animation

        // OPTIMIZATION: Prevent this view from invalidating its superview's layout
        // This is critical to prevent the Metal animation from triggering cascading
        // SwiftUI view updates when the layer presents new frames.
        self.translatesAutoresizingMaskIntoConstraints = true
        self.autoresizingMask = []  // Don't auto-resize with superview

        // Enable layer backing with settings that prevent layout propagation
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .never  // Metal handles its own drawing
        self.layerContentsPlacement = .center

        if let device = device {
            self.renderer = DiffLoaderRenderer(device: device, view: self, isClosing: isClosing, skipIntro: skipIntro)
            self.delegate = renderer
        }
    }

    required init(coder: NSCoder) {
        // Fallback for coder init
        super.init(coder: coder)
    }

    deinit {
        // Explicitly clear renderer to ensure proper cleanup
        delegate = nil
        renderer = nil
    }
}

class DiffLoaderRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var renderPipelineState: MTLRenderPipelineState!
    var computePipelineState: MTLComputePipelineState!
    var vertexBuffer: MTLBuffer!
    var particleBuffer: MTLBuffer!

    var isClosing: Bool = false {
        didSet {
            // If transition to closing, set start time if not already set
            if isClosing && closingStartTime == nil {
                closingStartTime = CACurrentMediaTime()
            }
        }
    }

    private var closingStartTime: CFTimeInterval?
    private let closingDuration: CFTimeInterval = 1.0

    // Start time for the main animation loop (using CACurrentMediaTime for efficiency)
    // When skipIntro is true, we offset the start time to skip the intro animation
    // (sky/sun/waves descent takes ~3.5s, so we start at 3.5s to show bubbles/fish immediately)
    let startTime: CFTimeInterval

    // DEBUG: Frame counter
    private var debugFrameCount = 0
    private var debugLastLogTime: CFTimeInterval = 0

    // Number of fish particles
    var numFish: Int32 = 30
    var targetNumFish: Int32 = 30
    var lastFishChangeTime: TimeInterval = 0

    struct Vertex {
        var position: SIMD2<Float>
    }

    struct FishParticle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
    }

    struct DiffLoaderUniforms {
        // Reordered for optimal 16-byte alignment
        var resolution: SIMD2<Float> // Offset 0, Size 8
        var time: Float              // Offset 8, Size 4
        var closingProgress: Float   // Offset 12, Size 4
        var numFish: Int32           // Offset 16, Size 4
        var isDarkMode: Int32        // Offset 20, Size 4 (1 for dark mode, 0 for light mode)
        var padding2: Int32          // Offset 24, Size 4
        var padding3: Int32          // Offset 28, Size 4 -> 32 bytes total (multiple of 16)
    }

    // Weak reference to view for notification handling - set in init
    private weak var mtkView: MTKView?

    /// Time offset for intro skip animation (3.5s is when Phase 5 "Deep Ocean" begins)
    private static let introSkipOffset: CFTimeInterval = 3.5

    init(device: MTLDevice, view: MTKView, isClosing: Bool, skipIntro: Bool = false) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.isClosing = isClosing
        self.mtkView = view
        // When skipIntro is true, offset start time to skip the intro animation
        // and jump directly to the underwater scene with bubbles and fish
        self.startTime = CACurrentMediaTime() - (skipIntro ? Self.introSkipOffset : 0)
        super.init()

        buildPipelines(view: view)
        buildBuffers()

        // Window Visibility Observers
        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowMiniaturized), name: NSWindow.didMiniaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowDeminiaturized), name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppHidden), name: NSApplication.didHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppUnhidden), name: NSApplication.didUnhideNotification, object: nil)

        // Sidebar Animation Observers - pause during sidebar animation to reduce GPU load
        NotificationCenter.default.addObserver(self, selector: #selector(handleSidebarAnimationWillStart), name: .sidebarAnimationWillStart, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSidebarAnimationDidEnd), name: .sidebarAnimationDidEnd, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func handleWindowMiniaturized() { mtkView?.isPaused = true }
    @objc func handleWindowDeminiaturized() { mtkView?.isPaused = false }
    @objc func handleAppHidden() { mtkView?.isPaused = true }
    @objc func handleAppUnhidden() { mtkView?.isPaused = false }
    @objc func handleSidebarAnimationWillStart() { mtkView?.isPaused = true }
    @objc func handleSidebarAnimationDidEnd() { mtkView?.isPaused = false }

    private func buildPipelines(view: MTKView) {
        guard let library = device.makeDefaultLibrary() else {
            print("Failed to make default library")
            return
        }

        // Render Pipeline
        let vertexFunc = library.makeFunction(name: "diff_loader_vertex")
        let fragmentFunc = library.makeFunction(name: "diff_loader_fragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        // Enable blending for transparency
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create render pipeline state: \(error)")
        }

        // Compute Pipeline
        if let computeFunc = library.makeFunction(name: "update_fish") {
            do {
                computePipelineState = try device.makeComputePipelineState(function: computeFunc)
            } catch {
                print("Failed to create compute pipeline state: \(error)")
            }
        } else {
            print("Could not find compute function 'update_fish'")
        }
    }

    private func buildBuffers() {
        // Full screen quad (0,0 to 1,1)
        let vertices = [
            Vertex(position: SIMD2(0, 0)),
            Vertex(position: SIMD2(1, 0)),
            Vertex(position: SIMD2(0, 1)),
            Vertex(position: SIMD2(1, 0)),
            Vertex(position: SIMD2(1, 1)),
            Vertex(position: SIMD2(0, 1))
        ]

        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: vertices.count * MemoryLayout<Vertex>.stride,
                                         options: .storageModeShared)

        // Initialize Particles
        // Start with max capacity (40) but only simulate numFish
        let maxCapacity = 40
        var particles = [FishParticle]()
        for _ in 0..<maxCapacity {
            // Initial positions are offscreen at bottom or sides
            // Fish become visible at t=2.5s, and drift up ~3 units by then
            // So spawn at Y = -4 to -6 to ensure they're still off-screen
            let spawnFromSide = Float.random(in: 0...1) < 0.3 // 30% chance to spawn from side
            var x: Float
            var y: Float
            var vx: Float
            var vy: Float

            if spawnFromSide {
                // Spawn from left or right side
                let fromLeft = Bool.random()
                x = fromLeft ? -2.0 - Float.random(in: 0...0.5) : 2.0 + Float.random(in: 0...0.5)
                y = Float.random(in: -1.0...0.5)
                vx = (fromLeft ? 1.0 : -1.0) * Float.random(in: 0.2...0.5) * 0.01
                vy = Float.random(in: 0.1...0.4) * 0.01
            } else {
                // Spawn from bottom (staggered deep below screen)
                x = Float.random(in: -0.8...0.8)
                y = -4.0 - Float.random(in: 0.0...2.0)
                vx = Float.random(in: -0.2...0.2) * 0.01
                vy = Float.random(in: 0.2...0.8) * 0.01
            }
            particles.append(FishParticle(position: SIMD2(x, y), velocity: SIMD2(vx, vy)))
        }

        particleBuffer = device.makeBuffer(bytes: particles,
                                           length: particles.count * MemoryLayout<FishParticle>.stride,
                                           options: .storageModeShared)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled in draw
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderPipelineState = renderPipelineState,
              let vertexBuffer = vertexBuffer,
              let particleBuffer = particleBuffer else {
            return
        }

        // DEBUG: Track frame rate
        debugFrameCount += 1
        let now = CACurrentMediaTime()
        if now - debugLastLogTime >= 1.0 {
            print("[DiffLoaderView] Frames/sec: \(debugFrameCount)")
            debugFrameCount = 0
            debugLastLogTime = now
        }

        let commandBuffer = commandQueue.makeCommandBuffer()

        let currentTime = CACurrentMediaTime() - startTime
        let time = Float(currentTime)

        // Update Fish Count Logic
        if currentTime - lastFishChangeTime > 5.0 { // Change every 5 seconds
            lastFishChangeTime = currentTime
            // Target a random number between 5 and 40
            targetNumFish = Int32.random(in: 5...40)
        }

        // Smoothly adjust numFish
        // In a compute shader, we can't "smoothly" change array size, but we can change the active count.
        // We'll just step it towards target.
        if numFish < targetNumFish {
            // Reset the new fish to bottom or side to avoid pop-in
            // We access the slot for the *next* fish (index = numFish, before increment)
            let index = Int(numFish)
            let pointer = particleBuffer.contents().bindMemory(to: FishParticle.self, capacity: Int(targetNumFish))

            let aspect = Float(view.drawableSize.width / view.drawableSize.height)
            let spawnFromSide = Float.random(in: 0...1) < 0.3 // 30% chance to spawn from side

            if spawnFromSide {
                // Spawn from left or right side
                let fromLeft = Bool.random()
                let startX = fromLeft ? -(aspect + 0.3) : (aspect + 0.3)
                let startY = Float.random(in: -0.8...0.5)
                let velX: Float = fromLeft ? 0.003 : -0.003
                pointer[index].position = SIMD2(startX, startY)
                pointer[index].velocity = SIMD2(velX, 0.002)
            } else {
                // Spawn from bottom
                let startX = Float.random(in: -aspect*0.9...aspect*0.9)
                pointer[index].position = SIMD2(startX, -1.5)
                pointer[index].velocity = SIMD2(0, 0.01) // Upward velocity
            }

            numFish += 1
        } else if numFish > targetNumFish {
            numFish -= 1
        }

        var progress: Float = 0.0
        if let closingStart = closingStartTime {
            let elapsed = CACurrentMediaTime() - closingStart
            progress = Float(min(elapsed / closingDuration, 1.0))
        } else if isClosing {
            // Fallback if property set but not caught in didSet
            closingStartTime = CACurrentMediaTime()
        }

        // Detect dark mode
        let isDarkMode: Int32 = {
            if let appearance = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
                return appearance == .darkAqua ? 1 : 0
            }
            return 1 // Default to dark mode
        }()

        var uniforms = DiffLoaderUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: time,
            closingProgress: progress,
            numFish: numFish,
            isDarkMode: isDarkMode,
            padding2: 0,
            padding3: 0
        )

        // Compute Pass (Boids Simulation)
        if let computePipelineState = computePipelineState, let computeEncoder = commandBuffer?.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<DiffLoaderUniforms>.stride, index: 1)

            let threadsPerGrid = MTLSize(width: Int(numFish), height: 1, depth: 1)
            let w = computePipelineState.threadExecutionWidth
            let threadsPerGroup = MTLSize(width: min(Int(numFish), w), height: 1, depth: 1)

            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }

        // Render Pass
        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        renderEncoder?.setRenderPipelineState(renderPipelineState)

        renderEncoder?.setVertexBytes(&uniforms, length: MemoryLayout<DiffLoaderUniforms>.stride, index: 1)
        renderEncoder?.setFragmentBytes(&uniforms, length: MemoryLayout<DiffLoaderUniforms>.stride, index: 0)

        // Pass particle buffer to fragment shader (buffer index 2)
        renderEncoder?.setFragmentBuffer(particleBuffer, offset: 0, index: 2)

        renderEncoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        renderEncoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        renderEncoder?.endEncoding()
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }
}
