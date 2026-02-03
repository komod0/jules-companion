import SwiftUI
import MetalKit

// =============================================================================
// BoidsBackgroundView - A lightweight, reusable Metal-based animated background
// =============================================================================
// Displays a mesmerizing school of fish animation using the Boids flocking
// algorithm, rendered efficiently on the GPU via Metal compute shaders.
//
// Usage:
//   // Simple autoplay
//   BoidsBackgroundView(
//       fishColor: .purple,
//       backgroundColor: Color(white: 0.1)
//   )
//
//   // With playback control
//   @StateObject var controller = BoidsController()
//
//   BoidsBackgroundView(
//       fishColor: .blue,
//       backgroundColor: .black,
//       controller: controller
//   )
//   .onAppear {
//       controller.playFor(duration: 5.0)
//   }
// =============================================================================

// MARK: - Playback Controller

/// Controller for managing boids animation playback.
/// Use this to control play/stop/playFor programmatically.
public class BoidsController: ObservableObject {
    /// Whether the animation is currently playing
    @Published public private(set) var isPlaying: Bool = false

    // Internal reference to the Metal view
    weak var metalView: BoidsMetalView? {
        didSet {
            // Sync initial state
            if let view = metalView {
                view.isPaused = !isPlaying
            }
        }
    }

    private var playForTimer: Timer?

    public init() {}

    /// Start the animation
    public func play() {
        playForTimer?.invalidate()
        playForTimer = nil
        isPlaying = true
        metalView?.isPaused = false
    }

    /// Stop the animation
    public func stop() {
        playForTimer?.invalidate()
        playForTimer = nil
        isPlaying = false
        metalView?.isPaused = true
    }

    /// Play the animation for a specific duration, then stop
    /// - Parameter duration: Duration in seconds to play before stopping
    public func playFor(duration: TimeInterval) {
        play()

        playForTimer?.invalidate()
        playForTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    /// Toggle between playing and stopped states
    public func toggle() {
        if isPlaying {
            stop()
        } else {
            play()
        }
    }

    deinit {
        playForTimer?.invalidate()
    }
}

// MARK: - Configuration

/// Render mode for the boids background
public enum BoidsRenderMode {
    /// Full rendering with motion blur trails (default)
    case full
    /// Minimal rendering for maximum performance - bodies only
    case minimal
}

/// Configuration options for the boids animation
public struct BoidsConfiguration {
    /// Number of fish in the school (default: 20, range: 5-60)
    public var fishCount: Int

    /// Target frame rate (default: 60)
    public var frameRate: Int

    /// Render mode (default: .full with motion blur)
    public var renderMode: BoidsRenderMode

    /// Whether to pause when the window is minimized/hidden
    public var pauseWhenHidden: Bool

    /// Whether to automatically start playing when the view appears (default: true)
    /// Set to false if you want to control playback via BoidsController
    public var autoplay: Bool

    public init(
        fishCount: Int = 20,
        frameRate: Int = 60,
        renderMode: BoidsRenderMode = .full,
        pauseWhenHidden: Bool = true,
        autoplay: Bool = true
    ) {
        self.fishCount = min(max(fishCount, 5), 60)
        self.frameRate = min(max(frameRate, 30), 120)
        self.renderMode = renderMode
        self.pauseWhenHidden = pauseWhenHidden
        self.autoplay = autoplay
    }

    public static let `default` = BoidsConfiguration()

    /// Lightweight preset for overlays and notifications
    public static let lightweight = BoidsConfiguration(fishCount: 12, frameRate: 30, renderMode: .minimal)

    /// Performance preset for background usage
    public static let performance = BoidsConfiguration(fishCount: 15, frameRate: 60, renderMode: .minimal)

    /// Preset with autoplay disabled for manual control
    public static let manualControl = BoidsConfiguration(autoplay: false)

    /// Preset optimized for flash messages - more visible fish, smooth rendering
    public static let flashMessage = BoidsConfiguration(fishCount: 15, frameRate: 60, renderMode: .full, autoplay: false)
}

// MARK: - SwiftUI View

/// A Metal-powered animated background featuring a school of fish using the Boids algorithm.
///
/// This view is designed to be lightweight and performant, suitable for use as a background
/// layer in notifications, loading screens, or decorative elements.
///
/// - Parameters:
///   - fishColor: The color of the fish (default: purple)
///   - backgroundColor: The background color (default: dark gray)
///   - configuration: Animation configuration options
///   - controller: Optional controller for playback control (play/stop/playFor)
public struct BoidsBackgroundView: NSViewRepresentable {
    public let fishColor: Color
    public let backgroundColor: Color
    public let configuration: BoidsConfiguration
    public var controller: BoidsController?

    public init(
        fishColor: Color = Color(red: 0.541, green: 0.459, blue: 1.0), // Purple
        backgroundColor: Color = Color(white: 0.1),
        configuration: BoidsConfiguration = .default,
        controller: BoidsController? = nil
    ) {
        self.fishColor = fishColor
        self.backgroundColor = backgroundColor
        self.configuration = configuration
        self.controller = controller
    }

    public func makeNSView(context: Context) -> BoidsMetalView {
        guard let device = fluxSharedMetalDevice else {
            print("BoidsBackgroundView: Metal is not supported on this device")
            return BoidsMetalView(device: nil, configuration: configuration)
        }
        let view = BoidsMetalView(device: device, configuration: configuration)
        updateColors(view)

        // Connect controller if provided
        if let controller = controller {
            controller.metalView = view
            // Start paused if controller exists and autoplay is off
            if !configuration.autoplay {
                view.isPaused = true
            }
        } else if !configuration.autoplay {
            // No controller but autoplay is off - start paused
            view.isPaused = true
        }

        return view
    }

    public func updateNSView(_ nsView: BoidsMetalView, context: Context) {
        updateColors(nsView)

        // Update controller reference
        if let controller = controller {
            controller.metalView = nsView
        }
    }

    private func updateColors(_ view: BoidsMetalView) {
        view.renderer?.fishColor = colorToSIMD4(fishColor)
        view.renderer?.backgroundColor = colorToSIMD4(backgroundColor)
    }

    private func colorToSIMD4(_ color: Color) -> SIMD4<Float> {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        return SIMD4<Float>(
            Float(nsColor.redComponent),
            Float(nsColor.greenComponent),
            Float(nsColor.blueComponent),
            Float(nsColor.alphaComponent)
        )
    }
}

// MARK: - Metal View

/// The underlying MTKView that hosts the boids animation
public class BoidsMetalView: MTKView {
    var renderer: BoidsRenderer?
    private let configuration: BoidsConfiguration

    init(device: MTLDevice?, configuration: BoidsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero, device: device)

        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        self.framebufferOnly = true
        self.preferredFramesPerSecond = configuration.frameRate
        self.enableSetNeedsDisplay = false
        self.isPaused = !configuration.autoplay

        // Allow transparency
        self.layer?.isOpaque = false

        if let device = device {
            self.renderer = BoidsRenderer(
                device: device,
                view: self,
                configuration: configuration
            )
            self.delegate = renderer
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        delegate = nil
        renderer = nil
    }

    // MARK: - Direct Playback Control

    /// Start the animation
    public func play() {
        isPaused = false
    }

    /// Stop the animation
    public func stop() {
        isPaused = true
    }

    /// Play for a specific duration then stop
    public func playFor(duration: TimeInterval) {
        play()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.stop()
        }
    }
}

// MARK: - Renderer

/// The Metal renderer that manages the boids simulation and rendering
@MainActor
public class BoidsRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipelineState: MTLRenderPipelineState!
    private var computePipelineState: MTLComputePipelineState!
    private var vertexBuffer: MTLBuffer!
    private var particleBuffer: MTLBuffer!

    private let configuration: BoidsConfiguration
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private weak var mtkView: MTKView?

    /// Tracks whether we should respect system pause events
    /// When manually controlled, we ignore automatic pause/resume
    private var respectsSystemPause: Bool = true

    // Configurable colors
    var fishColor: SIMD4<Float> = SIMD4(0.541, 0.459, 1.0, 1.0)
    var backgroundColor: SIMD4<Float> = SIMD4(0.1, 0.1, 0.1, 1.0)

    // GPU data structures (must match Metal shader)
    struct BoidParticle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
    }

    struct BoidsUniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var padding0: Float
        var fishColor: SIMD4<Float>
        var backgroundColor: SIMD4<Float>
        var numFish: Int32
        var padding1: Int32
        var padding2: Int32
        var padding3: Int32
    }

    init(device: MTLDevice, view: MTKView, configuration: BoidsConfiguration) {
        self.device = device
        self.commandQueue = fluxSharedCommandQueue ?? device.makeCommandQueue()!
        self.configuration = configuration
        self.mtkView = view
        super.init()

        buildPipelines(view: view)
        buildBuffers()

        if configuration.pauseWhenHidden {
            setupNotifications()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleSystemPause), name: NSWindow.didMiniaturizeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemResume), name: NSWindow.didDeminiaturizeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemPause), name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemResume), name: NSApplication.didUnhideNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemPause), name: .sidebarAnimationWillStart, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemResume), name: .sidebarAnimationDidEnd, object: nil)
    }

    @objc private func handleSystemPause() {
        guard respectsSystemPause else { return }
        mtkView?.isPaused = true
    }

    @objc private func handleSystemResume() {
        guard respectsSystemPause else { return }
        mtkView?.isPaused = false
    }

    private func buildPipelines(view: MTKView) {
        guard let library = device.makeDefaultLibrary() else {
            print("BoidsRenderer: Failed to create default library")
            return
        }

        // Render Pipeline
        let vertexFunc = library.makeFunction(name: "boids_vertex")
        let fragmentName = configuration.renderMode == .minimal ? "boids_fragment_minimal" : "boids_fragment"
        let fragmentFunc = library.makeFunction(name: fragmentName)

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
            print("BoidsRenderer: Failed to create render pipeline: \(error)")
        }

        // Compute Pipeline
        if let computeFunc = library.makeFunction(name: "boids_update") {
            do {
                computePipelineState = try device.makeComputePipelineState(function: computeFunc)
            } catch {
                print("BoidsRenderer: Failed to create compute pipeline: \(error)")
            }
        }
    }

    private func buildBuffers() {
        // Full-screen quad vertices (0,0 to 1,1)
        let vertices: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1),
            SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)
        ]

        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )

        // Initialize particles
        var particles = [BoidParticle]()
        particles.reserveCapacity(configuration.fishCount)

        for i in 0..<configuration.fishCount {
            let spawnFromSide = Float.random(in: 0...1) < 0.3
            var x: Float, y: Float, vx: Float, vy: Float

            if spawnFromSide {
                let fromLeft = Bool.random()
                x = fromLeft ? -2.0 - Float.random(in: 0...0.5) : 2.0 + Float.random(in: 0...0.5)
                y = Float.random(in: -1.0...0.5)
                vx = (fromLeft ? 1 : -1) * Float.random(in: 0.2...0.5) * 0.01
                vy = Float.random(in: 0.1...0.4) * 0.01
            } else {
                // Stagger initial positions for natural look
                x = Float.random(in: -0.8...0.8)
                y = -1.5 - Float(i) * 0.1 - Float.random(in: 0...0.5)
                vx = Float.random(in: -0.2...0.2) * 0.01
                vy = Float.random(in: 0.2...0.8) * 0.01
            }

            particles.append(BoidParticle(position: SIMD2(x, y), velocity: SIMD2(vx, vy)))
        }

        particleBuffer = device.makeBuffer(
            bytes: particles,
            length: particles.count * MemoryLayout<BoidParticle>.stride,
            options: .storageModeShared
        )
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Size changes handled in draw
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderPipelineState = renderPipelineState,
              let computePipelineState = computePipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let time = Float(CACurrentMediaTime() - startTime)

        var uniforms = BoidsUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: time,
            padding0: 0,
            fishColor: fishColor,
            backgroundColor: backgroundColor,
            numFish: Int32(configuration.fishCount),
            padding1: 0,
            padding2: 0,
            padding3: 0
        )

        // Compute Pass - Run boids simulation
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<BoidsUniforms>.stride, index: 1)

            let numFish = configuration.fishCount
            let threadsPerGrid = MTLSize(width: numFish, height: 1, depth: 1)
            let w = computePipelineState.threadExecutionWidth
            let threadsPerGroup = MTLSize(width: min(numFish, w), height: 1, depth: 1)

            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }

        // Render Pass - Draw fish
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BoidsUniforms>.stride, index: 1)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoidsUniforms>.stride, index: 0)
            renderEncoder.setFragmentBuffer(particleBuffer, offset: 0, index: 1)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            renderEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Convenience Extensions

public extension BoidsBackgroundView {
    /// Creates a boids background with theme-aware colors
    static func themed(
        for appearance: NSAppearance? = nil,
        configuration: BoidsConfiguration = .default,
        controller: BoidsController? = nil
    ) -> BoidsBackgroundView {
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let fishColor = isDark
            ? Color(red: 0.541, green: 0.459, blue: 1.0)  // Purple
            : Color(red: 0.36, green: 0.38, blue: 0.41)   // Gray

        let bgColor = isDark
            ? Color(white: 0.1)
            : Color(white: 0.95)

        return BoidsBackgroundView(
            fishColor: fishColor,
            backgroundColor: bgColor,
            configuration: configuration,
            controller: controller
        )
    }
}

// MARK: - View Modifier for Boids Background

public extension View {
    /// Adds a boids animation background to this view
    /// - Parameters:
    ///   - fishColor: Color of the fish
    ///   - backgroundColor: Background color
    ///   - configuration: Animation configuration
    ///   - controller: Optional playback controller
    /// - Returns: View with boids background
    func boidsBackground(
        fishColor: Color = Color(red: 0.541, green: 0.459, blue: 1.0),
        backgroundColor: Color = Color(white: 0.1),
        configuration: BoidsConfiguration = .default,
        controller: BoidsController? = nil
    ) -> some View {
        self.background(
            BoidsBackgroundView(
                fishColor: fishColor,
                backgroundColor: backgroundColor,
                configuration: configuration,
                controller: controller
            )
        )
    }
}

// MARK: - Preview

#if DEBUG
struct BoidsBackgroundView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Default style (autoplay)
            BoidsBackgroundView()
                .frame(width: 200, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Custom colors
            BoidsBackgroundView(
                fishColor: .cyan,
                backgroundColor: Color(red: 0.05, green: 0.1, blue: 0.15)
            )
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Lightweight preset
            BoidsBackgroundView(
                fishColor: .orange,
                backgroundColor: .black,
                configuration: .lightweight
            )
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Using view modifier
            Text("Hello World")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 200, height: 80)
                .boidsBackground(
                    fishColor: .green,
                    backgroundColor: Color(white: 0.15),
                    configuration: .lightweight
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .background(Color.gray.opacity(0.2))
    }
}
#endif
