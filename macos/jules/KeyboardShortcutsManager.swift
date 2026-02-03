import SwiftUI
import Combine
import HotKey

/// Manages user-customizable keyboard shortcut preferences
/// All shortcuts use Control+Option as the modifier, with customizable final key
@MainActor
class KeyboardShortcutsManager: ObservableObject {
    static let shared = KeyboardShortcutsManager()

    // MARK: - UserDefaults Keys
    private let toggleJulesKeyKey = "shortcut_toggleJules"
    private let screenshotKeyKey = "shortcut_screenshot"
    private let voiceInputKeyKey = "shortcut_voiceInput"

    // MARK: - Available Keys for Shortcuts
    /// Keys available for user selection (A-Z)
    static let availableKeys: [Key] = [
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
        .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z
    ]

    // MARK: - Default Keys
    static let defaultToggleJulesKey: Key = .j
    static let defaultScreenshotKey: Key = .i
    static let defaultVoiceInputKey: Key = .v

    // MARK: - Published Properties

    /// Key for Toggle Jules shortcut (Control+Option+?)
    @Published var toggleJulesKey: Key {
        didSet {
            UserDefaults.standard.set(toggleJulesKey.carbonKeyCode, forKey: toggleJulesKeyKey)
            shortcutsChanged.send()
        }
    }

    /// Key for Screenshot shortcut (Control+Option+?)
    @Published var screenshotKey: Key {
        didSet {
            UserDefaults.standard.set(screenshotKey.carbonKeyCode, forKey: screenshotKeyKey)
            shortcutsChanged.send()
        }
    }

    /// Key for Voice Input shortcut (Control+Option+?)
    @Published var voiceInputKey: Key {
        didSet {
            UserDefaults.standard.set(voiceInputKey.carbonKeyCode, forKey: voiceInputKeyKey)
            shortcutsChanged.send()
        }
    }

    /// Publisher to notify when any shortcut changes (used by AppDelegate to re-register hotkeys)
    let shortcutsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Initialization

    private init() {
        // Load saved preferences or use defaults
        let savedToggleJulesKey = UserDefaults.standard.integer(forKey: toggleJulesKeyKey)
        let savedScreenshotKey = UserDefaults.standard.integer(forKey: screenshotKeyKey)
        let savedVoiceInputKey = UserDefaults.standard.integer(forKey: voiceInputKeyKey)

        // Initialize with saved values or defaults
        // rawValue of 0 means no saved value (since Key.a starts at a higher value)
        if savedToggleJulesKey != 0, let key = Key(carbonKeyCode: UInt32(savedToggleJulesKey)) {
            self.toggleJulesKey = key
        } else {
            self.toggleJulesKey = Self.defaultToggleJulesKey
        }

        if savedScreenshotKey != 0, let key = Key(carbonKeyCode: UInt32(savedScreenshotKey)) {
            self.screenshotKey = key
        } else {
            self.screenshotKey = Self.defaultScreenshotKey
        }

        if savedVoiceInputKey != 0, let key = Key(carbonKeyCode: UInt32(savedVoiceInputKey)) {
            self.voiceInputKey = key
        } else {
            self.voiceInputKey = Self.defaultVoiceInputKey
        }
    }

    // MARK: - Public Methods

    /// Resets all shortcuts to their default values
    func resetToDefaults() {
        toggleJulesKey = Self.defaultToggleJulesKey
        screenshotKey = Self.defaultScreenshotKey
        voiceInputKey = Self.defaultVoiceInputKey
    }

    /// Returns display string for a key (e.g., "J" for .j)
    static func displayString(for key: Key) -> String {
        switch key {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        default: return "?"
        }
    }

    /// Returns the full shortcut display string (e.g., "^+⌥+J")
    func fullShortcutString(for shortcut: ShortcutType) -> String {
        let key: Key
        switch shortcut {
        case .toggleJules:
            key = toggleJulesKey
        case .screenshot:
            key = screenshotKey
        case .voiceInput:
            key = voiceInputKey
        }
        return "^+\u{2325}+\(Self.displayString(for: key))"
    }

    /// Shortcut types for easy reference
    enum ShortcutType {
        case toggleJules
        case screenshot
        case voiceInput
    }
}

// MARK: - Key Extension for Identifiable conformance
extension Key: @retroactive Identifiable {
    public var id: UInt32 { carbonKeyCode }
}
