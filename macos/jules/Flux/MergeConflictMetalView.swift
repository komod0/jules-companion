//
//  MergeConflictMetalView.swift
//  jules
//
//  Metal-based view for rendering merge conflict content.
//  Based on UnifiedMetalDiffView but adapted for merge conflict display.
//

import Cocoa
import MetalKit
import Combine

/// A Metal view that renders merge conflict content with syntax highlighting.
@MainActor
class MergeConflictMetalView: MTKView {

    // MARK: - Properties

    /// The renderer that handles Metal drawing
    var renderer: FluxRenderer?

    /// View model managing conflict content and layout
    var viewModel: MergeConflictViewModel? {
        didSet {
            setupViewModelSubscription()
        }
    }

    /// Subscription to view model changes
    private var viewModelCancellable: AnyCancellable?

    /// Callback when layout changes (for parent scroll view coordination)
    var onLayoutChanged: ((CGSize) -> Void)?

    /// Callback for vertical auto-scroll during drag
    var onVerticalAutoScroll: ((CGFloat) -> Void)?

    /// Callback when horizontal scroll changes
    var onHorizontalScrollChanged: (() -> Void)?

    // MARK: - Scroll State

    /// Current vertical scroll position (set by parent NSScrollView)
    private var currentScrollY: CGFloat = 0

    // MARK: - Selection State

    private var isDragging = false
    private var dragStartPoint: CGPoint?
    private var dragStartTextPosition: ConflictTextPosition?

    // MARK: - Auto-scroll during drag

    private var autoScrollTimer: Timer?
    private var lastDragPoint: CGPoint?
    private let autoScrollEdgeInset: CGFloat = 50
    private let autoScrollSpeed: CGFloat = 25

    // MARK: - Selection throttling

    private var lastSelectionUpdateTime: CFTimeInterval = 0
    private let minSelectionUpdateInterval: CFTimeInterval = 1.0 / 120.0

    // MARK: - Resize Handling

    private var lastLayoutSize: CGSize = .zero
    private var pendingLayoutUpdate: DispatchWorkItem?
    private var lastLayoutTime: CFTimeInterval = 0
    private let layoutThrottleInterval: CFTimeInterval = 0.016

    // MARK: - Render Coalescing

    private var hasRenderedThisFrame = false
    private var lastRenderedScrollY: CGFloat = -1
    private var lastRenderedViewportSize: CGSize = .zero

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

        // Configure layer for redraw on scroll
        // Use .onSetNeedsDisplay so that setNeedsDisplay(bounds) calls during scrolling
        // actually trigger redraws. Using .duringViewResize would cause content to
        // disappear during scroll since redraws would only happen on resize events.
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layerContentsPlacement = .topLeft

        // Synchronized presentation for smooth animations
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = true
            // Critical: Layer must redraw when bounds change during scroll
            // Without this, scrolling causes content to disappear in areas
            // that were previously outside the visible viewport
            metalLayer.needsDisplayOnBoundsChange = true
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - ViewModel Subscription

    private func setupViewModelSubscription() {
        viewModelCancellable?.cancel()
        viewModelCancellable = nil

        guard let viewModel = viewModel else { return }

        viewModelCancellable = viewModel.objectWillChange
            .sink { [weak self] _ in
                // Defer renderUpdate to next run loop iteration to avoid
                // "Publishing changes from within view updates" warning.
                // The objectWillChange publisher fires synchronously, and if SwiftUI
                // is in the middle of a view update cycle, calling renderUpdate()
                // synchronously could trigger nested state changes.
                DispatchQueue.main.async { [weak self] in
                    self?.renderUpdate()
                }
            }
    }

    // MARK: - Appearance

    private func updateClearColor() {
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

    /// Update the view with new text content
    func updateContent(_ text: String) {
        viewModel?.updateContent(text)
        setNeedsDisplay(bounds)
    }

    /// Called by parent when scroll position changes
    func updateScrollPosition(_ scrollY: CGFloat, viewportHeight: CGFloat) {
        currentScrollY = scrollY
        // CRITICAL: Apply scroll offset to renderer for viewport-based tiling.
        // The Metal view is now viewport-sized and positioned at scrollY in document coords.
        // The renderer must offset rendering by scrollY so content appears at correct position.
        renderer?.setScroll(x: 0, y: Float(scrollY))
        viewModel?.setViewport(top: scrollY, height: viewportHeight, width: bounds.width)
        // CRITICAL: Regenerate instances for the new visible range.
        // Without this, only instances from the initial viewport would exist in the GPU buffer,
        // causing content past the initial viewport to be invisible ("hidden second tile").
        renderUpdate()
    }

    // MARK: - Rendering

    /// Trigger a render update
    func renderUpdate() {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        // Skip rendering if bounds are invalid
        guard bounds.width >= 1 && bounds.height >= 1 else { return }

        // Coalesce multiple renderUpdate calls within same frame
        if hasRenderedThisFrame {
            setNeedsDisplay(bounds)
            return
        }

        // Ensure monoAdvance is up-to-date
        let monoAdvance = CGFloat(renderer.fontAtlasManager.monoAdvance)
        viewModel.updateMonoAdvance(monoAdvance)

        // Ensure viewport is up-to-date
        if bounds.width > 0 {
            viewModel.setViewport(top: currentScrollY, height: bounds.height, width: bounds.width)
        }

        // Set NSAppearance.current so NSColor dynamic providers resolve correctly.
        // This is critical for background colors in generateInstances().
        NSAppearance.current = effectiveAppearance

        let result = viewModel.generateInstances(renderer: renderer)

        // Only update GPU buffers if instances changed
        if !result.isCacheHit {
            renderer.updateInstances(result.instances, rects: result.rects)

            hasRenderedThisFrame = true
            DispatchQueue.main.async { [weak self] in
                self?.hasRenderedThisFrame = false
            }
        }

        lastRenderedScrollY = currentScrollY
        lastRenderedViewportSize = bounds.size

        // Skip Metal draw when no content
        guard !viewModel.lines.isEmpty else { return }

        setNeedsDisplay(bounds)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        guard bounds.size != lastLayoutSize else { return }

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
        // Handle horizontal scrolling
        if abs(event.deltaX) > 0.1, let viewModel = viewModel {
            viewModel.adjustScrollOffsetX(delta: event.deltaX * 2.0)
            renderUpdate()
            onHorizontalScrollChanged?()
        }

        // Forward vertical scrolling to parent
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        isDragging = false

        let monoAdvance = renderer.fontAtlasManager.monoAdvance
        let flippedY = Float(bounds.height - point.y)
        let scrollX = Float(viewModel.getScrollOffsetX())
        let adjustedX = Float(point.x) + scrollX

        if let pos = viewModel.screenToTextPosition(
            screenX: adjustedX,
            screenY: flippedY,
            scrollY: Float(currentScrollY),
            monoAdvance: monoAdvance
        ) {
            dragStartTextPosition = pos
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

        if autoScrollTimer == nil {
            startAutoScrollTimer()
        }

        updateSelectionDuringDrag(point: point, viewModel: viewModel, renderer: renderer)
    }

    private func updateSelectionDuringDrag(point: CGPoint, viewModel: MergeConflictViewModel, renderer: FluxRenderer, forceUpdate: Bool = false) {
        guard let startPos = dragStartTextPosition else { return }

        let currentTime = CACurrentMediaTime()
        if !forceUpdate && currentTime - lastSelectionUpdateTime < minSelectionUpdateInterval {
            return
        }
        lastSelectionUpdateTime = currentTime

        let monoAdvance = renderer.fontAtlasManager.monoAdvance
        let flippedEndY = Float(bounds.height - point.y)
        let scrollX = Float(viewModel.getScrollOffsetX())
        let adjustedEndX = Float(point.x) + scrollX

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

        let leftDistance = point.x
        let rightDistance = bounds.width - point.x
        let bottomDistance = point.y
        let topDistance = bounds.height - point.y

        var didScroll = false

        // Horizontal scroll
        var horizontalDelta: CGFloat = 0
        if leftDistance < 0 {
            horizontalDelta = autoScrollSpeed
        } else if leftDistance < autoScrollEdgeInset {
            let intensity = 1.0 - (leftDistance / autoScrollEdgeInset)
            horizontalDelta = autoScrollSpeed * intensity
        } else if rightDistance < 0 {
            horizontalDelta = -autoScrollSpeed
        } else if rightDistance < autoScrollEdgeInset {
            let intensity = 1.0 - (rightDistance / autoScrollEdgeInset)
            horizontalDelta = -autoScrollSpeed * intensity
        }

        if abs(horizontalDelta) > 0.1 {
            viewModel.adjustScrollOffsetX(delta: horizontalDelta)
            didScroll = true
            onHorizontalScrollChanged?()
        }

        // Vertical scroll
        var verticalDelta: CGFloat = 0
        if topDistance < 0 {
            verticalDelta = -autoScrollSpeed
        } else if topDistance < autoScrollEdgeInset {
            let intensity = 1.0 - (topDistance / autoScrollEdgeInset)
            verticalDelta = -autoScrollSpeed * intensity
        } else if bottomDistance < 0 {
            verticalDelta = autoScrollSpeed
        } else if bottomDistance < autoScrollEdgeInset {
            let intensity = 1.0 - (bottomDistance / autoScrollEdgeInset)
            verticalDelta = autoScrollSpeed * intensity
        }

        if abs(verticalDelta) > 0.1 {
            onVerticalAutoScroll?(verticalDelta)
            didScroll = true
        }

        if didScroll {
            renderUpdate()
            updateSelectionDuringDrag(point: point, viewModel: viewModel, renderer: renderer, forceUpdate: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScrollTimer()
        isDragging = false
        dragStartPoint = nil
        dragStartTextPosition = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
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
        viewModel?.releaseMemory()
        viewModel = nil
        onLayoutChanged = nil
        onVerticalAutoScroll = nil
        onHorizontalScrollChanged = nil
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
    }

    deinit {
        autoScrollTimer?.invalidate()
        viewModelCancellable?.cancel()
        viewModelCancellable = nil
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil
        onLayoutChanged = nil
        viewModel = nil
        renderer = nil
    }
}
