import SwiftUI
import Combine

/// Observes the system's preferred scroller style (overlay vs legacy).
/// Legacy scrollers (shown when using a mouse) take up space in the scroll view,
/// while overlay scrollers (shown when using a trackpad) do not.
final class ScrollerStyleObserver: ObservableObject {
    /// Whether the system is using legacy (always-visible) scrollers
    @Published private(set) var isLegacyScrollers: Bool = false

    private var observer: NSObjectProtocol?

    init() {
        updateStyle()

        // Observe changes to scroller style preference
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStyle()
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateStyle() {
        isLegacyScrollers = NSScroller.preferredScrollerStyle == .legacy
    }
}
