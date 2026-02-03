import SwiftUI
import Combine

/// Manages font size preferences for ActivityView and DiffView
/// Provides centralized font size control with persistence to UserDefaults
@MainActor
class FontSizeManager: ObservableObject {
    static let shared = FontSizeManager()

    // MARK: - UserDefaults Keys
    private let activityFontSizeKey = "activityViewFontSize"
    private let diffFontSizeKey = "diffViewFontSize"

    // MARK: - Default Font Sizes
    static let defaultActivityFontSize: CGFloat = 13.0
    static let defaultDiffFontSize: CGFloat = 12.0

    // MARK: - Font Size Limits
    private let minFontSize: CGFloat = 9.0
    private let maxFontSize: CGFloat = 24.0
    private let fontSizeStep: CGFloat = 1.0

    // MARK: - Published Properties
    /// Current font size for ActivityView (messages, progress, plans, etc.)
    @Published var activityFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(activityFontSize, forKey: activityFontSizeKey)
        }
    }

    /// Current font size for DiffView (code diff rendering)
    @Published var diffFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(diffFontSize, forKey: diffFontSizeKey)
            diffFontSizeChanged.send(diffFontSize)
        }
    }

    /// Publisher for DiffView font size changes (used by non-SwiftUI components)
    let diffFontSizeChanged = PassthroughSubject<CGFloat, Never>()

    // MARK: - Computed Properties

    /// Line height for ActivityView (scales with font size)
    var activityLineHeight: CGFloat {
        return ceil(activityFontSize * 1.5)
    }

    /// Line height for DiffView (scales with font size)
    /// Multiplier of 1.85 provides comfortable spacing for code readability
    var diffLineHeight: Float {
        return Float(ceil(diffFontSize * 1.85))
    }

    // MARK: - Initialization

    private init() {
        // Load saved preferences or use defaults
        let savedActivitySize = UserDefaults.standard.double(forKey: activityFontSizeKey)
        let savedDiffSize = UserDefaults.standard.double(forKey: diffFontSizeKey)

        // Clamp loaded values to valid range to prevent crashes from corrupted UserDefaults
        if savedActivitySize >= minFontSize && savedActivitySize <= maxFontSize {
            self.activityFontSize = CGFloat(savedActivitySize)
        } else {
            self.activityFontSize = Self.defaultActivityFontSize
        }

        if savedDiffSize >= minFontSize && savedDiffSize <= maxFontSize {
            self.diffFontSize = CGFloat(savedDiffSize)
        } else {
            self.diffFontSize = Self.defaultDiffFontSize
        }
    }

    // MARK: - Public Methods

    /// Increases both activity and diff font sizes by one step
    func increaseFontSize() {
        if activityFontSize < maxFontSize {
            activityFontSize = min(activityFontSize + fontSizeStep, maxFontSize)
        }
        if diffFontSize < maxFontSize {
            diffFontSize = min(diffFontSize + fontSizeStep, maxFontSize)
        }
    }

    /// Decreases both activity and diff font sizes by one step
    func decreaseFontSize() {
        if activityFontSize > minFontSize {
            activityFontSize = max(activityFontSize - fontSizeStep, minFontSize)
        }
        if diffFontSize > minFontSize {
            diffFontSize = max(diffFontSize - fontSizeStep, minFontSize)
        }
    }

    /// Resets both font sizes to their defaults
    func resetToDefaults() {
        activityFontSize = Self.defaultActivityFontSize
        diffFontSize = Self.defaultDiffFontSize
    }
}
