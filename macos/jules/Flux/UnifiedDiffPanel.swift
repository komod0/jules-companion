import SwiftUI
import MetalKit
import Combine

/// SwiftUI wrapper for the unified Metal diff view.
/// This replaces the SwiftUI ScrollView + LazyVStack approach with a single NSScrollView + Metal view.
struct UnifiedDiffPanel: NSViewRepresentable {

    /// The diffs to display
    let diffs: [(patch: String, language: String?, filename: String?)]

    /// Session ID for caching and navigation
    let sessionId: String

    /// Binding for scroll-to-file navigation
    @Binding var scrollToFile: (sessionId: String, filename: String)?

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = UnifiedDiffScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        // Disable scroll bounce (rubber-banding) for both directions
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none

        // Background - use main background color for space between diff files
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(AppColors.background)

        // Layer backing for performance
        scrollView.wantsLayer = true

        // Create the document view (container for Metal view)
        let documentView = UnifiedDiffDocumentView(frame: .zero)
        documentView.coordinator = context.coordinator
        scrollView.documentView = documentView

        // Store references
        context.coordinator.scrollView = scrollView
        context.coordinator.documentView = documentView

        // Create and configure Metal view
        guard let device = fluxSharedMetalDevice else {
            fatalError("Metal not supported")
        }

        let metalView = UnifiedMetalDiffView(device: device)
        let viewModel = UnifiedDiffViewModel()
        metalView.viewModel = viewModel

        documentView.metalView = metalView
        documentView.addSubview(metalView)

        // Ensure scroll indicator is on top of metal view
        documentView.bringScrollIndicatorToFront()

        // Wire up horizontal scroll callback for scrollbar updates
        metalView.onHorizontalScrollChanged = { [weak documentView] sectionIndex in
            documentView?.notifyHorizontalScrollChanged(sectionIndex: sectionIndex)
        }

        // Wire up vertical auto-scroll callback for text selection drag
        metalView.onVerticalAutoScroll = { [weak scrollView] delta in
            guard let scrollView = scrollView else { return }
            let visibleRect = scrollView.documentVisibleRect
            let contentHeight = scrollView.documentView?.frame.height ?? 0

            // Calculate new scroll position (clamped to valid range)
            let newY = max(0, min(contentHeight - visibleRect.height, visibleRect.origin.y + delta))
            let newOrigin = NSPoint(x: visibleRect.origin.x, y: newY)

            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        context.coordinator.metalView = metalView
        context.coordinator.viewModel = viewModel

        // Set up scroll observation
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Initial content update
        viewModel.updateContent(diffs: diffs, sessionId: sessionId)
        documentView.updateDocumentSize()

        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // CRITICAL: Clean up resources when the view is removed from the hierarchy
        // Without this, Metal resources, view models, and notification observers leak

        // Remove notification observer to prevent Coordinator from being retained
        NotificationCenter.default.removeObserver(coordinator)

        // Release Metal view resources
        coordinator.metalView?.releaseResources()

        // Clear strong references
        coordinator.viewModel = nil
        coordinator.metalView = nil
        coordinator.documentView = nil
        coordinator.scrollView = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Compute hash of current diffs to detect changes
        var hasher = Hasher()
        hasher.combine(sessionId)
        for diff in diffs {
            hasher.combine(diff.patch)
            hasher.combine(diff.language)
            hasher.combine(diff.filename)
        }
        let currentHash = hasher.finalize()

        // Check for scroll-to-file request (must handle even if diffs unchanged)
        let hasScrollRequest = scrollToFile != nil && scrollToFile?.sessionId == sessionId

        // CRITICAL: Detect session change to force immediate visual update
        // When rapidly paginating, we must clear the old session's content immediately
        // to prevent showing stale diffs from a previous session
        let sessionChanged = sessionId != context.coordinator.lastSessionId

        // Early return if nothing has changed and no scroll request
        if currentHash == context.coordinator.lastDiffsHash &&
           !sessionChanged &&
           !hasScrollRequest {
            return
        }

        // Detect if this is just a scroll request with no content change
        let contentChanged = currentHash != context.coordinator.lastDiffsHash || sessionChanged

        // Update stored hash
        context.coordinator.lastDiffsHash = currentHash
        context.coordinator.lastSessionId = sessionId

        guard let viewModel = context.coordinator.viewModel,
              let documentView = context.coordinator.documentView else { return }

        // CRITICAL: When session changes, reset scroll position to top
        // Don't preserve scroll position from previous session
        if sessionChanged {
            context.coordinator.clearSavedScrollPosition()
            // Scroll to top for new session
            let topPoint = NSPoint(x: 0, y: 0)
            scrollView.contentView.scroll(to: topPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // NOTE: Don't call renderUpdate() here before viewModel.updateContent().
            // That would render OLD content right before clearing. Instead, the
            // viewModel.updateContent() method handles GPU buffer clearing via
            // onSessionChangeRequiresGPUClear callback when it detects session change.
        } else {
            // CRITICAL: Save scroll position before ANY updates
            // This preserves scroll position even when SwiftUI triggers unnecessary updates
            context.coordinator.saveScrollPosition()
        }

        // Update content - viewModel has internal hash-based change detection
        // for efficient handling of: no change, append-only, or full rebuild
        let previousHeight = viewModel.totalContentHeight
        viewModel.updateContent(diffs: diffs, sessionId: sessionId)

        // Update document size if content height changed OR session changed
        // Session change requires document size update even if going to empty content
        if viewModel.totalContentHeight != previousHeight || sessionChanged {
            documentView.updateDocumentSize()
        }

        // Handle scroll-to-file (this intentionally changes scroll position)
        if let target = scrollToFile, target.sessionId == sessionId {
            if let yOffset = viewModel.yOffset(forFilename: target.filename) {
                // Scroll to the file with some padding
                let targetPoint = NSPoint(x: 0, y: max(0, yOffset - 8))
                scrollView.contentView.scroll(to: targetPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            DispatchQueue.main.async {
                scrollToFile = nil
            }
            // Don't restore scroll position - we intentionally scrolled to a file
            // Just clear the saved position without restoring
            context.coordinator.clearSavedScrollPosition()
        } else if contentChanged && !sessionChanged {
            // Content changed but no scroll request and same session - restore previous scroll position
            // Use async to ensure document view has finished updating
            DispatchQueue.main.async {
                context.coordinator.restoreScrollPosition()
            }
        } else if !sessionChanged {
            // No content change, just cleanup
            context.coordinator.restoreScrollPosition()
        }
        // Note: When sessionChanged, we already scrolled to top above
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        var parent: UnifiedDiffPanel
        weak var scrollView: NSScrollView?
        weak var documentView: UnifiedDiffDocumentView?
        weak var metalView: UnifiedMetalDiffView?
        var viewModel: UnifiedDiffViewModel?

        private var lastScrollY: CGFloat = -1
        private var lastViewportHeight: CGFloat = -1

        /// Hash of the last processed diffs to detect changes
        var lastDiffsHash: Int = 0
        var lastSessionId: String = ""

        /// Saved scroll position for restoration after updates
        /// Used to preserve scroll position across view updates
        private var savedScrollPosition: CGFloat?

        /// Flag to track if we're in the middle of an update
        /// Prevents scroll position from being modified during update
        private var isUpdating: Bool = false

        /// Time of last user scroll action
        /// Used to avoid conflicting with active scrolling
        private var lastUserScrollTime: CFTimeInterval = 0

        /// Threshold for considering user as actively scrolling (100ms)
        private let activeScrollThreshold: CFTimeInterval = 0.1

        init(_ parent: UnifiedDiffPanel) {
            self.parent = parent
        }

        /// Save current scroll position before updates
        func saveScrollPosition() {
            guard let scrollView = scrollView else { return }
            savedScrollPosition = scrollView.documentVisibleRect.origin.y
            isUpdating = true
        }

        /// Restore scroll position after updates
        func restoreScrollPosition() {
            defer {
                isUpdating = false
                savedScrollPosition = nil
            }

            guard let scrollView = scrollView,
                  let savedY = savedScrollPosition else { return }

            // Don't restore if user is actively scrolling
            // This prevents fighting with user's scroll actions
            let timeSinceLastScroll = CACurrentMediaTime() - lastUserScrollTime
            if timeSinceLastScroll < activeScrollThreshold {
                return
            }

            let currentY = scrollView.documentVisibleRect.origin.y
            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let viewportHeight = scrollView.documentVisibleRect.height

            // Only restore if position actually changed and we have valid content
            guard contentHeight > 0 else { return }

            // Clamp to valid range
            let maxScrollY = max(0, contentHeight - viewportHeight)
            let targetY = min(savedY, maxScrollY)

            // Only scroll if there's a meaningful difference
            if abs(currentY - targetY) > 1 {
                let targetPoint = NSPoint(x: 0, y: targetY)
                scrollView.contentView.scroll(to: targetPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// Clear saved scroll position without restoring
        /// Used when scroll position intentionally changes (e.g., scroll-to-file)
        func clearSavedScrollPosition() {
            isUpdating = false
            savedScrollPosition = nil
        }

        /// Called when user scrolls to track active scrolling
        func recordUserScroll() {
            lastUserScrollTime = CACurrentMediaTime()
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let scrollView = scrollView,
                  let metalView = metalView,
                  let documentView = documentView else { return }

            let visibleRect = scrollView.documentVisibleRect
            let scrollY = visibleRect.origin.y
            let viewportHeight = visibleRect.height

            // Skip if nothing changed
            if scrollY == lastScrollY && viewportHeight == lastViewportHeight {
                return
            }

            // Track that user is actively scrolling
            // This prevents scroll position restoration from interfering
            recordUserScroll()

            lastScrollY = scrollY
            lastViewportHeight = viewportHeight

            // Update Metal view frame to track scroll position
            // This keeps the Metal texture within size limits while scrolling
            documentView.updateMetalViewFrame(visibleRect: visibleRect)

            // Update Metal view content
            metalView.updateScrollPosition(scrollY, viewportHeight: viewportHeight)
            metalView.renderUpdate()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Custom NSScrollView

/// Custom scroll view with flipped coordinate system
class UnifiedDiffScrollView: NSScrollView {
    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)

        // Notify document view of scroll
        if let docView = documentView as? UnifiedDiffDocumentView {
            docView.handleScrollChanged()
        }
    }
}

// MARK: - Horizontal Scroll Indicator

/// Custom horizontal scrollbar that matches Apple's overlay scrollbar style.
/// Shows per-section horizontal scroll progress and supports drag-to-scroll.
class HorizontalScrollIndicator: NSView {
    // MARK: - Configuration

    private let scrollbarHeight: CGFloat = 8
    private let scrollbarMinWidth: CGFloat = 30
    private let scrollbarInset: CGFloat = 4
    private let cornerRadius: CGFloat = 4
    private let fadeOutDelay: TimeInterval = 1.5

    // MARK: - State

    private var currentSectionIndex: Int?
    private var scrollProgress: CGFloat = 0  // 0 to 1
    private var contentRatio: CGFloat = 1    // viewport / content, 1 means no scroll needed
    private var isHovered = false
    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartProgress: CGFloat = 0
    private var dragSectionIndex: Int?  // Section index at drag start (stable during drag)
    private var dragContentRatio: CGFloat = 1  // Content ratio at drag start (stable during drag)

    private var fadeOutTimer: Timer?
    private var currentOpacity: CGFloat = 0
    private let animator = NSAnimationContext.current

    // Throttling for smooth scrolling during drag
    private var lastScrollTime: CFTimeInterval = 0
    private let minScrollInterval: CFTimeInterval = 1.0 / 120.0  // 120 fps max

    // Active scroll tracking - prevents hover from switching away from actively scrolled section
    private var activeScrollSection: Int?
    private var activeScrollTimer: Timer?
    private let activeScrollTimeout: TimeInterval = 0.3  // Time after scroll stops before allowing hover switch

    weak var viewModel: UnifiedDiffViewModel?
    var onScrollChanged: ((Int, CGFloat) -> Void)?  // (sectionIndex, newProgress)

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor

        // Track mouse for hover effects
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Update the scrollbar state for a given section
    /// - Parameters:
    ///   - sectionIndex: The section index (nil if not over a section)
    ///   - scrollOffset: Current horizontal scroll offset
    ///   - maxScroll: Maximum scroll value
    ///   - sectionFrame: The full section frame in document coordinates
    ///   - viewportTop: The top Y coordinate of the visible viewport
    ///   - viewportBottom: The bottom Y coordinate of the visible viewport
    ///   - isActiveScroll: True if this update is from an active scroll event (not hover)
    func update(forSection sectionIndex: Int?, scrollOffset: CGFloat, maxScroll: CGFloat, sectionFrame: NSRect?, viewportTop: CGFloat, viewportBottom: CGFloat, isActiveScroll: Bool = false) {
        let previousSection = currentSectionIndex

        if let sectionIndex = sectionIndex, let sectionFrame = sectionFrame, maxScroll > 0 {
            // Position scrollbar at the actual bottom of the section
            let sectionBottom = sectionFrame.maxY
            let scrollbarY = sectionBottom - scrollbarHeight - scrollbarInset - 2  // 2px above footer

            // Check if scrollbar position is visible within the viewport
            // Scrollbar is visible if its top is above viewport bottom AND its bottom is below viewport top
            let isBottomVisible = scrollbarY < viewportBottom && (scrollbarY + scrollbarHeight) > viewportTop

            if isBottomVisible {
                // For active scroll events: always switch to the scrolled section
                // For hover events: only switch if not currently showing a different actively-scrolled section
                // This prevents mouse movement from switching away from the section being scrolled
                if isActiveScroll {
                    activeScrollSection = sectionIndex
                    // Reset the timer - will clear activeScrollSection after timeout
                    activeScrollTimer?.invalidate()
                    activeScrollTimer = Timer.scheduledTimer(withTimeInterval: activeScrollTimeout, repeats: false) { [weak self] _ in
                        self?.activeScrollSection = nil
                    }
                } else if let activeSection = activeScrollSection, activeSection != sectionIndex {
                    // During active scrolling of another section, ignore hover updates
                    return
                }

                // Only update state when this section's scrollbar is visible
                // This prevents a visible scrollbar from showing another section's scroll progress
                currentSectionIndex = sectionIndex
                scrollProgress = scrollOffset / maxScroll
                // Use section frame width for content ratio calculation
                contentRatio = 1.0 / (1.0 + maxScroll / sectionFrame.width)

                // Show the scrollbar at the section bottom
                showScrollbar()

                // Inset from section edges (section has horizontal padding applied)
                self.frame = NSRect(
                    x: sectionFrame.origin.x + scrollbarInset,
                    y: scrollbarY,
                    width: sectionFrame.width - (scrollbarInset * 2),
                    height: scrollbarHeight
                )
                needsDisplay = true
            }
            // If section's scrollbar position isn't visible, don't update anything
            // This prevents the currently-visible scrollbar from showing wrong section's progress
        } else if previousSection != nil && sectionIndex == nil {
            currentSectionIndex = sectionIndex
            // Mouse left the section - schedule fade out (but not during drag)
            if !isDragging {
                scheduleFadeOut()
            }
            needsDisplay = true
        }
    }

    /// Show the scrollbar (called when scrolling occurs)
    func showScrollbar() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil

        if currentOpacity < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.animator().alphaValue = 1
            }
            currentOpacity = 1
        }

        scheduleFadeOut()
    }

    /// Sync scroll progress from actual scroll offset (called after offset is clamped)
    /// This ensures the scrollbar thumb position matches the actual scroll state
    func syncProgress(_ progress: CGFloat) {
        scrollProgress = max(0, min(1, progress))
        needsDisplay = true
    }

    /// Hide the scrollbar immediately
    func hideScrollbar() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            self.animator().alphaValue = 0
        }
        currentOpacity = 0
    }

    // MARK: - Private Helpers

    private func scheduleFadeOut() {
        fadeOutTimer?.invalidate()

        guard !isDragging && !isHovered else { return }

        fadeOutTimer = Timer.scheduledTimer(withTimeInterval: fadeOutDelay, repeats: false) { [weak self] _ in
            self?.hideScrollbar()
        }
    }

    private func scrollbarRect(usingContentRatio ratio: CGFloat? = nil) -> NSRect {
        let trackWidth = bounds.width
        let effectiveRatio = ratio ?? contentRatio
        let thumbWidth = max(scrollbarMinWidth, trackWidth * effectiveRatio)
        let availableWidth = trackWidth - thumbWidth
        let thumbX = availableWidth * scrollProgress

        return NSRect(x: thumbX, y: 0, width: thumbWidth, height: scrollbarHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // During drag, use stored drag state even if mouse is outside section
        let effectiveSectionIndex = currentSectionIndex ?? (isDragging ? dragSectionIndex : nil)
        let effectiveContentRatio = isDragging ? dragContentRatio : contentRatio

        guard effectiveSectionIndex != nil, effectiveContentRatio < 1 else { return }

        let thumbRect = scrollbarRect(usingContentRatio: effectiveContentRatio)

        // Draw track (subtle, only on hover)
        if isHovered || isDragging {
            let trackPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor(white: 0.5, alpha: 0.1).setFill()
            trackPath.fill()
        }

        // Draw thumb
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: cornerRadius, yRadius: cornerRadius)
        let thumbColor: NSColor
        if isDragging {
            thumbColor = NSColor(white: 0.4, alpha: 0.8)
        } else if isHovered {
            thumbColor = NSColor(white: 0.45, alpha: 0.7)
        } else {
            thumbColor = NSColor(white: 0.5, alpha: 0.5)
        }
        thumbColor.setFill()
        thumbPath.fill()
    }

    // MARK: - Mouse Handling

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        scheduleFadeOut()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let sectionIndex = currentSectionIndex else { return }

        let point = convert(event.locationInWindow, from: nil)
        let thumbRect = scrollbarRect()

        if thumbRect.contains(point) {
            // Start dragging the thumb
            isDragging = true
            dragStartX = point.x
            dragStartProgress = scrollProgress
            dragSectionIndex = sectionIndex  // Store section index for stable drag
            dragContentRatio = contentRatio  // Store content ratio for stable drag
        } else {
            // Click on track - jump to that position
            let trackWidth = bounds.width
            let thumbWidth = max(scrollbarMinWidth, trackWidth * contentRatio)
            let availableWidth = trackWidth - thumbWidth
            let newProgress = max(0, min(1, (point.x - thumbWidth / 2) / availableWidth))
            scrollProgress = newProgress
            onScrollChanged?(sectionIndex, newProgress)
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        // Use stored dragSectionIndex (stable during drag) instead of currentSectionIndex
        // This allows dragging to continue even when mouse goes outside the view/window
        guard isDragging, let sectionIndex = dragSectionIndex else { return }

        let point = convert(event.locationInWindow, from: nil)
        let deltaX = point.x - dragStartX

        let trackWidth = bounds.width
        // Use stored dragContentRatio for consistent thumb size during drag
        let thumbWidth = max(scrollbarMinWidth, trackWidth * dragContentRatio)
        let availableWidth = trackWidth - thumbWidth

        if availableWidth > 0 {
            let progressDelta = deltaX / availableWidth
            let newProgress = max(0, min(1, dragStartProgress + progressDelta))
            scrollProgress = newProgress

            // Throttle scroll callbacks for smooth performance
            let currentTime = CACurrentMediaTime()
            if currentTime - lastScrollTime >= minScrollInterval {
                lastScrollTime = currentTime
                onScrollChanged?(sectionIndex, newProgress)
            }
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Apply final scroll position using the stored drag section index
        if let sectionIndex = dragSectionIndex {
            onScrollChanged?(sectionIndex, scrollProgress)
        }

        isDragging = false
        dragSectionIndex = nil  // Clear stored section index
        scheduleFadeOut()
        needsDisplay = true
    }

    // MARK: - Cleanup

    deinit {
        fadeOutTimer?.invalidate()
        activeScrollTimer?.invalidate()
    }
}

// MARK: - Document View

/// The document view that hosts the Metal diff view.
/// Its frame is sized to the total content height for scrollbar purposes.
/// CRITICAL: The Metal view is sized to the viewport (visible area) to avoid exceeding
/// Metal's texture size limit of 16384 pixels. At 3x Retina scale, that's ~5461 points max.
class UnifiedDiffDocumentView: NSView {
    weak var coordinator: UnifiedDiffPanel.Coordinator?
    weak var metalView: UnifiedMetalDiffView?
    var scrollIndicator: HorizontalScrollIndicator?

    // Track which section the mouse is over for scrollbar display
    private var currentHoveredSection: Int?
    private var mouseTrackingArea: NSTrackingArea?

    // Render coalescing for smooth scrollbar dragging
    private var pendingRenderUpdate = false

    // Lockout mechanism for horizontal scroll - prevents scrollbar from jumping to wrong section
    private var activeScrollSectionIndex: Int?
    private var scrollLockoutTimer: Timer?
    private let scrollLockoutDuration: TimeInterval = 0.15  // Short lockout after scroll wheel

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor(AppColors.background).cgColor

        // Create scroll indicator
        scrollIndicator = HorizontalScrollIndicator(frame: .zero)
        scrollIndicator?.alphaValue = 0
        if let indicator = scrollIndicator {
            addSubview(indicator)
        }

        // Set up mouse tracking
        updateTrackingArea()

        // Observe split view divider resizing
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDividerDidResize),
            name: .splitViewDividerDidResize,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        scrollLockoutTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func updateTrackingArea() {
        if let existing = mouseTrackingArea {
            removeTrackingArea(existing)
        }
        mouseTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let area = mouseTrackingArea {
            addTrackingArea(area)
        }
    }

    /// Bring scroll indicator to front of view hierarchy (called after metalView is added)
    func bringScrollIndicatorToFront() {
        if let indicator = scrollIndicator {
            indicator.removeFromSuperview()
            addSubview(indicator)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        updateScrollIndicatorForMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        currentHoveredSection = nil
        scrollIndicator?.update(forSection: nil, scrollOffset: 0, maxScroll: 0, sectionFrame: nil, viewportTop: 0, viewportBottom: 0)
    }

    private func updateScrollIndicatorForMousePosition(_ event: NSEvent) {
        guard let viewModel = coordinator?.viewModel,
              let scrollView = enclosingScrollView else { return }

        let point = convert(event.locationInWindow, from: nil)
        let visibleRect = scrollView.documentVisibleRect
        let viewportTop = visibleRect.origin.y
        let viewportBottom = viewportTop + visibleRect.height

        // Find which section the mouse is over
        if let sectionIndex = viewModel.sectionIndex(atY: point.y) {
            currentHoveredSection = sectionIndex

            // During scroll lockout, only update if mouse is over the actively scrolled section
            // This prevents the scrollbar from jumping to a different section during scroll gestures
            if let activeSection = activeScrollSectionIndex, activeSection != sectionIndex {
                return
            }

            let scrollOffset = viewModel.scrollOffsetX(forSection: sectionIndex)
            let maxScroll = viewModel.maxScrollX(forSection: sectionIndex)

            // Get full section frame for scrollbar positioning
            if let sectionFrame = viewModel.sectionFrame(forSection: sectionIndex) {
                scrollIndicator?.viewModel = viewModel
                scrollIndicator?.onScrollChanged = { [weak self] sectionIdx, progress in
                    self?.handleScrollIndicatorChanged(sectionIndex: sectionIdx, progress: progress)
                }
                scrollIndicator?.update(
                    forSection: sectionIndex,
                    scrollOffset: scrollOffset,
                    maxScroll: maxScroll,
                    sectionFrame: sectionFrame,
                    viewportTop: viewportTop,
                    viewportBottom: viewportBottom
                )
            }
        } else {
            currentHoveredSection = nil
            // Only update to nil if no active scroll lockout
            if activeScrollSectionIndex == nil {
                scrollIndicator?.update(forSection: nil, scrollOffset: 0, maxScroll: 0, sectionFrame: nil, viewportTop: 0, viewportBottom: 0)
            }
        }
    }

    private func handleScrollIndicatorChanged(sectionIndex: Int, progress: CGFloat) {
        guard let viewModel = coordinator?.viewModel else { return }

        let maxScroll = viewModel.maxScrollX(forSection: sectionIndex)
        let newOffset = progress * maxScroll
        viewModel.setScrollOffsetX(newOffset, forSection: sectionIndex)

        // Sync scrollbar progress back from actual (potentially clamped) offset
        // This ensures the scrollbar thumb position matches the actual scroll state
        let actualOffset = viewModel.scrollOffsetX(forSection: sectionIndex)
        let syncedProgress = maxScroll > 0 ? actualOffset / maxScroll : 0
        scrollIndicator?.syncProgress(syncedProgress)

        // Coalesce render updates for smooth scrolling
        // Multiple scroll events in the same frame will result in a single render
        if !pendingRenderUpdate {
            pendingRenderUpdate = true
            DispatchQueue.main.async { [weak self] in
                self?.pendingRenderUpdate = false
                self?.metalView?.renderUpdate()
            }
        }
    }

    /// Called when horizontal scroll changes (from scroll wheel)
    func notifyHorizontalScrollChanged(sectionIndex: Int) {
        guard let viewModel = coordinator?.viewModel,
              let scrollView = enclosingScrollView else { return }

        // Set scroll lockout to prevent mouse-based updates from switching sections
        setScrollLockout(forSection: sectionIndex)

        let scrollOffset = viewModel.scrollOffsetX(forSection: sectionIndex)
        let maxScroll = viewModel.maxScrollX(forSection: sectionIndex)
        let visibleRect = scrollView.documentVisibleRect
        let viewportTop = visibleRect.origin.y
        let viewportBottom = viewportTop + visibleRect.height

        if let sectionFrame = viewModel.sectionFrame(forSection: sectionIndex) {
            scrollIndicator?.update(
                forSection: sectionIndex,
                scrollOffset: scrollOffset,
                maxScroll: maxScroll,
                sectionFrame: sectionFrame,
                viewportTop: viewportTop,
                viewportBottom: viewportBottom,
                isActiveScroll: true  // This is from a scroll wheel event
            )
        }
    }

    /// Set a temporary lockout on section switching during active scrolling
    private func setScrollLockout(forSection sectionIndex: Int) {
        activeScrollSectionIndex = sectionIndex

        // Cancel any existing timer and start a new one
        scrollLockoutTimer?.invalidate()
        scrollLockoutTimer = Timer.scheduledTimer(withTimeInterval: scrollLockoutDuration, repeats: false) { [weak self] _ in
            self?.activeScrollSectionIndex = nil
        }
    }

    @objc private func handleDividerDidResize() {
        // When the split view divider is dragged, update the document view width
        // and Metal view frame to fill the new available space.
        // IMPORTANT: Defer to next run loop iteration because when this notification
        // is received, the scroll view's contentSize hasn't been updated yet.
        DispatchQueue.main.async { [weak self] in
            self?.updateDocumentSize()
        }
    }

    /// Update document size to match content
    func updateDocumentSize() {
        guard let viewModel = coordinator?.viewModel else { return }

        let contentHeight = viewModel.totalContentHeight
        guard let scrollView = enclosingScrollView else { return }
        let width = scrollView.contentSize.width

        // CRITICAL FIX: Preserve scroll position before changing frame.
        // When the document frame changes, NSScrollView may internally reset the scroll
        // position. We need to capture it before the change and restore it after.
        let savedScrollY = scrollView.documentVisibleRect.origin.y
        let viewportHeight = scrollView.documentVisibleRect.height

        // Size document to total content (this drives the scrollbar)
        self.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        // Handle viewport width change - clamp scroll offsets
        viewModel.handleViewportWidthChange(newWidth: width)

        // Restore scroll position - clamp to valid range for new content height
        let maxScrollY = max(0, contentHeight - viewportHeight)
        let restoredScrollY = min(savedScrollY, maxScrollY)

        // Only restore if scroll position was affected by the frame change
        let currentScrollY = scrollView.documentVisibleRect.origin.y
        if abs(currentScrollY - restoredScrollY) > 1 {
            let restoredPoint = NSPoint(x: 0, y: restoredScrollY)
            scrollView.contentView.scroll(to: restoredPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // CRITICAL FIX: Metal view should be sized to viewport, NOT document!
        // Metal textures are limited to 16384 pixels. Large diffs can easily exceed this.
        // The Metal view renders only what's visible, so it only needs viewport-sized texture.
        let visibleRect = scrollView.documentVisibleRect
        updateMetalViewFrame(visibleRect: visibleRect)
        metalView?.updateScrollPosition(visibleRect.origin.y, viewportHeight: visibleRect.height)
        // Note: renderUpdate is NOT called here - the view model's objectWillChange
        // subscription in UnifiedMetalDiffView handles triggering renders when content changes.
        // This prevents redundant double-renders on initial load.
    }

    /// Update Metal view frame to match the visible rect.
    /// This keeps the Metal texture within Metal's size limits while
    /// allowing the document to be any height for scrollbar purposes.
    func updateMetalViewFrame(visibleRect: NSRect) {
        guard let metalView = metalView else { return }

        let width = bounds.width
        let viewportHeight = visibleRect.height
        let scrollY = visibleRect.origin.y

        // Position the Metal view at the top of the visible area.
        // The Metal view will render content offset by scrollY internally.
        metalView.frame = NSRect(x: 0, y: scrollY, width: width, height: viewportHeight)
    }

    func handleScrollChanged() {
        coordinator?.scrollViewDidScroll(Notification(name: NSView.boundsDidChangeNotification))
    }

    override func layout() {
        super.layout()

        // Update width and Metal view frame
        if let scrollView = enclosingScrollView {
            let newWidth = scrollView.contentSize.width
            let visibleRect = scrollView.documentVisibleRect

            let widthChanged = abs(frame.width - newWidth) > 1
            if widthChanged {
                frame.size.width = newWidth
            }

            // Always update Metal view frame to track scroll position
            updateMetalViewFrame(visibleRect: visibleRect)

            // Handle viewport width change - clamp scroll offsets
            if widthChanged, let viewModel = coordinator?.viewModel {
                viewModel.handleViewportWidthChange(newWidth: newWidth)
            }

            // Note: renderUpdate is NOT called here - the Metal view's own layout()
            // method handles rendering when its bounds change. Calling it here would
            // cause redundant double-renders.
        }
    }

    /// Update scroll indicator visibility after resize
    private func updateScrollIndicatorForResize() {
        guard let viewModel = coordinator?.viewModel,
              let scrollView = enclosingScrollView else { return }

        // Don't show scrollbar if no content is loaded yet
        guard !viewModel.sections.isEmpty else { return }

        // Don't show scrollbar until renderer has initialized monoAdvance
        // This prevents incorrect scroll calculations during initial load
        guard viewModel.hasValidMonoAdvance else { return }

        let visibleRect = scrollView.documentVisibleRect
        let viewportTop = visibleRect.origin.y
        let viewportBottom = viewportTop + visibleRect.height

        // Find which sections are currently visible and have scrollable content
        for section in viewModel.sections {
            let sectionTop = section.yOffset
            let sectionBottom = section.yOffset + section.totalHeight

            // Check if section is visible
            guard sectionBottom > viewportTop && sectionTop < viewportBottom else { continue }

            let sectionIndex = section.index
            let scrollOffset = viewModel.scrollOffsetX(forSection: sectionIndex)
            let maxScroll = viewModel.maxScrollX(forSection: sectionIndex)

            // Update scroll indicator for this section if it needs scrolling
            if maxScroll > 0 {
                if let sectionFrame = viewModel.sectionFrame(forSection: sectionIndex) {
                    scrollIndicator?.viewModel = viewModel
                    scrollIndicator?.onScrollChanged = { [weak self] sectionIdx, progress in
                        self?.handleScrollIndicatorChanged(sectionIndex: sectionIdx, progress: progress)
                    }
                    scrollIndicator?.update(
                        forSection: sectionIndex,
                        scrollOffset: scrollOffset,
                        maxScroll: maxScroll,
                        sectionFrame: sectionFrame,
                        viewportTop: viewportTop,
                        viewportBottom: viewportBottom
                    )
                }
                // Only show scrollbar for one section at a time during resize
                break
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        if superview != nil {
            updateDocumentSize()
        }
    }
}

// MARK: - Preview

#if DEBUG
struct UnifiedDiffPanel_Previews: PreviewProvider {
    static var previews: some View {
        UnifiedDiffPanel(
            diffs: [
                (patch: """
                diff --git a/test.swift b/test.swift
                --- a/test.swift
                +++ b/test.swift
                @@ -1,3 +1,4 @@
                 import Foundation
                +import SwiftUI

                 class Test {
                """, language: "swift", filename: "test.swift")
            ],
            sessionId: "preview",
            scrollToFile: .constant(nil)
        )
        .frame(width: 600, height: 400)
    }
}
#endif
