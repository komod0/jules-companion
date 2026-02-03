import SwiftUI
import MetalKit

// =============================================================================
// MetalWaveView - GPU-Accelerated Gerstner Wave Animation
// =============================================================================
// A Metal-powered wave animation using physically accurate Gerstner (trochoidal)
// waves. Unlike simple sine waves, Gerstner waves include horizontal displacement
// that creates the characteristic sharp crests and wide troughs of real water.
//
// Usage:
//   MetalWaveView(
//       fillColor: .purple,
//       configuration: .default
//   )
// =============================================================================

// MARK: - Wave Edge Selection

/// Specifies which edge of the shape should have the animated wave
public enum WaveEdge: Int {
    /// Wave animation on the top edge (default, water surface extending upward)
    case top = 0
    /// Wave animation on the bottom edge (water surface extending downward)
    case bottom = 1
}

// MARK: - Wave Configuration

/// Configuration for a single wave component in the Gerstner sum
public struct GerstnerWaveParams {
    /// Wave height (amplitude) in points
    public var amplitude: Float

    /// Distance between wave crests in points
    public var wavelength: Float

    /// Steepness factor (0 = sine wave, approaching 1/(k*A) = sharp cusp)
    /// Higher values create sharper, more dramatic crests
    public var steepness: Float

    /// Speed multiplier for this wave component
    public var speed: Float

    /// Initial phase offset (radians)
    public var phaseOffset: Float

    public init(
        amplitude: Float = 8,
        wavelength: Float = 100,
        steepness: Float = 0.5,
        speed: Float = 1.0,
        phaseOffset: Float = 0
    ) {
        self.amplitude = amplitude
        self.wavelength = wavelength
        self.steepness = steepness
        self.speed = speed
        self.phaseOffset = phaseOffset
    }

    /// The Swell: Long, slow, rolling waves (ocean background)
    public static let swell = GerstnerWaveParams(
        amplitude: 12,
        wavelength: 200,
        steepness: 0.4,
        speed: 0.6,
        phaseOffset: 0
    )

    /// The Chop: Medium frequency surface disturbance
    public static let chop = GerstnerWaveParams(
        amplitude: 6,
        wavelength: 80,
        steepness: 0.6,
        speed: 1.0,
        phaseOffset: 1.2
    )

    /// The Ripple: High frequency detail waves
    public static let ripple = GerstnerWaveParams(
        amplitude: 3,
        wavelength: 40,
        steepness: 0.3,
        speed: 1.4,
        phaseOffset: 2.5
    )
}

/// Overall configuration for the wave animation
public struct MetalWaveConfiguration {
    /// Array of wave components to sum together
    public var waves: [GerstnerWaveParams]

    /// Gravity constant (affects dispersion - how wave speed relates to wavelength)
    public var gravity: Float

    /// Target frame rate
    public var frameRate: Int

    /// Whether to pause when the window is hidden
    public var pauseWhenHidden: Bool

    /// Which edge of the shape has the animated wave
    public var waveEdge: WaveEdge

    public init(
        waves: [GerstnerWaveParams] = [.swell, .chop, .ripple],
        gravity: Float = 9.81,
        frameRate: Int = 60,
        pauseWhenHidden: Bool = true,
        waveEdge: WaveEdge = .top
    ) {
        self.waves = waves
        self.gravity = gravity
        self.frameRate = frameRate
        self.pauseWhenHidden = pauseWhenHidden
        self.waveEdge = waveEdge
    }

    /// Default realistic ocean-like configuration
    public static let `default` = MetalWaveConfiguration()

    /// Calm, gentle waves
    public static let calm = MetalWaveConfiguration(
        waves: [
            GerstnerWaveParams(amplitude: 6, wavelength: 180, steepness: 0.3, speed: 0.5, phaseOffset: 0),
            GerstnerWaveParams(amplitude: 3, wavelength: 90, steepness: 0.25, speed: 0.7, phaseOffset: 1.0),
        ],
        gravity: 9.81
    )

    /// Dramatic, choppy waves
    public static let dramatic = MetalWaveConfiguration(
        waves: [
            GerstnerWaveParams(amplitude: 15, wavelength: 150, steepness: 0.7, speed: 0.8, phaseOffset: 0),
            GerstnerWaveParams(amplitude: 8, wavelength: 60, steepness: 0.65, speed: 1.2, phaseOffset: 0.8),
            GerstnerWaveParams(amplitude: 4, wavelength: 30, steepness: 0.5, speed: 1.6, phaseOffset: 2.0),
            GerstnerWaveParams(amplitude: 2, wavelength: 15, steepness: 0.3, speed: 2.0, phaseOffset: 3.5),
        ],
        gravity: 12.0
    )

    /// Subtle, minimal waves for UI backgrounds
    public static let subtle = MetalWaveConfiguration(
        waves: [
            GerstnerWaveParams(amplitude: 4, wavelength: 120, steepness: 0.25, speed: 0.4, phaseOffset: 0),
            GerstnerWaveParams(amplitude: 2, wavelength: 60, steepness: 0.2, speed: 0.6, phaseOffset: 1.5),
        ],
        gravity: 8.0
    )

    /// Flash message optimized configuration - wave on BOTTOM edge
    /// Using smaller amplitudes to avoid overlapping with text above
    /// Wavelengths reduced for higher frequency (more waves on screen)
    public static let flashMessage = MetalWaveConfiguration(
        waves: [
            GerstnerWaveParams(amplitude: 5, wavelength: 20, steepness: 0.6, speed: 1.5, phaseOffset: 0),
            GerstnerWaveParams(amplitude: 3, wavelength: 10, steepness: 0.55, speed: 1.9, phaseOffset: 1.0),
            GerstnerWaveParams(amplitude: 1.5, wavelength: 5, steepness: 0.45, speed: 2.4, phaseOffset: 2.2),
        ],
        gravity: 10.0,
        waveEdge: .bottom
    )
}

// MARK: - SwiftUI View

/// A Metal-powered view displaying realistic Gerstner wave animation
public struct MetalWaveView: NSViewRepresentable {
    public let fillColor: Color
    public let configuration: MetalWaveConfiguration

    public init(
        fillColor: Color = Color(red: 0.541, green: 0.459, blue: 1.0),
        configuration: MetalWaveConfiguration = .default
    ) {
        self.fillColor = fillColor
        self.configuration = configuration
    }

    public func makeNSView(context: Context) -> WaveMetalView {
        guard let device = fluxSharedMetalDevice else {
            print("MetalWaveView: Metal is not supported on this device")
            return WaveMetalView(device: nil, configuration: configuration)
        }
        let view = WaveMetalView(device: device, configuration: configuration)
        view.renderer?.fillColor = colorToSIMD4(fillColor)
        return view
    }

    public func updateNSView(_ nsView: WaveMetalView, context: Context) {
        nsView.renderer?.fillColor = colorToSIMD4(fillColor)
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

/// The underlying MTKView that hosts the wave animation
public class WaveMetalView: MTKView {
    var renderer: WaveRenderer?
    private let configuration: MetalWaveConfiguration

    init(device: MTLDevice?, configuration: MetalWaveConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero, device: device)

        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        self.framebufferOnly = true
        self.preferredFramesPerSecond = configuration.frameRate
        self.enableSetNeedsDisplay = false
        self.isPaused = false

        // 4x MSAA for crisp vector-like edges
        self.sampleCount = 4

        // Allow transparency
        self.layer?.isOpaque = false

        if let device = device {
            self.renderer = WaveRenderer(device: device, view: self, configuration: configuration)
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
}

// MARK: - Renderer

/// The Metal renderer that manages the wave mesh and rendering
@MainActor
public class WaveRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipelineState: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer!
    private var indexBuffer: MTLBuffer!
    private var waveParamsBuffer: MTLBuffer!

    private let configuration: MetalWaveConfiguration
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private weak var mtkView: MTKView?

    private var vertexCount: Int = 0
    private var indexCount: Int = 0

    // Configurable fill color
    var fillColor: SIMD4<Float> = SIMD4(0.541, 0.459, 1.0, 1.0)

    // GPU data structures (must match Metal shader)
    struct WaveVertex {
        var position: SIMD2<Float>
        var waveInfluence: Float
    }

    struct WaveParams {
        var amplitude: Float
        var wavelength: Float
        var steepness: Float
        var speed: Float
        var direction: Float
        var phaseOffset: Float
        var padding1: Float
        var padding2: Float
    }

    struct WaveUniforms {
        var viewSize: SIMD2<Float>
        var time: Float
        var gravity: Float
        var fillColor: SIMD4<Float>
        var strokeColor: SIMD4<Float>
        var strokeWidth: Float
        var cornerRadius: Float
        var waveCount: Int32
        var waveEdge: Int32  // 0 = top, 1 = bottom
    }

    init(device: MTLDevice, view: MTKView, configuration: MetalWaveConfiguration) {
        self.device = device
        self.commandQueue = fluxSharedCommandQueue ?? device.makeCommandQueue()!
        self.configuration = configuration
        self.mtkView = view
        super.init()

        buildPipelines(view: view)
        buildMesh()
        buildWaveParams()

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
        nc.addObserver(self, selector: #selector(handlePause), name: NSWindow.didMiniaturizeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleResume), name: NSWindow.didDeminiaturizeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handlePause), name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleResume), name: NSApplication.didUnhideNotification, object: nil)
    }

    @objc private func handlePause() {
        mtkView?.isPaused = true
    }

    @objc private func handleResume() {
        mtkView?.isPaused = false
    }

    private func buildPipelines(view: MTKView) {
        guard let library = device.makeDefaultLibrary() else {
            print("WaveRenderer: Failed to create default library")
            return
        }

        let vertexFunc = library.makeFunction(name: "wave_vertex")
        let fragmentFunc = library.makeFunction(name: "wave_fragment")

        // Vertex descriptor
        let vertexDescriptor = MTLVertexDescriptor()
        // Position
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // Wave influence
        vertexDescriptor.attributes[1].format = .float
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        // Layout
        vertexDescriptor.layouts[0].stride = MemoryLayout<WaveVertex>.stride

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.sampleCount = view.sampleCount

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
            print("WaveRenderer: Failed to create render pipeline: \(error)")
        }
    }

    private func buildMesh() {
        // High density mesh for smooth wave curves
        // Using triangle strip topology
        let segments = 500 // High density for smooth curves
        var vertices: [WaveVertex] = []
        vertices.reserveCapacity((segments + 1) * 2)

        // Determine which edge gets the wave based on configuration
        let waveOnBottom = configuration.waveEdge == .bottom

        for i in 0...segments {
            let x = Float(i) / Float(segments)

            if waveOnBottom {
                // Bottom edge has wave: top is pinned (y=1.0), bottom is animated (y=0.0)
                // Top vertex (pinned for bottom-edge wave)
                vertices.append(WaveVertex(position: SIMD2(x, 1.0), waveInfluence: 0.0))
                // Bottom vertex (affected by waves)
                vertices.append(WaveVertex(position: SIMD2(x, 0.0), waveInfluence: 1.0))
            } else {
                // Top edge has wave (default): top is animated (y=1.0), bottom is pinned (y=0.0)
                // Top vertex (affected by waves)
                vertices.append(WaveVertex(position: SIMD2(x, 1.0), waveInfluence: 1.0))
                // Bottom vertex (pinned)
                vertices.append(WaveVertex(position: SIMD2(x, 0.0), waveInfluence: 0.0))
            }
        }

        vertexCount = vertices.count

        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<WaveVertex>.stride,
            options: .storageModeShared
        )
    }

    private func buildWaveParams() {
        var params: [WaveParams] = []
        for wave in configuration.waves {
            params.append(WaveParams(
                amplitude: wave.amplitude,
                wavelength: wave.wavelength,
                steepness: wave.steepness,
                speed: wave.speed,
                direction: 0, // 2D wave, direction not used
                phaseOffset: wave.phaseOffset,
                padding1: 0,
                padding2: 0
            ))
        }

        // Ensure we have at least one wave
        if params.isEmpty {
            params.append(WaveParams(
                amplitude: 8,
                wavelength: 100,
                steepness: 0.5,
                speed: 1.0,
                direction: 0,
                phaseOffset: 0,
                padding1: 0,
                padding2: 0
            ))
        }

        waveParamsBuffer = device.makeBuffer(
            bytes: params,
            length: params.count * MemoryLayout<WaveParams>.stride,
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
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let time = Float(CACurrentMediaTime() - startTime)

        var uniforms = WaveUniforms(
            viewSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: time,
            gravity: configuration.gravity,
            fillColor: fillColor,
            strokeColor: SIMD4(1, 1, 1, 0.3),
            strokeWidth: 0,
            cornerRadius: 0,
            waveCount: Int32(configuration.waves.count),
            waveEdge: Int32(configuration.waveEdge.rawValue)
        )

        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<WaveUniforms>.stride, index: 1)
            renderEncoder.setVertexBuffer(waveParamsBuffer, offset: 0, index: 2)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaveUniforms>.stride, index: 0)

            // Draw as triangle strip
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)

            renderEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - View Modifier

public extension View {
    /// Adds a Metal wave animation background to this view
    func metalWaveBackground(
        fillColor: Color = Color(red: 0.541, green: 0.459, blue: 1.0),
        configuration: MetalWaveConfiguration = .default
    ) -> some View {
        self.background(
            MetalWaveView(fillColor: fillColor, configuration: configuration)
        )
    }
}

// MARK: - Preview

#if DEBUG
struct MetalWaveView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Default waves (top edge)
            VStack(alignment: .leading, spacing: 4) {
                Text("Top Edge Wave (default)").font(.caption).foregroundColor(.secondary)
                MetalWaveView(
                    fillColor: Color(red: 0.541, green: 0.459, blue: 1.0),
                    configuration: .default
                )
                .frame(width: 400, height: 100)
            }

            // Flash message style (bottom edge wave)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bottom Edge Wave (flashMessage)").font(.caption).foregroundColor(.secondary)
                MetalWaveView(
                    fillColor: Color(red: 0.541, green: 0.459, blue: 1.0),
                    configuration: .flashMessage
                )
                .frame(width: 400, height: 100)
            }

            // Calm waves
            VStack(alignment: .leading, spacing: 4) {
                Text("Calm Waves").font(.caption).foregroundColor(.secondary)
                MetalWaveView(
                    fillColor: .blue,
                    configuration: .calm
                )
                .frame(width: 400, height: 100)
            }

            // Dramatic waves
            VStack(alignment: .leading, spacing: 4) {
                Text("Dramatic Waves").font(.caption).foregroundColor(.secondary)
                MetalWaveView(
                    fillColor: .orange,
                    configuration: .dramatic
                )
                .frame(width: 400, height: 100)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.2))
    }
}
#endif
