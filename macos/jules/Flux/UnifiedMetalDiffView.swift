import Cocoa
import MetalKit
import Combine

/// A single Metal view that renders all diff content for all files.
/// This replaces the multi-tile approach with one unified rendering surface.
@MainActor
class UnifiedMetalDiffView: MTKView {

    // MARK: - Properties

    /// The renderer that handles Metal drawing
    var renderer: FluxRenderer?

    /// View model managing all diff sections
    var viewModel: UnifiedDiffViewModel? {
        didSet {
            // Subscribe to view model changes (e.g., syntax highlighting completion)
            setupViewModelSubscription()
        }
    }

    /// Subscription to view model changes
    private var viewModelCancellable: AnyCancellable?

    /// Callback when scroll offset changes (for parent coordination)
    var onScrollChanged: ((CGPoint) -> Void)?

    /// Callback when layout changes (resize, etc.)
    var onLayoutChanged: ((CGSize) -> Void)?

    /// Callback when horizontal scroll changes (for scrollbar update)
    var onHorizontalScrollChanged: ((Int) -> Void)?

    /// Callback for vertical auto-scroll during text selection drag
    /// Parameter is the scroll delta (negative = scroll up, positive = scroll down)
    var onVerticalAutoScroll: ((CGFloat) -> Void)?

    // MARK: - Scroll State

    /// Current vertical scroll position (set by parent NSScrollView)
    private var currentScrollY: CGFloat = 0

    /// Note: Horizontal scroll is now per-section, managed by UnifiedDiffViewModel

    // MARK: - Selection State

    private var isDragging = false
    private var dragStartPoint: CGPoint?
    private var dragStartTextPosition: GlobalTextPosition?  // Content position at drag start
    private var dragStartSectionIndex: Int?  // Section index at drag start (stable during drag)

    // MARK: - Auto-scroll during drag

    private var autoScrollTimer: Timer?
    private var lastDragPoint: CGPoint?
    private let autoScrollEdgeInset: CGFloat = 50  // Distance from edge to trigger auto-scroll
    private let autoScrollSpeed: CGFloat = 25  // Pixels per timer tick (increased for faster scrolling)

    // MARK: - Selection throttling for performance

    private var lastSelectionUpdateTime: CFTimeInterval = 0
    private let minSelectionUpdateInterval: CFTimeInterval = 1.0 / 120.0  // 120 fps max

    // MARK: - Resize Handling

    private var lastLayoutSize: CGSize = .zero
    private var pendingLayoutUpdate: DispatchWorkItem?
    private var lastLayoutTime: CFTimeInterval = 0
    private let layoutThrottleInterval: CFTimeInterval = 0.016

    // MARK: - Sidebar Animation Handling

    private var isSidebarAnimating = false

    // MARK: - Render State

    /// Last viewport state that was rendered - used to detect if render is needed
    private var lastRenderedScrollY: CGFloat = -1
    private var lastRenderedViewportSize: CGSize = .zero

    // DEBUG: Frame counter for performance tracking
    private var debugFrameCount = 0
    private var debugLastLogTime: CFTimeInterval = 0

    // MARK: - Initialization

    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)

        self.colorPixelFormat = .bgra8Unorm
        updateClearColor()

        self.renderer = FluxRenderer(device: device)
        self.delegate = renderer

        // Manual drawing for efficiency
        self.isPaused = true
        self.enableSetNeedsDisplay = true

        // Configure layer for smooth resize
        self.layerContentsRedrawPolicy = .duringViewResize
        self.layerContentsPlacement = .topLeft

        // Synchronized presentation for smooth animations
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = true
        }

        // Observe sidebar animation
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

        // Note: We intentionally do NOT observe splitViewDividerDidResize here.
        // The parent UnifiedDiffDocumentView handles that notification and updates our frame,
        // which triggers our layout() method naturally. Having both observe the notification
        // was causing redundant re-renders.
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - ViewModel Subscription

    /// Subscribe to view model changes to auto-update when syntax highlighting completes
    private func setupViewModelSubscription() {
        viewModelCancellable?.cancel()
        viewModelCancellable = nil

        guard let viewModel = viewModel else { return }

        // NOTE: Removed .receive(on: DispatchQueue.main) to eliminate async delay.
        // Since UnifiedMetalDiffView is an NSView on the main thread and objectWillChange
        // is sent from @MainActor context, the sink executes synchronously for immediate updates.
        viewModelCancellable = viewModel.objectWillChange
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.renderUpdate()
            }

        // CRITICAL FIX: Set up callback for immediate GPU buffer clearing on session change.
        // When rapidly paginating (A→B→A), the normal objectWillChange-based rendering can
        // get coalesced, leaving stale content in GPU buffers. This callback forces an
        // immediate synchronous GPU clear before new content loads.
        viewModel.onSessionChangeRequiresGPUClear = { [weak self] in
            guard let self = self, let renderer = self.renderer else { return }
            // Force immediate GPU buffer update with empty content
            renderer.updateInstances([], boldInstances: [], rects: [])
            // Use display() instead of setNeedsDisplay() for immediate synchronous redraw.
            // setNeedsDisplay is asynchronous and the actual draw happens later in the run loop,
            // which can leave stale content visible during fast pagination.
            self.display()
        }
    }

    // MARK: - Appearance

    private func updateClearColor() {
        // Use main background color so spacing between diff files matches the app background
        let bgColor = NSColor(AppColors.background)
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
        updateClearColor()
        // Use dedicated appearance change handler that clears caches and triggers re-render.
        // The view model will send objectWillChange which triggers renderUpdate() via our
        // Combine subscription. This ensures proper instance regeneration before drawing.
        // Note: We don't call setNeedsDisplay() directly as that would bypass renderUpdate()
        // and render with stale GPU buffers.
        viewModel?.invalidateForAppearanceChange()
    }

    // MARK: - Content Updates

    /// Update the view with new diff content
    func updateContent(
        diffs: [(patch: String, language: String?, filename: String?)],
        sessionId: String
    ) {
        viewModel?.updateContent(diffs: diffs, sessionId: sessionId)
        setNeedsDisplay(bounds)
    }

    /// Called by parent when scroll position changes
    func updateScrollPosition(_ scrollY: CGFloat, viewportHeight: CGFloat) {
        currentScrollY = scrollY
        renderer?.setScroll(x: 0, y: Float(scrollY))  // X scroll is now per-section
        viewModel?.setViewport(top: scrollY, height: viewportHeight, width: bounds.width)
        setNeedsDisplay(bounds)
    }

    // MARK: - Rendering

    /// Trigger a render update
    /// This method is safe to call multiple times - it coalesces redundant calls
    /// and only performs GPU updates when data has actually changed.
    func renderUpdate() {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        // Skip rendering if bounds are invalid (view not yet laid out properly)
        // This prevents pixelated textures from being cached during rapid view creation
        guard bounds.width >= 1 && bounds.height >= 1 else { return }

        // DEBUG: Track render frequency
        debugFrameCount += 1
        let now = CACurrentMediaTime()
        if now - debugLastLogTime >= 1.0 {
            let sectionsCount = viewModel.sections.count
            let hasContent = sectionsCount > 0
            print("[UnifiedMetalDiffView] Renders/sec: \(debugFrameCount), sections: \(sectionsCount), hasContent: \(hasContent)")
            debugFrameCount = 0
            debugLastLogTime = now
        }

        // NOTE: Removed hasRenderedThisFrame short-circuit optimization.
        // The optimization was causing syntax highlighting updates to be skipped when
        // they completed in the same run loop as another render. The view model's internal
        // cache (needsFullRegen flag) already handles efficient re-rendering - when syntax
        // highlighting completes, it calls invalidateRenderCache() which ensures the next
        // generateInstances() call regenerates with the new colors.

        // Ensure monoAdvance is up-to-date for scroll calculations
        // This must happen before setViewport/generateInstances to ensure correct maxScrollX
        let monoAdvance = CGFloat(renderer.fontAtlasManager.monoAdvance)
        viewModel.updateMonoAdvance(monoAdvance)

        // Ensure viewport width is up-to-date before generating instances
        // This fixes an issue where diff sections may not fill the full width
        // if renderUpdate is called before updateScrollPosition
        if bounds.width > 0 {
            viewModel.setViewport(top: currentScrollY, height: bounds.height, width: bounds.width)
        }

        // Set NSAppearance.current so NSColor dynamic providers resolve correctly.
        // This is critical for background colors in generateInstances().
        NSAppearance.current = effectiveAppearance

        let result = viewModel.generateInstances(renderer: renderer)

        // Only update GPU buffers if instances actually changed (cache miss)
        // This prevents redundant GPU uploads when multiple renderUpdate calls
        // happen in the same frame with the same data
        let didUpdateGPUBuffers = !result.isCacheHit
        if didUpdateGPUBuffers {
            renderer.updateInstances(result.instances, boldInstances: result.boldInstances, rects: result.rects)
        }

        // Track viewport state for debugging/optimization
        lastRenderedScrollY = currentScrollY
        lastRenderedViewportSize = bounds.size

        // Skip Metal draw when there's no content - reduces GPU load when DiffLoader is showing
        // EXCEPT when GPU buffers were just cleared (transitioning to empty content) -
        // we need setNeedsDisplay to trigger a redraw that shows the cleared view
        guard viewModel.sections.count > 0 || didUpdateGPUBuffers else { return }

        setNeedsDisplay(bounds)
    }

    // MARK: - Sidebar Animation

    @objc private func handleSidebarAnimationWillStart() {
        isSidebarAnimating = true
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @objc private func handleSidebarAnimationDidEnd() {
        isSidebarAnimating = false
        self.layerContentsRedrawPolicy = .duringViewResize

        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            onLayoutChanged?(bounds.size)
        }

        viewModel?.invalidateRenderCache()
        setNeedsDisplay(bounds)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        guard bounds.size != lastLayoutSize else { return }

        if isSidebarAnimating { return }

        let currentTime = CACurrentMediaTime()
        let timeSinceLastLayout = currentTime - lastLayoutTime
        let isRapidLayoutChange = timeSinceLastLayout < layoutThrottleInterval * 3

        if inLiveResize || isRapidLayoutChange {
            pendingLayoutUpdate?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastLayoutSize = self.bounds.size
                self.lastLayoutTime = CACurrentMediaTime()
                self.onLayoutChanged?(self.bounds.size)
                self.viewModel?.invalidateRenderCache()
                self.renderUpdate()
            }
            pendingLayoutUpdate = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + layoutThrottleInterval, execute: workItem)
        } else {
            lastLayoutSize = bounds.size
            lastLayoutTime = currentTime
            onLayoutChanged?(bounds.size)
            viewModel?.invalidateRenderCache()
            renderUpdate()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil

        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            onLayoutChanged?(bounds.size)
            viewModel?.invalidateRenderCache()
            renderUpdate()
        }
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        // Handle horizontal scrolling for wide content - per section
        if abs(event.deltaX) > 0.1, let viewModel = viewModel {
            let point = convert(event.locationInWindow, from: nil)
            // Convert to document coordinates
            let flippedY = bounds.height - point.y
            let documentY = currentScrollY + flippedY

            // Find which section the mouse is over
            if let sectionIndex = viewModel.sectionIndex(atY: documentY) {
                viewModel.adjustScrollOffsetX(delta: event.deltaX * 2.0, forSection: sectionIndex)
                renderUpdate()

                // Notify parent to update scrollbar
                onHorizontalScrollChanged?(sectionIndex)
            }
        }

        // Forward vertical scrolling to parent NSScrollView
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        isDragging = false

        let monoAdvance = renderer.fontAtlasManager.monoAdvance

        // Flip Y: macOS origin is bottom-left, we use top-left
        let flippedY = Float(bounds.height - point.y)

        // Get per-section scroll offset for click position calculation
        let documentY = currentScrollY + CGFloat(bounds.height - point.y)
        let sectionScrollX: Float
        if let sectionIndex = viewModel.sectionIndex(atY: documentY) {
            sectionScrollX = Float(viewModel.scrollOffsetX(forSection: sectionIndex))
            dragStartSectionIndex = sectionIndex  // Store section for stable horizontal scroll during drag
        } else {
            sectionScrollX = 0
            dragStartSectionIndex = nil
        }

        let adjustedX = Float(point.x) + sectionScrollX

        if let pos = viewModel.screenToTextPosition(
            screenX: adjustedX,
            screenY: flippedY,
            scrollY: Float(currentScrollY),
            monoAdvance: monoAdvance
        ) {
            dragStartTextPosition = pos  // Store content position for drag
            viewModel.setSelection(start: pos, end: pos)
        } else {
            dragStartTextPosition = nil
            viewModel.clearSelection()
        }

        renderUpdate()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer, dragStartPoint != nil else { return }

        isDragging = true
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point

        // Start auto-scroll timer if not already running
        if autoScrollTimer == nil {
            startAutoScrollTimer()
        }

        updateSelectionDuringDrag(point: point, viewModel: viewModel, renderer: renderer)
    }

    /// Update selection during drag - used by both mouseDragged and auto-scroll timer
    /// Throttled for performance - limits update frequency to minSelectionUpdateInterval
    private func updateSelectionDuringDrag(point: CGPoint, viewModel: UnifiedDiffViewModel, renderer: FluxRenderer, forceUpdate: Bool = false) {
        // Use the stored start position from mouseDown (doesn't drift with scroll)
        guard let startPos = dragStartTextPosition else { return }

        // Throttle selection updates for performance
        let currentTime = CACurrentMediaTime()
        if !forceUpdate && currentTime - lastSelectionUpdateTime < minSelectionUpdateInterval {
            return
        }
        lastSelectionUpdateTime = currentTime

        let monoAdvance = renderer.fontAtlasManager.monoAdvance
        let flippedEndY = Float(bounds.height - point.y)

        // Get per-section scroll offset for end position
        let endDocumentY = currentScrollY + CGFloat(bounds.height - point.y)
        let endSectionScrollX: Float
        if let sectionIndex = viewModel.sectionIndex(atY: endDocumentY) {
            endSectionScrollX = Float(viewModel.scrollOffsetX(forSection: sectionIndex))
        } else {
            endSectionScrollX = 0
        }

        let adjustedEndX = Float(point.x) + endSectionScrollX

        if let endPos = viewModel.screenToTextPosition(
            screenX: adjustedEndX,
            screenY: flippedEndY,
            scrollY: Float(currentScrollY),
            monoAdvance: monoAdvance
        ) {
            viewModel.setSelection(start: startPos, end: endPos)
            renderUpdate()
        }
    }

    // MARK: - Auto-scroll Timer

    private func startAutoScrollTimer() {
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleAutoScroll()
            }
        }
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        lastDragPoint = nil
    }

    private func handleAutoScroll() {
        guard isDragging,
              let point = lastDragPoint,
              let viewModel = viewModel,
              let renderer = renderer else { return }

        // Calculate distance from edges (horizontal)
        let leftDistance = point.x
        let rightDistance = bounds.width - point.x

        // Calculate distance from edges (vertical - note: macOS Y is bottom-up in view coords)
        let bottomDistance = point.y  // Distance from bottom edge
        let topDistance = bounds.height - point.y  // Distance from top edge

        var didScroll = false

        // Horizontal scroll (per-section)
        // Works like standard text editors: scrolls when mouse is near edge or outside bounds
        var horizontalDelta: CGFloat = 0

        if leftDistance < 0 {
            // Mouse is outside left edge - scroll left at max speed
            horizontalDelta = autoScrollSpeed
        } else if leftDistance < autoScrollEdgeInset {
            // Near left edge - scroll left with intensity based on distance
            let intensity = 1.0 - (leftDistance / autoScrollEdgeInset)
            horizontalDelta = autoScrollSpeed * intensity
        } else if rightDistance < 0 {
            // Mouse is outside right edge - scroll right at max speed
            horizontalDelta = -autoScrollSpeed
        } else if rightDistance < autoScrollEdgeInset {
            // Near right edge - scroll right with intensity based on distance
            let intensity = 1.0 - (rightDistance / autoScrollEdgeInset)
            horizontalDelta = -autoScrollSpeed * intensity
        }

        if abs(horizontalDelta) > 0.1 {
            // Find the section to scroll - prefer stored section from drag start
            // This ensures horizontal scroll continues when mouse goes outside the view
            let sectionToScroll: Int?
            if let storedSection = dragStartSectionIndex {
                sectionToScroll = storedSection
            } else {
                // Fallback: try to find section from clamped mouse position
                let clampedY = max(0, min(bounds.height, point.y))
                let documentY = currentScrollY + CGFloat(bounds.height - clampedY)
                sectionToScroll = viewModel.sectionIndex(atY: documentY)
            }

            if let sectionIndex = sectionToScroll {
                viewModel.adjustScrollOffsetX(delta: horizontalDelta, forSection: sectionIndex)
                didScroll = true

                // Notify parent to update scrollbar
                onHorizontalScrollChanged?(sectionIndex)
            }
        }

        // Vertical scroll (parent NSScrollView)
        // Works like standard text editors: scrolls when mouse is near edge or outside bounds
        var verticalDelta: CGFloat = 0

        if topDistance < 0 {
            // Mouse is above the view - scroll up at max speed
            verticalDelta = -autoScrollSpeed
        } else if topDistance < autoScrollEdgeInset {
            // Near top edge - scroll up with intensity based on distance
            let intensity = 1.0 - (topDistance / autoScrollEdgeInset)
            verticalDelta = -autoScrollSpeed * intensity
        } else if bottomDistance < 0 {
            // Mouse is below the view - scroll down at max speed
            verticalDelta = autoScrollSpeed
        } else if bottomDistance < autoScrollEdgeInset {
            // Near bottom edge - scroll down with intensity based on distance
            let intensity = 1.0 - (bottomDistance / autoScrollEdgeInset)
            verticalDelta = autoScrollSpeed * intensity
        }

        if abs(verticalDelta) > 0.1 {
            onVerticalAutoScroll?(verticalDelta)
            didScroll = true
        }

        // If scrolling occurred, ensure we render the updated scroll position
        // This is critical because updateSelectionDuringDrag may not call renderUpdate
        // if the mouse position can't be converted to a text position (e.g., in gutter area)
        if didScroll {
            // Always render when scrolling - this ensures the view updates even when
            // the mouse is in an area where text selection isn't possible (like the gutter)
            renderUpdate()

            // Also try to update selection if possible
            updateSelectionDuringDrag(point: point, viewModel: viewModel, renderer: renderer, forceUpdate: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Stop auto-scroll timer
        stopAutoScrollTimer()

        // Handle double-click to select entire line
        if event.clickCount == 2 && !isDragging {
            guard let viewModel = viewModel, let renderer = renderer else { return }

            let point = convert(event.locationInWindow, from: nil)
            let flippedY = Float(bounds.height - point.y)
            let adjustedY = flippedY + Float(currentScrollY)

            // Find global line index
            let lineHeight = Float(viewModel.lineHeight)
            for (idx, globalLine) in viewModel.globalLines.enumerated() {
                let lineY = Float(globalLine.yOffset)
                if adjustedY >= lineY && adjustedY < lineY + lineHeight {
                    viewModel.selectLine(at: idx)
                    renderUpdate()
                    break
                }
            }
        }

        isDragging = false
        dragStartPoint = nil
        dragStartTextPosition = nil
        dragStartSectionIndex = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd+C to copy
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            copySelection()
        } else {
            super.keyDown(with: event)
        }
    }

    private func copySelection() {
        guard let text = viewModel?.getSelectedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Right-Click Menu

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

    func releaseResources() {
        stopAutoScrollTimer()
        viewModelCancellable?.cancel()
        viewModelCancellable = nil
        renderer?.releaseBuffers()
        renderer = nil
        viewModel?.onSessionChangeRequiresGPUClear = nil
        viewModel?.releaseMemory()
        viewModel = nil
        onScrollChanged = nil
        onLayoutChanged = nil
        onHorizontalScrollChanged = nil
        onVerticalAutoScroll = nil
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
    }

    deinit {
        autoScrollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        viewModelCancellable?.cancel()
        viewModelCancellable = nil
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
        onScrollChanged = nil
        onLayoutChanged = nil
        viewModel = nil
        renderer = nil
    }
}
