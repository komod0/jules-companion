import SwiftUI
import AppKit

class CenteredSplitViewController: NSSplitViewController {
    private var initialSplitSet = false
    private var lastDividerPosition: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        setInitialSplitIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        setInitialSplitIfNeeded()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)

        // Get current divider position
        guard splitView.subviews.count > 0 else { return }
        let currentPosition = splitView.subviews[0].frame.width

        // Only notify if position actually changed (filter duplicate calls)
        if abs(currentPosition - lastDividerPosition) > 1 {
            lastDividerPosition = currentPosition
            NotificationCenter.default.post(name: .splitViewDividerDidResize, object: self)
        }
    }

    private func setInitialSplitIfNeeded() {
        guard !initialSplitSet else { return }
        // Prefer the window's content width to align with the visible area; fall back to the split view's bounds.
        let width = view.window?.contentLayoutRect.width ?? splitView.bounds.width
        guard width > 0 else { return }

        let availableWidth = width - splitView.dividerThickness
        let halfWidth = availableWidth / 2

        // Set position synchronously first to avoid visual flash from content-driven sizing.
        splitView.setPosition(halfWidth, ofDividerAt: 0)
        initialSplitSet = true

        // Also dispatch to the next run loop to correct any drift after SwiftUI layout completes.
        // This ensures the 50/50 split is maintained even if SwiftUI reports different content sizes.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let finalWidth = self.view.window?.contentLayoutRect.width ?? self.splitView.bounds.width
            guard finalWidth > 0 else { return }
            let finalAvailable = finalWidth - self.splitView.dividerThickness
            let finalHalf = finalAvailable / 2
            self.splitView.setPosition(finalHalf, ofDividerAt: 0)
        }
    }
}

struct SplitViewController<A: View, B: View>: NSViewControllerRepresentable {
    var viewA: A
    var viewB: B

    init(@ViewBuilder viewA: () -> A, @ViewBuilder viewB: () -> B) {
        self.viewA = viewA()
        self.viewB = viewB()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitViewController = CenteredSplitViewController()

        let controllerA = NSHostingController(rootView: viewA)
        let controllerB = NSHostingController(rootView: viewB)

        // Prevent hosting controllers from reporting intrinsic content size that would
        // cause the split view to shift from 50/50. This fixes the double-render stutter
        // where the diff view would initially request more width than its allocation.
        controllerA.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controllerA.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controllerB.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controllerB.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Enable layer-backed views for smoother animation (allows CALayer optimizations)
        controllerA.view.wantsLayer = true
        controllerB.view.wantsLayer = true

        // Configure layer redraw policy to redraw during resize to avoid stale cached content
        controllerA.view.layerContentsRedrawPolicy = .duringViewResize
        controllerB.view.layerContentsRedrawPolicy = .duringViewResize

        // Use .center placement to prevent visual "sliding" artifacts when views re-render.
        // The .scaleProportionallyToFill placement caused cached content to slide during
        // re-renders because it tries to maintain aspect ratio during scaling.
        controllerA.view.layerContentsPlacement = .center
        controllerB.view.layerContentsPlacement = .center

        let itemA = NSSplitViewItem(viewController: controllerA)
        let itemB = NSSplitViewItem(viewController: controllerB)

        // Phase 1: Use optimized holding priorities
        // Design principle: "The left pane holds its ground; the right pane yields."
        // This minimizes constraint churn during resize operations
//        itemA.holdingPriority = NSLayoutConstraint.Priority(200)
//        itemB.holdingPriority = NSLayoutConstraint.Priority(199)

        splitViewController.addSplitViewItem(itemA)
        splitViewController.addSplitViewItem(itemB)

        return splitViewController
    }

    func updateNSViewController(_ nsViewController: NSSplitViewController, context: Context) {
        // Update the views if they change.
        (nsViewController.splitViewItems[0].viewController as? NSHostingController<A>)?.rootView = viewA
        (nsViewController.splitViewItems[1].viewController as? NSHostingController<B>)?.rootView = viewB
    }
}
