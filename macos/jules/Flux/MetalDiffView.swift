import Cocoa
import MetalKit

@MainActor
class MetalDiffView: MTKView {
    var renderer: FluxRenderer?
    // FIXED: Make viewModel weak to avoid retain cycles
    weak var viewModel: FluxViewModel?
    var onScroll: ((Float) -> Void)?
    var onLayout: ((CGFloat) -> Void)?

    // Scroll handling
    private var _scrollOffsetX: CGFloat = 0
    private var _scrollOffsetY: CGFloat = 0

    // Live resize handling - throttle updates during resize for smooth animation
    private var lastLayoutHeight: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0
    private var pendingLayoutUpdate: DispatchWorkItem?
    private var lastLayoutTime: CFTimeInterval = 0
    private let layoutThrottleInterval: CFTimeInterval = 0.016 // ~60fps throttle

    // Sidebar animation handling - freeze layout updates during animation
    private var isSidebarAnimating: Bool = false

    var scrollOffsetX: CGFloat {
        get { _scrollOffsetX }
        set {
            guard newValue != _scrollOffsetX else { return }
            _scrollOffsetX = newValue
            renderer?.setScroll(x: Float(_scrollOffsetX), y: Float(_scrollOffsetY))
            self.setNeedsDisplay(self.bounds)
        }
    }

    var scrollOffset: CGFloat {
        get { _scrollOffsetY }
        set {
            // Only update if value actually changed (avoids redundant renders)
            guard newValue != _scrollOffsetY else { return }
            _scrollOffsetY = newValue
            renderer?.setScroll(x: Float(_scrollOffsetX), y: Float(_scrollOffsetY))
            // Notify VM of scroll change for virtualization
            // Note: handleScroll will call setNeedsDisplay after updating instances
            onScroll?(Float(newValue))
        }
    }

    // Selection state
    private var isDragging = false
    private var dragStartPoint: CGPoint?

    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        self.colorPixelFormat = .bgra8Unorm
        // Use adaptive background color based on appearance
        updateClearColor()
        self.renderer = FluxRenderer(device: device)
        self.delegate = renderer

        // Use manual drawing for efficiency (only on scroll/update)
        // or loop if we have animations. For a diff viewer, demand-driven is better.
        self.isPaused = true
        self.enableSetNeedsDisplay = true

        // Configure layer for smooth resize behavior
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layerContentsPlacement = .topLeft
        
        // Enable presentsWithTransaction for synchronized display during animations
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = true
        }

        // Observe sidebar animation to freeze layout updates
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

    @objc private func handleSidebarAnimationWillStart() {
        isSidebarAnimating = true
        // Cancel any pending layout updates to prevent stuttering
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
        // Use snapshot redraw policy during animation - prevents expensive redraws
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @objc private func handleSidebarAnimationDidEnd() {
        isSidebarAnimating = false
        // Restore normal redraw policy
        self.layerContentsRedrawPolicy = .duringViewResize

        // Check if size changed (width changes when sidebar opens/closes, height may also change)
        let sizeChanged = bounds.height != lastLayoutHeight || bounds.width != lastLayoutWidth

        // Update layout with final size if changed
        if sizeChanged {
            lastLayoutHeight = bounds.height
            lastLayoutWidth = bounds.width
            lastLayoutTime = CACurrentMediaTime()
            onLayout?(bounds.height)
        }

        // Always force a full redraw after sidebar animation to fix any blank areas
        // This is necessary because the Metal layer content was cached during animation
        self.setNeedsDisplay(self.bounds)
    }

    /// Update the clear color based on current appearance (light/dark mode)
    private func updateClearColor() {
        let bgColor = AppColors.diffEditorBackground
        if let c = bgColor.usingColorSpace(.sRGB) {
            self.clearColor = MTLClearColor(
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
        // Update clear color when appearance changes (light/dark mode toggle)
        updateClearColor()
        // Use dedicated appearance change handler that also clears syntax color caches.
        // This ensures diff colors update when switching between light/dark mode.
        viewModel?.invalidateForAppearanceChange()
        // Trigger immediate re-render to update background colors.
        // Syntax colors will update when async parsing completes.
        setNeedsDisplay(bounds)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Input Handling
    override var acceptsFirstResponder: Bool { true }

    // Prevent window dragging when clicking in the diff view - allow text selection instead
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        // Handle horizontal scrolling for wide content
        // deltaX is negative when swiping left (to reveal content on right)
        if abs(event.deltaX) > 0.1 {
            scrollOffsetX -= event.deltaX * 2.0 // Sensitivity (invert for natural scrolling)
            // Clamp: don't scroll left past origin
            if scrollOffsetX < 0 { scrollOffsetX = 0 }
            // Clamp: reasonable max scroll (content can be up to 2000px wide)
            let maxScrollX = max(0, 2000 - bounds.width)
            scrollOffsetX = min(scrollOffsetX, maxScrollX)
        }

        // Always forward to next responder so parent ScrollView handles vertical scrolling
        // with proper momentum/inertia. This view has fixed height, no internal scrolling needed.
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let vm = viewModel, let r = renderer else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        isDragging = false

        // Phase 4: Use cached monoAdvance for O(1) lookup
        let monoAdvance: Float = r.fontAtlasManager.monoAdvance

        // Flip Y coordinate: macOS has origin at bottom-left, but renderer uses top-left
        let flippedY = Float(bounds.height - point.y)

        // Adjust for horizontal scroll
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

        self.setNeedsDisplay(self.bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let vm = viewModel, let r = renderer, let start = dragStartPoint else { return }

        isDragging = true
        let point = convert(event.locationInWindow, from: nil)

        // Phase 4: Use cached monoAdvance for O(1) lookup
        let monoAdvance: Float = r.fontAtlasManager.monoAdvance

        // Flip Y coordinates: macOS has origin at bottom-left, but renderer uses top-left
        let flippedStartY = Float(bounds.height - start.y)
        let flippedEndY = Float(bounds.height - point.y)

        // Adjust for horizontal scroll
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
            self.setNeedsDisplay(self.bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Handle double-click to select entire line
        if event.clickCount == 2 && !isDragging {
            guard let vm = viewModel else { return }

            let point = convert(event.locationInWindow, from: nil)

            // Flip Y coordinate: macOS has origin at bottom-left, but renderer uses top-left
            let flippedY = Float(bounds.height - point.y)

            // Calculate visual line index
            let adjustedY = flippedY + Float(scrollOffset)
            let visualLineIndex = Int(adjustedY / vm.lineHeight)

            vm.selectLine(at: visualLineIndex)
            self.setNeedsDisplay(self.bounds)
        }

        isDragging = false
        dragStartPoint = nil
    }

    // Copy support
    override func keyDown(with event: NSEvent) {
        // Cmd+C to copy
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

    // Right-click menu
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

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Cancel any pending throttled update
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil

        // Immediately update viewport with final size after resize completes
        if bounds.height != lastLayoutHeight || bounds.width != lastLayoutWidth {
            lastLayoutHeight = bounds.height
            lastLayoutWidth = bounds.width
            onLayout?(bounds.height)
        }
    }

    override func layout() {
        super.layout()

        let newHeight = bounds.height
        let newWidth = bounds.width
        let sizeChanged = newHeight != lastLayoutHeight || newWidth != lastLayoutWidth
        guard sizeChanged else { return }

        // During sidebar animation, skip layout callbacks entirely - they'll be handled when animation ends
        if isSidebarAnimating {
            return
        }

        let currentTime = CACurrentMediaTime()
        let timeSinceLastLayout = currentTime - lastLayoutTime

        // Detect rapid layout changes (window resize, etc.)
        // If layouts are happening faster than our throttle interval, we're likely animating
        let isRapidLayoutChange = timeSinceLastLayout < layoutThrottleInterval * 3

        // During live resize (window drag) or rapid layout changes,
        // throttle updates to prevent choppy rendering
        if inLiveResize || isRapidLayoutChange {
            // Cancel any previously scheduled update
            pendingLayoutUpdate?.cancel()

            // Schedule a throttled update (debounce at ~60fps during resize/animation)
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
            // Not animating - update immediately for responsive feel
            lastLayoutHeight = newHeight
            lastLayoutWidth = newWidth
            lastLayoutTime = currentTime
            onLayout?(newHeight)
        }
    }
    
    // MARK: - Memory Management

    /// Explicitly release all resources held by this view.
    /// Call this when the view is being removed from the hierarchy to free memory immediately.
    func releaseResources() {
        // Release Metal resources
        renderer?.releaseBuffers()
        renderer = nil

        // Release view model caches
        viewModel?.releaseMemory()
        viewModel = nil

        // Clear callbacks to break any retain cycles
        onScroll = nil
        onLayout = nil

        // Cancel pending work
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
    }

    // FIXED: Add cleanup
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
