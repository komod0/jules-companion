import Cocoa
import MetalKit
import QuartzCore

/// Phase 2: Optimized Metal View for Diff Rendering
/// Acts as the synchronization bridge between AppKit and Metal
///
/// Key optimizations:
/// - Custom CAMetalLayer with framebufferOnly for GPU optimization
/// - RenderMode switching between async (normal) and sync (resize) modes
/// - Immediate drawable size updates during resize
/// - Transaction-aware presentation for smooth animations
@MainActor
class DiffMetalView: NSView {

    // MARK: - Render Mode

    /// Render mode determines how frames are presented
    enum RenderMode {
        /// Async mode: Maximum throughput, no CPU waiting
        /// Used during normal operation and scrolling
        case async

        /// Sync mode: Synchronized with Core Animation transactions
        /// Used during resize for tear-free presentation
        case sync
    }

    // MARK: - Properties

    /// The Metal device
    let device: MTLDevice

    /// The Metal layer backing this view
    var metalLayer: CAMetalLayer {
        return layer as! CAMetalLayer
    }

    /// The renderer responsible for drawing
    var renderer: TripleBufferedRenderer?

    /// Weak reference to the view model for content
    weak var viewModel: FluxViewModel?

    /// Scroll callbacks
    var onScroll: ((Float) -> Void)?
    var onLayout: ((CGFloat) -> Void)?

    /// Current render mode
    private(set) var renderMode: RenderMode = .async {
        didSet {
            updateTransactionMode()
        }
    }

    /// Whether we're in a live resize operation
    private var isInLiveResize: Bool = false

    /// Whether sidebar animation is in progress
    private var isSidebarAnimating: Bool = false

    /// Scroll offsets
    private var _scrollOffsetX: CGFloat = 0
    private var _scrollOffsetY: CGFloat = 0

    /// Layout throttling
    private var lastLayoutHeight: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0
    private var pendingLayoutUpdate: DispatchWorkItem?
    private var lastLayoutTime: CFTimeInterval = 0
    private let layoutThrottleInterval: CFTimeInterval = 0.008 // ~120fps throttle

    /// Selection state
    private var isDragging = false
    private var dragStartPoint: CGPoint?

    // MARK: - Scroll Properties

    var scrollOffsetX: CGFloat {
        get { _scrollOffsetX }
        set {
            guard newValue != _scrollOffsetX else { return }
            _scrollOffsetX = newValue
            renderer?.setScroll(x: Float(_scrollOffsetX), y: Float(_scrollOffsetY))
            setNeedsDisplay(bounds)
        }
    }

    var scrollOffset: CGFloat {
        get { _scrollOffsetY }
        set {
            guard newValue != _scrollOffsetY else { return }
            _scrollOffsetY = newValue
            renderer?.setScroll(x: Float(_scrollOffsetX), y: Float(_scrollOffsetY))
            onScroll?(Float(newValue))
        }
    }

    // MARK: - Layer Configuration

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()

        // Core Metal configuration
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm

        // OPTIMIZATION: framebufferOnly allows GPU to optimize internal storage
        // Since we only render to this texture (never sample from it), the GPU
        // can use more efficient memory layouts
        metalLayer.framebufferOnly = true

        // Match display refresh rate for 120Hz ProMotion support
        metalLayer.displaySyncEnabled = true

        // Content scale for Retina
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Allow extended dynamic range if available
        if #available(macOS 10.15, *) {
            metalLayer.wantsExtendedDynamicRangeContent = false
        }

        return metalLayer
    }

    // MARK: - Initialization

    init(device: MTLDevice) {
        self.device = device
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        // Use shared Metal device to avoid context leaks (msgtracer error)
        guard let device = fluxSharedMetalDevice else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Ensure we use a layer
        wantsLayer = true

        // Configure layer properties
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .topLeft

        // Create the renderer
        renderer = TripleBufferedRenderer(device: device)

        // Configure initial clear color
        updateClearColor()

        // Set initial transaction mode
        updateTransactionMode()

        // Observe sidebar animation notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarAnimationWillStart),
            name: .sidebarAnimationWillStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarAnimationDidEnd),
            name: .sidebarAnimationDidEnd,
            object: nil
        )
    }

    // MARK: - Transaction Mode

    private func updateTransactionMode() {
        switch renderMode {
        case .sync:
            metalLayer.presentsWithTransaction = true
        case .async:
            metalLayer.presentsWithTransaction = false
        }
    }

    // MARK: - Sidebar Animation Handling

    @objc private func handleSidebarAnimationWillStart() {
        isSidebarAnimating = true
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil

        // Switch to sync mode during animation for tear-free presentation
        renderMode = .sync

        // Cache current content during animation
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @objc private func handleSidebarAnimationDidEnd() {
        isSidebarAnimating = false

        // Restore async mode for maximum throughput
        renderMode = .async

        // Restore normal redraw policy
        layerContentsRedrawPolicy = .duringViewResize

        // Handle any pending size changes
        let sizeChanged = bounds.height != lastLayoutHeight || bounds.width != lastLayoutWidth
        if sizeChanged {
            lastLayoutHeight = bounds.height
            lastLayoutWidth = bounds.width
            lastLayoutTime = CACurrentMediaTime()
            onLayout?(bounds.height)
        }

        // Force full redraw
        setNeedsDisplay(bounds)
    }

    // MARK: - Frame Size Handling (Phase 2 Critical)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // CRITICAL: Update drawable size IMMEDIATELY on frame change
        // This ensures the Metal layer matches the view size at all times
        let scale = metalLayer.contentsScale
        let drawableSize = CGSize(
            width: newSize.width * scale,
            height: newSize.height * scale
        )

        // Only update if size actually changed
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize

            // Trigger synchronous draw during resize for tear-free presentation
            if renderMode == .sync || isInLiveResize {
                draw()
            }
        }
    }

    // MARK: - Live Resize Handling

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isInLiveResize = true

        // Switch to sync mode for tear-free resize
        renderMode = .sync
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isInLiveResize = false

        // Cancel pending updates
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil

        // Final size update
        if bounds.height != lastLayoutHeight || bounds.width != lastLayoutWidth {
            lastLayoutHeight = bounds.height
            lastLayoutWidth = bounds.width
            onLayout?(bounds.height)
        }

        // Restore async mode after short delay to ensure final frame is rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.renderMode = .async
        }
    }

    // MARK: - Drawing

    /// Trigger a draw operation
    func draw() {
        guard let renderer = renderer else { return }

        // Get next drawable
        guard let drawable = metalLayer.nextDrawable() else { return }

        // Calculate viewport size in points
        let scale = metalLayer.contentsScale
        let viewportWidth = Float(metalLayer.drawableSize.width / scale)
        let viewportHeight = Float(metalLayer.drawableSize.height / scale)

        // Render the frame
        renderer.render(
            to: drawable,
            viewportSize: SIMD2<Float>(viewportWidth, viewportHeight),
            presentWithTransaction: renderMode == .sync
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        draw()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let newHeight = bounds.height
        let newWidth = bounds.width
        let sizeChanged = newHeight != lastLayoutHeight || newWidth != lastLayoutWidth
        guard sizeChanged else { return }

        // Skip during sidebar animation
        if isSidebarAnimating { return }

        let currentTime = CACurrentMediaTime()
        let timeSinceLastLayout = currentTime - lastLayoutTime
        let isRapidLayoutChange = timeSinceLastLayout < layoutThrottleInterval * 3

        if inLiveResize || isRapidLayoutChange {
            pendingLayoutUpdate?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastLayoutHeight = self.bounds.height
                self.lastLayoutWidth = self.bounds.width
                self.lastLayoutTime = CACurrentMediaTime()
                self.onLayout?(self.bounds.height)
            }
            pendingLayoutUpdate = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + layoutThrottleInterval, execute: workItem)
        } else {
            lastLayoutHeight = newHeight
            lastLayoutWidth = newWidth
            lastLayoutTime = currentTime
            onLayout?(newHeight)
        }
    }

    // MARK: - Appearance

    private func updateClearColor() {
        let bgColor = AppColors.diffEditorBackground
        if let c = bgColor.usingColorSpace(.sRGB) {
            renderer?.clearColor = MTLClearColor(
                red: Double(c.redComponent),
                green: Double(c.greenComponent),
                blue: Double(c.blueComponent),
                alpha: 1.0
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Set NSAppearance.current so NSColor dynamic providers resolve correctly.
        // Without this, colors like diffEditorBackground may resolve for the old appearance.
        NSAppearance.current = effectiveAppearance
        updateClearColor()
        // Use dedicated appearance change handler that also clears syntax color caches.
        // This ensures diff colors update when switching between light/dark mode.
        viewModel?.invalidateForAppearanceChange()
        // Trigger immediate re-render to update background colors.
        // Syntax colors will update when async parsing completes.
        setNeedsDisplay(bounds)
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        // Horizontal scrolling
        if abs(event.deltaX) > 0.1 {
            scrollOffsetX -= event.deltaX * 2.0
            scrollOffsetX = max(0, min(scrollOffsetX, max(0, 2000 - bounds.width)))
        }

        // Forward vertical scrolling to parent
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let vm = viewModel, let r = renderer else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        isDragging = false

        let monoAdvance: Float = r.fontAtlasManager.monoAdvance

        let flippedY = Float(bounds.height - point.y)
        let adjustedX = Float(point.x) + Float(scrollOffsetX)

        if let pos = vm.screenToTextPosition(
            screenX: adjustedX,
            screenY: flippedY,
            scrollY: Float(scrollOffset),
            monoAdvance: monoAdvance
        ) {
            vm.setSelection(start: pos, end: pos)
        } else {
            vm.clearSelection()
        }

        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let vm = viewModel, let r = renderer, let start = dragStartPoint else { return }

        isDragging = true
        let point = convert(event.locationInWindow, from: nil)

        let monoAdvance: Float = r.fontAtlasManager.monoAdvance

        let flippedStartY = Float(bounds.height - start.y)
        let flippedEndY = Float(bounds.height - point.y)

        let adjustedStartX = Float(start.x) + Float(scrollOffsetX)
        let adjustedEndX = Float(point.x) + Float(scrollOffsetX)

        if let startPos = vm.screenToTextPosition(
            screenX: adjustedStartX,
            screenY: flippedStartY,
            scrollY: Float(scrollOffset),
            monoAdvance: monoAdvance
        ),
        let endPos = vm.screenToTextPosition(
            screenX: adjustedEndX,
            screenY: flippedEndY,
            scrollY: Float(scrollOffset),
            monoAdvance: monoAdvance
        ) {
            vm.setSelection(start: startPos, end: endPos)
            setNeedsDisplay(bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 && !isDragging {
            guard let vm = viewModel else { return }

            let point = convert(event.locationInWindow, from: nil)
            let flippedY = Float(bounds.height - point.y)
            let adjustedY = flippedY + Float(scrollOffset)
            let visualLineIndex = Int(adjustedY / vm.lineHeight)

            vm.selectLine(at: visualLineIndex)
            setNeedsDisplay(bounds)
        }

        isDragging = false
        dragStartPoint = nil
    }

    // MARK: - Copy Support

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            copySelection()
        } else {
            super.keyDown(with: event)
        }
    }

    private func copySelection() {
        guard let vm = viewModel, let text = vm.getSelectedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        if viewModel?.selectionStart != nil && viewModel?.selectionEnd != nil {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copySelectionMenu), keyEquivalent: "c")
            copyItem.keyEquivalentModifierMask = .command
            menu.addItem(copyItem)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func copySelectionMenu() {
        copySelection()
    }

    // MARK: - Memory Management

    /// Explicitly release all resources held by this view.
    /// Call this when the view is being removed from the hierarchy to free memory immediately.
    func releaseResources() {
        // Release view model caches
        viewModel?.releaseMemory()
        viewModel = nil

        // Release renderer (TripleBufferedRenderer)
        renderer = nil

        // Clear callbacks to break any retain cycles
        onScroll = nil
        onLayout = nil

        // Cancel pending work
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
        onScroll = nil
        onLayout = nil
        // Setting viewModel to nil triggers FluxViewModel's deinit which cleans up caches
        viewModel = nil
        renderer = nil
    }
}
