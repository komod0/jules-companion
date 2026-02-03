import SwiftUI

// MARK: - Wave Configuration (Legacy - for animation timing)

/// Configuration for wave animation timing (used for entry/exit animations)
struct WaveConfiguration {
    /// Height of the wave peaks/crests (default: 8)
    var amplitude: CGFloat = 8

    /// Depth of the wave troughs/valleys - can differ from amplitude for asymmetric waves (default: 6)
    var trough: CGFloat = 6

    /// Speed of wave movement (default: 1.0, higher = faster)
    var speed: Double = 1.0

    /// Number of wave peaks across the width
    var frequency: CGFloat = 2.5

    /// Inertia for animation timing
    var inertia: CGFloat = 0.8

    static let `default` = WaveConfiguration()

    static let subtle = WaveConfiguration(
        amplitude: 5,
        trough: 4,
        speed: 0.8,
        frequency: 2.0,
        inertia: 0.9
    )

    static let dramatic = WaveConfiguration(
        amplitude: 12,
        trough: 10,
        speed: 1.5,
        frequency: 3.0,
        inertia: 0.6
    )

    static let ocean = WaveConfiguration(
        amplitude: 10,
        trough: 8,
        speed: 0.7,
        frequency: 2.0,
        inertia: 1.2
    )

    /// Convert to Metal wave configuration
    var metalConfiguration: MetalWaveConfiguration {
        switch self {
        case _ where self.speed > 1.2:
            return .dramatic
        case _ where self.inertia > 1.0:
            return .calm
        case _ where self.amplitude < 6:
            return .subtle
        default:
            return .flashMessage
        }
    }
}

// MARK: - Animation Phase

enum WaveFlashPhase: Equatable {
    case hidden
    case wavingIn
    case showing
    case washingAway
}

// MARK: - Wave Flash Message View

/// A styled flash message with animated wave bottom border
struct WaveFlashMessageView: View {
    let message: String
    let type: FlashMessageType
    let cornerRadius: CGFloat
    let waveConfiguration: WaveConfiguration
    let showBoids: Bool
    let onDismiss: (() -> Void)?

    @State private var phase: WaveFlashPhase = .hidden
    @State private var waveOffset: CGFloat = 0
    @State private var contentOpacity: Double = 0

    @StateObject private var boidsController = BoidsController()

    init(
        message: String,
        type: FlashMessageType,
        cornerRadius: CGFloat = 12,
        waveConfiguration: WaveConfiguration = .default,
        showBoids: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.message = message
        self.type = type
        self.cornerRadius = cornerRadius
        self.waveConfiguration = waveConfiguration
        self.showBoids = showBoids
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Background with wave
                backgroundLayer(width: geometry.size.width, height: geometry.size.height)

                // Optional Boids background - rendered when visible, controlled by boidsController
                if showBoids && phase != .hidden {
                    BoidsBackgroundView(
                        fishColor: type.foregroundColor.opacity(0.85),
                        backgroundColor: .clear,
                        configuration: .flashMessage,
                        controller: boidsController
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(y: waveOffset)
                    .clipShape(
                        RoundedCornerShape(
                            corners: [.topLeft, .topRight],
                            radius: cornerRadius
                        )
                    )
                }

                // Content
                contentLayer
                    .opacity(contentOpacity)
            }
            .clipShape(
                RoundedCornerShape(
                    corners: [.topLeft, .topRight],
                    radius: cornerRadius
                )
            )
            .mask(maskLayer(height: geometry.size.height))
        }
        .frame(height: calculateHeight())
        .onAppear {
            startWaveInAnimation()
            // Start boids early so they're visible during wave-in animation
            if showBoids {
                boidsController.play()
            }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .washingAway {
                boidsController.stop()
            }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func backgroundLayer(width: CGFloat, height: CGFloat) -> some View {
        // Use Metal-based Gerstner wave for realistic fluid animation
        // The wave shape fills from top to the wavy line, leaving transparency below
        if phase != .hidden {
            MetalWaveView(
                fillColor: type.backgroundColor,
                configuration: waveConfiguration.metalConfiguration
            )
            .frame(height: height)
            .offset(y: waveOffset)
        } else {
            // When hidden, just use solid background (will be masked anyway)
            type.backgroundColor
        }
    }

    private var contentLayer: some View {
        HStack(spacing: 10) {
            Spacer()

            Text(message)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(type.foregroundColor)
                .lineLimit(2)

            Spacer()

            if onDismiss != nil {
                Button {
                    startWashAwayAnimation {
                        onDismiss?()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(type.foregroundColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func maskLayer(height: CGFloat) -> some View {
        switch phase {
        case .hidden:
            Rectangle()
                .frame(height: 0)
        case .wavingIn, .showing, .washingAway:
            // Simple rectangle mask - the waveOffset handles all animation
            Rectangle()
        }
    }

    // MARK: - Animation

    private func calculateHeight() -> CGFloat {
        // Account for varied peaks - use 1.6x multiplier (max seed value) for safety
        let maxAmplitude = max(waveConfiguration.amplitude, waveConfiguration.trough) * 1.6
        return 55 + maxAmplitude
    }

    private func startWaveInAnimation() {
        phase = .wavingIn
        // Start above the visible area (negative offset = pushed up)
        waveOffset = -calculateHeight()

        // Smooth eased entry - easeOut gives a natural deceleration as it arrives
        let duration = 0.5 * Double(waveConfiguration.inertia)

        withAnimation(
            .easeOut(duration: duration)
        ) {
            waveOffset = 0
        }

        // Content fades in slightly delayed with easing
        let fadeDelay = duration * 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay) {
            withAnimation(.easeOut(duration: 0.25)) {
                contentOpacity = 1
            }
        }

        // Transition to showing state after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            phase = .showing
        }
    }

    /// Starts the exit animation: wave recedes upward maintaining its shape
    func startWashAwayAnimation(completion: (() -> Void)? = nil) {
        phase = .washingAway

        let exitOffset = -(calculateHeight() + 20) // Negative = recede up above the view

        // Wave recedes back up where it came from, maintaining its wavy shape
        let duration = 0.4 * Double(waveConfiguration.inertia)

        withAnimation(.easeIn(duration: duration)) {
            waveOffset = exitOffset
            contentOpacity = 0
        }

        // Complete after animation finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            phase = .hidden
            completion?()
        }
    }
}


// MARK: - Rounded Corner Shape

/// A shape with specific corners rounded
struct RoundedCornerShape: Shape {
    var corners: NSRectCorner
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - NSRectCorner

struct NSRectCorner: OptionSet {
    let rawValue: Int

    static let topLeft = NSRectCorner(rawValue: 1 << 0)
    static let topRight = NSRectCorner(rawValue: 1 << 1)
    static let bottomLeft = NSRectCorner(rawValue: 1 << 2)
    static let bottomRight = NSRectCorner(rawValue: 1 << 3)

    static let allCorners: NSRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

// MARK: - NSBezierPath Extension

extension NSBezierPath {
    convenience init(roundedRect rect: CGRect, byRoundingCorners corners: NSRectCorner, cornerRadii: CGSize) {
        self.init()

        let topLeft = corners.contains(.topLeft) ? cornerRadii : .zero
        let topRight = corners.contains(.topRight) ? cornerRadii : .zero
        let bottomLeft = corners.contains(.bottomLeft) ? cornerRadii : .zero
        let bottomRight = corners.contains(.bottomRight) ? cornerRadii : .zero

        // Start at top-left, after the corner
        move(to: CGPoint(x: rect.minX + topLeft.width, y: rect.minY))

        // Top edge and top-right corner
        line(to: CGPoint(x: rect.maxX - topRight.width, y: rect.minY))
        if corners.contains(.topRight) {
            appendArc(
                withCenter: CGPoint(x: rect.maxX - topRight.width, y: rect.minY + topRight.height),
                radius: topRight.width,
                startAngle: -90,
                endAngle: 0,
                clockwise: false
            )
        }

        // Right edge and bottom-right corner
        line(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight.height))
        if corners.contains(.bottomRight) {
            appendArc(
                withCenter: CGPoint(x: rect.maxX - bottomRight.width, y: rect.maxY - bottomRight.height),
                radius: bottomRight.width,
                startAngle: 0,
                endAngle: 90,
                clockwise: false
            )
        }

        // Bottom edge and bottom-left corner
        line(to: CGPoint(x: rect.minX + bottomLeft.width, y: rect.maxY))
        if corners.contains(.bottomLeft) {
            appendArc(
                withCenter: CGPoint(x: rect.minX + bottomLeft.width, y: rect.maxY - bottomLeft.height),
                radius: bottomLeft.width,
                startAngle: 90,
                endAngle: 180,
                clockwise: false
            )
        }

        // Left edge and top-left corner
        line(to: CGPoint(x: rect.minX, y: rect.minY + topLeft.height))
        if corners.contains(.topLeft) {
            appendArc(
                withCenter: CGPoint(x: rect.minX + topLeft.width, y: rect.minY + topLeft.height),
                radius: topLeft.width,
                startAngle: 180,
                endAngle: 270,
                clockwise: false
            )
        }

        close()
    }

    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)

        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }

        return path
    }
}

// MARK: - Preview

#if DEBUG
struct WaveFlashMessageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 30) {
            // Default wave flash
            WaveFlashMessageView(
                message: "Submitting Task",
                type: .success,
                cornerRadius: 12,
                showBoids: false,
                onDismiss: {}
            )
            .frame(width: 580)

            // With Boids and dramatic physics (bouncy)
            WaveFlashMessageView(
                message: "Processing...",
                type: .info,
                cornerRadius: 12,
                waveConfiguration: .dramatic,
                showBoids: true,
                onDismiss: {}
            )
            .frame(width: 500)

            // Ocean-like wave (heavy inertia)
            WaveFlashMessageView(
                message: "Syncing data...",
                type: .success,
                cornerRadius: 12,
                waveConfiguration: .ocean,
                onDismiss: {}
            )
            .frame(width: 500)

            // Subtle smooth wave
            WaveFlashMessageView(
                message: "Almost there!",
                type: .success,
                cornerRadius: 8,
                waveConfiguration: .subtle,
                onDismiss: {}
            )
            .frame(width: 400)

            // Custom configuration demo
            WaveFlashMessageView(
                message: "Custom Waves",
                type: .info,
                cornerRadius: 10,
                waveConfiguration: WaveConfiguration(
                    amplitude: 10,
                    trough: 5,
                    speed: 1.2,
                    frequency: 3.0,
                    inertia: 1.0
                ),
                onDismiss: {}
            )
            .frame(width: 450)
        }
        .padding(40)
        .background(Color.gray.opacity(0.3))
    }
}
#endif
