import AppKit
import SwiftUI

/// Phase 1: Optimized NSSplitViewController for sidebar animations
/// Design principle: "The Sidebar holds its ground; the DiffView yields."
///
/// This controller minimizes constraint churn during sidebar toggle animations
/// by using carefully tuned holding priorities and interruptible animations.
@MainActor
class OptimizedSplitViewController: NSSplitViewController {

    // MARK: - Configuration

    /// Holding priority for sidebar item - higher value resists resizing more
    /// The sidebar maintains its width during window resize
    private let sidebarHoldingPriority: Float = 200

    /// Holding priority for content/diff item - lower value yields to resize
    /// The content area absorbs resize changes
    private let contentHoldingPriority: Float = 199

    /// Animation duration for sidebar toggle
    private let animationDuration: TimeInterval = 0.25

    /// Whether an animation is currently in progress
    private(set) var isAnimating: Bool = false

    // MARK: - Initialization

    override func viewDidLoad() {
        super.viewDidLoad()
        configureItems()
        configureSplitView()
    }

    /// Programmatically configure split view items with optimized priorities
    private func configureItems() {
        for (index, item) in splitViewItems.enumerated() {
            if index == 0 {
                // Sidebar item: holds its ground
                item.holdingPriority = NSLayoutConstraint.Priority(rawValue: sidebarHoldingPriority)
                item.canCollapse = true

                // Enable layer-backed for GPU-accelerated animation
                // NOTE: Using .center placement to prevent visual "sliding" artifacts when
                // views re-render. The .scaleProportionallyToFill placement caused cached
                // content to slide because it tries to maintain aspect ratio during scaling.
                item.viewController.view.wantsLayer = true
                item.viewController.view.layerContentsRedrawPolicy = .duringViewResize
                item.viewController.view.layerContentsPlacement = .center
            } else {
                // Content/Diff item: yields to resize
                item.holdingPriority = NSLayoutConstraint.Priority(rawValue: contentHoldingPriority)

                // Enable layer-backed for GPU-accelerated animation
                // NOTE: Using .center placement to prevent visual "sliding" artifacts
                item.viewController.view.wantsLayer = true
                item.viewController.view.layerContentsRedrawPolicy = .duringViewResize
                item.viewController.view.layerContentsPlacement = .center
            }
        }
    }

    /// Configure the split view itself for optimal animation performance
    private func configureSplitView() {
        // Layer-backed for smooth divider animations
        splitView.wantsLayer = true

        // Use vertical divider style (sidebar on left)
        splitView.isVertical = true

        // Thin divider for cleaner appearance
        splitView.dividerStyle = .thin

        // Set delegate to track divider changes
        splitView.delegate = self
    }

    // MARK: - NSSplitViewDelegate

    /// Track last known divider position to detect user-initiated divider drags
    private var lastDividerPosition: CGFloat = 0

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Skip if we're animating the sidebar toggle (handled separately)
        guard !isAnimating else { return }

        // Get current divider position
        let currentPosition = sidebarWidth

        // Only notify if position actually changed (filter duplicate calls)
        if abs(currentPosition - lastDividerPosition) > 1 {
            lastDividerPosition = currentPosition
            NotificationCenter.default.post(name: .splitViewDividerDidResize, object: self)
        }
    }

    // MARK: - Optimized Sidebar Toggle

    /// Toggle sidebar with interruptible animation
    /// - Parameter sender: The sender of the action
    @objc override func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem = splitViewItems.first else { return }

        // Notify observers that animation is starting
        NotificationCenter.default.post(name: .sidebarAnimationWillStart, object: self)

        isAnimating = true

        // Use NSAnimationContext for interruptible, GPU-accelerated animation
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            guard let self = self else { return }

            // Animation configuration
            context.duration = self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            // CRITICAL: Allow user interaction during animation
            // This is essential for perceived responsiveness - users can interrupt
            // and reverse the animation mid-way
            context.allowsImplicitAnimation = true

            // Toggle the collapsed state with animation
            sidebarItem.animator().isCollapsed.toggle()

        }, completionHandler: { [weak self] in
            guard let self = self else { return }

            self.isAnimating = false

            // Notify observers that animation completed
            NotificationCenter.default.post(name: .sidebarAnimationDidEnd, object: self)
        })
    }

    /// Collapse sidebar without animation (for state restoration)
    func collapseSidebar(animated: Bool = false) {
        guard let sidebarItem = splitViewItems.first, !sidebarItem.isCollapsed else { return }

        if animated {
            toggleSidebar(nil)
        } else {
            sidebarItem.isCollapsed = true
        }
    }

    /// Expand sidebar without animation (for state restoration)
    func expandSidebar(animated: Bool = false) {
        guard let sidebarItem = splitViewItems.first, sidebarItem.isCollapsed else { return }

        if animated {
            toggleSidebar(nil)
        } else {
            sidebarItem.isCollapsed = false
        }
    }

    // MARK: - Split View Configuration Helpers

    /// Set sidebar width constraints
    /// - Parameters:
    ///   - minimum: Minimum width in points
    ///   - maximum: Maximum width in points
    func setSidebarThickness(minimum: CGFloat, maximum: CGFloat) {
        guard let sidebarItem = splitViewItems.first else { return }
        sidebarItem.minimumThickness = minimum
        sidebarItem.maximumThickness = maximum
    }

    /// Get current sidebar width
    var sidebarWidth: CGFloat {
        guard let sidebarView = splitView.subviews.first else { return 0 }
        return sidebarView.frame.width
    }

    /// Set sidebar to specific width
    /// - Parameter width: Target width in points
    func setSidebarWidth(_ width: CGFloat) {
        guard let sidebarItem = splitViewItems.first else { return }

        // Clamp to valid range
        let clampedWidth = max(
            sidebarItem.minimumThickness,
            min(width, sidebarItem.maximumThickness)
        )

        splitView.setPosition(clampedWidth, ofDividerAt: 0)
    }
}

// MARK: - SwiftUI Wrapper

/// NSViewControllerRepresentable wrapper for OptimizedSplitViewController
struct OptimizedSplitView<Sidebar: View, Content: View>: NSViewControllerRepresentable {
    let sidebar: Sidebar
    let content: Content
    var sidebarMinWidth: CGFloat = 250
    var sidebarMaxWidth: CGFloat = 400
    var initiallyCollapsed: Bool = true

    init(
        sidebarMinWidth: CGFloat = 250,
        sidebarMaxWidth: CGFloat = 400,
        initiallyCollapsed: Bool = true,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content
    ) {
        self.sidebarMinWidth = sidebarMinWidth
        self.sidebarMaxWidth = sidebarMaxWidth
        self.initiallyCollapsed = initiallyCollapsed
        self.sidebar = sidebar()
        self.content = content()
    }

    func makeNSViewController(context: Context) -> OptimizedSplitViewController {
        let splitVC = OptimizedSplitViewController()

        // Create hosting controllers for SwiftUI views
        let sidebarController = NSHostingController(rootView: sidebar)
        let contentController = NSHostingController(rootView: content)

        // Configure hosting controllers to not fight with split view sizing
        sidebarController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebarController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Create split view items
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.isCollapsed = initiallyCollapsed
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth

        let contentItem = NSSplitViewItem(viewController: contentController)

        // Add items to split view controller
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)

        return splitVC
    }

    func updateNSViewController(_ nsViewController: OptimizedSplitViewController, context: Context) {
        // Update sidebar content
        if let sidebarHosting = nsViewController.splitViewItems.first?.viewController as? NSHostingController<Sidebar> {
            sidebarHosting.rootView = sidebar
        }

        // Update content
        if nsViewController.splitViewItems.count > 1,
           let contentHosting = nsViewController.splitViewItems[1].viewController as? NSHostingController<Content> {
            contentHosting.rootView = content
        }
    }
}
