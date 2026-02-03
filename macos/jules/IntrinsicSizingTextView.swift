import AppKit

class IntrinsicSizingTextView: NSTextView {
    /// Tracks the last computed intrinsic size to avoid unnecessary invalidations
    private var lastIntrinsicSize: NSSize = .zero
    /// Guards against re-entrant layout invalidation
    private var isInvalidatingSize: Bool = false

    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return .zero
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // Return exact size needed without extra padding to ensure alignment
        return NSSize(width: usedRect.width, height: usedRect.height)
    }

    override func layout() {
        super.layout()

        // Only invalidate intrinsic content size if it has actually changed.
        // This prevents layout recursion by avoiding unnecessary invalidations.
        // The hosting controller calls layoutSubtreeIfNeeded when intrinsic size changes,
        // which would cause recursion if we always invalidate during layout.
        let currentSize = intrinsicContentSize
        if currentSize != lastIntrinsicSize && !isInvalidatingSize {
            lastIntrinsicSize = currentSize
            isInvalidatingSize = true
            // Use needsLayout instead of invalidateIntrinsicContentSize to avoid
            // triggering layoutSubtreeIfNeeded during the current layout pass.
            // This schedules a layout update for the next cycle instead.
            needsLayout = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isInvalidatingSize = false
                // Only invalidate if still attached to a window to avoid zombie calls
                if self.window != nil {
                    self.invalidateIntrinsicContentSize()
                }
            }
        }
    }
}
