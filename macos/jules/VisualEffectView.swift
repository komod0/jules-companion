import SwiftUI
import AppKit

// MARK: - NSGlassEffectView Compatibility Shim

/// Compatibility shim for NSGlassEffectView which is introduced in macOS 26.
/// This allows the code to compile on earlier SDK versions while being ready for macOS 26.
/// When building with macOS 26 SDK, this will be replaced by the real NSGlassEffectView.
#if swift(>=5.9)
@available(macOS 26.0, *)
public class NSGlassEffectView: NSView {
    /// The corner radius of the glass effect view.
    /// On macOS 26+, this is a native property. On earlier versions, we use layer masking.
    public var cornerRadius: CGFloat = 0 {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
        }
    }

    /// The material style for the glass effect.
    /// Maps to NSVisualEffectView.Material values.
    public var material: NSVisualEffectView.Material = .sidebar {
        didSet {
            updateBackingView()
        }
    }

    /// Whether the glass effect view is interactive (responds to mouse events).
    public var isInteractive: Bool = true

    /// The backing visual effect view (used until real NSGlassEffectView is available)
    private var backingView: NSVisualEffectView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBackingView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBackingView()
    }

    private func setupBackingView() {
        let effectView = NSVisualEffectView(frame: bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.material = material
        effectView.wantsLayer = true
        addSubview(effectView)
        backingView = effectView
    }

    private func updateBackingView() {
        backingView?.material = material
    }

    public override func layout() {
        super.layout()
        backingView?.frame = bounds
        backingView?.layer?.cornerRadius = cornerRadius
        backingView?.layer?.masksToBounds = true
    }
}
#endif

// MARK: - Glass Effect Type

/// Categorizes the UI component type for appropriate glass effect styling.
/// On macOS 26+, NSGlassEffectView handles these differently than NSVisualEffectView.
public enum GlassEffectType {
    /// Sidebars - macOS 26 uses edge-to-edge glass by default
    case sidebar

    /// Toolbars - NSGlassEffectView handles floating toolbar style automatically
    case toolbar

    /// Floating panels - Better "Liquid" look where background morphs based on content
    case floatingPanel

    /// Custom rectangular areas with rounded corners
    case customRect

    /// Header areas
    case header

    /// Under window background - general content areas
    case underWindow
}

// MARK: - Legacy Visual Effect View (macOS < 26)

/// NSViewRepresentable wrapper for NSVisualEffectView.
/// Used on macOS versions prior to 26.0.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.state = state
        view.material = material
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.masksToBounds = true
    }
}

// MARK: - Glass Effect View (macOS 26+)

/// NSViewRepresentable wrapper for NSGlassEffectView.
/// Available on macOS 26.0 and later.
@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
    var effectType: GlassEffectType = .underWindow
    var cornerRadius: CGFloat = 0
    var isInteractive: Bool = true

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        configureView(view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        configureView(nsView)
    }

    private func configureView(_ view: NSGlassEffectView) {
        // Configure corner radius using native property (no layer masking needed)
        view.cornerRadius = cornerRadius

        // Configure material/style based on effect type
        switch effectType {
        case .sidebar:
            // Sidebars use edge-to-edge glass material
            view.material = .sidebar

        case .toolbar:
            // Toolbars use the floating toolbar style
            view.material = .titlebar

        case .floatingPanel:
            // Floating panels use the "Liquid" HUD style
            view.material = .hudWindow

        case .customRect:
            // Custom rectangles use the content background
            view.material = .contentBackground

        case .header:
            // Headers use the header view material
            view.material = .headerView

        case .underWindow:
            // General content areas use under-window background
            view.material = .underWindowBackground
        }

        // Set interactivity for proper event handling
        view.isInteractive = isInteractive
    }
}

// MARK: - Adaptive Effect View

/// A view that automatically selects the appropriate backing effect view
/// based on the current macOS version.
/// - On macOS 26+: Uses NSGlassEffectView for modern "Liquid Glass" effects
/// - On earlier versions: Falls back to NSVisualEffectView
struct AdaptiveEffectView: View {
    var effectType: GlassEffectType
    var cornerRadius: CGFloat = 0
    var isInteractive: Bool = true

    /// Legacy material for macOS < 26 fallback
    private var legacyMaterial: NSVisualEffectView.Material {
        switch effectType {
        case .sidebar:
            return .sidebar
        case .toolbar:
            return .titlebar
        case .floatingPanel:
            return .hudWindow
        case .customRect:
            return .contentBackground
        case .header:
            return .headerView
        case .underWindow:
            return .underWindowBackground
        }
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectView(
                effectType: effectType,
                cornerRadius: cornerRadius,
                isInteractive: isInteractive
            )
        } else {
            VisualEffectView(
                material: legacyMaterial,
                blendingMode: .behindWindow,
                state: .active,
                cornerRadius: cornerRadius
            )
        }
    }
}

// MARK: - Unified Background

/// A unified background view that combines the appropriate effect view with an overlay tint.
/// Use this for consistent styling across MenuView, Sidebar, and Toolbar.
/// - On macOS 26+: Uses NSGlassEffectView (tint overlay is typically not needed)
/// - On earlier versions: Uses NSVisualEffectView with optional tint overlay
struct UnifiedBackground: View {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var tintOverlayColor: Color = AppColors.background
    var tintOverlayOpacity: Double = 0.8
    var effectType: GlassEffectType? = nil
    var cornerRadius: CGFloat = 0

    var body: some View {
        if #available(macOS 26.0, *) {
            // On macOS 26+, use NSGlassEffectView without tint overlay
            // The glass effect provides the proper visual treatment automatically
            GlassEffectView(
                effectType: resolvedEffectType,
                cornerRadius: cornerRadius,
                isInteractive: true
            )
            .ignoresSafeArea()
        } else {
            // On earlier macOS versions, use NSVisualEffectView with tint overlay
            ZStack {
                VisualEffectView(material: material, blendingMode: blendingMode, cornerRadius: cornerRadius)
                    .ignoresSafeArea()

                tintOverlayColor
                    .opacity(tintOverlayOpacity)
                    .blendMode(.overlay)
                    .ignoresSafeArea()
            }
        }
    }

    /// Resolves the effect type from explicit setting or infers from material
    private var resolvedEffectType: GlassEffectType {
        if let explicit = effectType {
            return explicit
        }
        // Infer from legacy material
        switch material {
        case .sidebar:
            return .sidebar
        case .titlebar:
            return .toolbar
        case .hudWindow:
            return .floatingPanel
        case .contentBackground:
            return .customRect
        case .headerView:
            return .header
        case .underWindowBackground:
            return .underWindow
        default:
            return .underWindow
        }
    }
}

/// A view modifier that applies the unified background styling.
struct UnifiedBackgroundModifier: ViewModifier {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var tintOverlayColor: Color = AppColors.background
    var tintOverlayOpacity: Double = 0.8
    var effectType: GlassEffectType? = nil
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                UnifiedBackground(
                    material: material,
                    blendingMode: blendingMode,
                    tintOverlayColor: tintOverlayColor,
                    tintOverlayOpacity: tintOverlayOpacity,
                    effectType: effectType,
                    cornerRadius: cornerRadius
                )
            }
    }
}

// MARK: - Adaptive Effect View Modifier

/// A view modifier that applies adaptive glass effects based on component type.
struct AdaptiveEffectModifier: ViewModifier {
    var effectType: GlassEffectType
    var cornerRadius: CGFloat = 0
    var tintOverlayColor: Color = AppColors.background
    var tintOverlayOpacity: Double = 0.5

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectView(
                        material: legacyMaterial,
                        blendingMode: .behindWindow,
                        cornerRadius: cornerRadius
                    )
                    tintOverlayColor
                        .opacity(tintOverlayOpacity)
                        .blendMode(.overlay)
                }
                
            }
    }

    private var legacyMaterial: NSVisualEffectView.Material {
        switch effectType {
        case .sidebar:
            return .sidebar
        case .toolbar:
            return .titlebar
        case .floatingPanel:
            return .hudWindow
        case .customRect:
            return .contentBackground
        case .header:
            return .headerView
        case .underWindow:
            return .underWindowBackground
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies the unified background styling used across MenuView, Sidebar, and Toolbar.
    /// Automatically uses NSGlassEffectView on macOS 26+ and NSVisualEffectView on earlier versions.
    func unifiedBackground(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.5,
        effectType: GlassEffectType? = nil,
        cornerRadius: CGFloat = 0
    ) -> some View {
        modifier(UnifiedBackgroundModifier(
            material: material,
            blendingMode: blendingMode,
            tintOverlayColor: tintOverlayColor,
            tintOverlayOpacity: tintOverlayOpacity,
            effectType: effectType,
            cornerRadius: cornerRadius
        ))
    }

    /// Applies an adaptive glass effect background based on the UI component type.
    /// - On macOS 26+: Uses NSGlassEffectView for modern effects
    /// - On earlier versions: Uses NSVisualEffectView with appropriate material
    func adaptiveGlassEffect(
        _ effectType: GlassEffectType,
        cornerRadius: CGFloat = 0,
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.5
    ) -> some View {
        modifier(AdaptiveEffectModifier(
            effectType: effectType,
            cornerRadius: cornerRadius,
            tintOverlayColor: tintOverlayColor,
            tintOverlayOpacity: tintOverlayOpacity
        ))
    }

    /// Applies a sidebar glass effect.
    /// On macOS 26+, sidebars use edge-to-edge glass automatically.
    func sidebarGlassEffect(
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.5
    ) -> some View {
        adaptiveGlassEffect(.sidebar, tintOverlayColor: tintOverlayColor, tintOverlayOpacity: tintOverlayOpacity)
    }

    /// Applies a toolbar glass effect.
    /// On macOS 26+, uses the floating toolbar style automatically.
    func toolbarGlassEffect(
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.3
    ) -> some View {
        adaptiveGlassEffect(.toolbar, tintOverlayColor: tintOverlayColor, tintOverlayOpacity: tintOverlayOpacity)
    }

    /// Applies a floating panel glass effect.
    /// On macOS 26+, provides the "Liquid" look where background morphs based on content.
    func floatingPanelGlassEffect(
        cornerRadius: CGFloat = 12,
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.5
    ) -> some View {
        adaptiveGlassEffect(.floatingPanel, cornerRadius: cornerRadius, tintOverlayColor: tintOverlayColor, tintOverlayOpacity: tintOverlayOpacity)
    }

    /// Applies a custom rect glass effect with rounded corners.
    /// On macOS 26+, uses native cornerRadius property (no layer masking needed).
    func customRectGlassEffect(
        cornerRadius: CGFloat = 8,
        tintOverlayColor: Color = AppColors.background,
        tintOverlayOpacity: Double = 0.5
    ) -> some View {
        adaptiveGlassEffect(.customRect, cornerRadius: cornerRadius, tintOverlayColor: tintOverlayColor, tintOverlayOpacity: tintOverlayOpacity)
    }
}

// MARK: - AppKit Helpers

/// Creates an appropriate NSView for glass effects based on macOS version.
/// Use this when you need to create effect views directly in AppKit code.
@MainActor
func createAdaptiveEffectView(
    effectType: GlassEffectType,
    cornerRadius: CGFloat = 0
) -> NSView {
    if #available(macOS 26.0, *) {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius

        switch effectType {
        case .sidebar:
            view.material = .sidebar
        case .toolbar:
            view.material = .titlebar
        case .floatingPanel:
            view.material = .hudWindow
        case .customRect:
            view.material = .contentBackground
        case .header:
            view.material = .headerView
        case .underWindow:
            view.material = .underWindowBackground
        }

        return view
    } else {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true

        switch effectType {
        case .sidebar:
            view.material = .sidebar
        case .toolbar:
            view.material = .titlebar
        case .floatingPanel:
            view.material = .hudWindow
        case .customRect:
            view.material = .contentBackground
        case .header:
            view.material = .headerView
        case .underWindow:
            view.material = .underWindowBackground
        }

        return view
    }
}

/// Configures an existing window's content view with appropriate glass effects.
/// Call this during window setup to apply the correct effect for macOS version.
@MainActor
func configureWindowWithGlassEffect(
    window: NSWindow,
    effectType: GlassEffectType = .underWindow,
    cornerRadius: CGFloat = 0
) {
    if #available(macOS 26.0, *) {
        // On macOS 26+, configure window for glass effects
        // The system handles most of the glass styling automatically
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true

        // For floating panels, use appropriate window level
        if effectType == .floatingPanel {
            window.level = .floating
            window.isMovableByWindowBackground = true
        }
    } else {
        // On earlier versions, apply NSVisualEffectView to content view
        let effectView = createAdaptiveEffectView(
            effectType: effectType,
            cornerRadius: cornerRadius
        ) as! NSVisualEffectView

        // Store original content and wrap it
        if let originalContent = window.contentView {
            effectView.frame = originalContent.bounds
            effectView.autoresizingMask = [.width, .height]

            originalContent.removeFromSuperview()
            effectView.addSubview(originalContent)
            originalContent.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                originalContent.topAnchor.constraint(equalTo: effectView.topAnchor),
                originalContent.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                originalContent.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                originalContent.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
            ])

            window.contentView = effectView
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
    }
}
