import SwiftUI
import AppKit

// Adaptive Color Definitions - supports both Light and Dark modes
struct AppColors {

    // MARK: - Base Theme Colors

    /// Main background color
    static let background = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "202124")  // Dark mode
            : NSColor(hex: "FFFFFF")  // Light mode
    }))

    /// Secondary background for cards/sections
    static let backgroundSecondary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "2C2D30")  // Dark mode
            : NSColor(hex: "F5F5F7")  // Light mode
    }))

    /// Darker background for contrast areas
    static let backgroundDark = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "16161a")  // Dark mode
            : NSColor(hex: "E8E8ED")  // Light mode
    }))

    /// Primary text color
    static let textPrimary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white           // Dark mode
            : NSColor(hex: "1D1D1F")  // Light mode
    }))

    /// Secondary/muted text color
    static let textSecondary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "7a7384")  // Dark mode
            : NSColor(hex: "6E6E73")  // Light mode
    }))

    /// Primary accent color (purple)
    static let accent = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "B2A3FF")  // Dark mode - lighter purple
            : NSColor(hex: "7B61FF")  // Light mode - deeper purple
    }))

    /// Light accent variant
    static let accentLight = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "CEC4FF")  // Dark mode
            : NSColor(hex: "A78BFF")  // Light mode
    }))

    /// Secondary accent variant
    static let accentSecondary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "C3BDFF")  // Dark mode
            : NSColor(hex: "9580FF")  // Light mode
    }))

    /// Button text color
    static let buttonText = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.black           // Dark mode
            : NSColor.white           // Light mode
    }))

    /// Button background color
    static let buttonBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white           // Dark mode
            : NSColor(hex: "16161A")  // Light mode - dark background
    }))

    // MARK: - Status Colors

    /// Destructive/Failed status (red)
    static let destructive = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "FF6767")  // Dark mode
            : NSColor(hex: "E53935")  // Light mode - slightly darker red
    }))

    /// Warning status (orange)
    static let warning = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "FF954D")  // Dark mode
            : NSColor(hex: "F57C00")  // Light mode - slightly darker orange
    }))

    /// Review/Paused status (purple)
    static let review = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "B2A3FF")  // Dark mode
            : NSColor(hex: "7B61FF")  // Light mode
    }))

    /// Running/Active status (green)
    static let running = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "80f796")  // Dark mode
            : NSColor(hex: "43A047")  // Light mode - slightly darker green
    }))

    /// Starting status (green)
    static let starting = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "80f796")  // Dark mode
            : NSColor(hex: "43A047")  // Light mode
    }))

    /// Finished/Completed status (gray)
    static let finished = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "7a7384")  // Dark mode
            : NSColor(hex: "9E9E9E")  // Light mode
    }))

    /// Unknown status (gray)
    static let unknown = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "7a7384")  // Dark mode
            : NSColor(hex: "9E9E9E")  // Light mode
    }))

    // MARK: - Diff Colors

    /// Lines removed indicator (red)
    static let linesRemoved = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "ff6767")  // Dark mode
            : NSColor(hex: "FF1008")  // Light mode - +35% saturation
    }))

    /// Lines added indicator (green)
    static let linesAdded = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "80f796")  // Dark mode
            : NSColor(hex: "139916")  // Light mode - +35% saturation
    }))

    // MARK: - Diff/Conflict Background Colors

    /// Background for added diff sections
    static let diffAddedBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1A3D2A")  // Dark mode - dark green tint
            : NSColor(hex: "E6FFEC")  // Light mode - light green
    }))

    /// Background for removed diff sections
    static let diffRemovedBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "3D1A1A")  // Dark mode - dark red tint
            : NSColor(hex: "FFEBE9")  // Light mode - light red
    }))

    /// Background for current (ours) conflict section
    static let conflictCurrentBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1A2A3D")  // Dark mode - dark blue tint
            : NSColor(hex: "E6F3FF")  // Light mode - light blue
    }))

    /// Background for incoming (theirs) conflict section
    static let conflictIncomingBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1A3D2A")  // Dark mode - dark green tint
            : NSColor(hex: "E6FFEC")  // Light mode - light green
    }))

    // MARK: - Merge Conflict Metal Colors

    /// Conflict editor current (ours) line background - NSColor for Metal rendering
    static let conflictEditorCurrentBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "4A90D9").withAlphaComponent(0.18)  // Dark mode - blue with alpha
            : NSColor(hex: "2979FF").withAlphaComponent(0.12)  // Light mode - blue with alpha
    })

    /// Conflict editor incoming (theirs) line background - NSColor for Metal rendering
    static let conflictEditorIncomingBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "4CAF50").withAlphaComponent(0.18)  // Dark mode - green with alpha
            : NSColor(hex: "43A047").withAlphaComponent(0.12)  // Light mode - green with alpha
    })

    /// Conflict editor marker line background (<<<<<<, =======, >>>>>>>) - NSColor for Metal rendering
    static let conflictEditorMarkerBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "808080").withAlphaComponent(0.25)  // Dark mode - gray marker
            : NSColor(hex: "606060").withAlphaComponent(0.15)  // Light mode - gray marker
    })

    /// Conflict marker text color - NSColor for Metal rendering
    static let conflictEditorMarkerText = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "888888")  // Dark mode - muted gray
            : NSColor(hex: "666666")  // Light mode - muted gray
    })

    // MARK: - Diff Editor Colors (Metal-based)
    // Light mode colors based on ayu-theme: https://github.com/ayu-theme/ayu-colors

    /// Diff editor background color
    static let diffEditorBackground = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1A1A1C")  // Dark mode
            : NSColor(hex: "FCFCFC")  // Light mode - ayu light bg
    })

    /// Diff editor default text color
    static let diffEditorText = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "E5E5E5")  // Dark mode - light gray
            : NSColor(hex: "24292E")  // Light mode - darker for better contrast
    })

    /// Diff editor gutter text color
    static let diffEditorGutter = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "808080")  // Dark mode
            : NSColor(hex: "8A9199")  // Light mode - ayu gutter (40% of #828E9F)
    })

    /// Diff editor gutter separator color - explicit hex values to avoid catalog color component access crashes
    static let diffEditorGutterSeparator = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.2)  // Dark mode - transparent white
            : NSColor(hex: "C6C6C8")  // Light mode - separator equivalent
    })

    /// Diff editor gutter background color - solid background behind line numbers
    static let diffEditorGutterBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "141416")  // Dark mode - slightly darker than editor bg
            : NSColor(hex: "F5F5F5")  // Light mode - slightly darker than editor bg
    })

    /// Diff editor added line background
    static let diffEditorAddedBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "6CBF43").withAlphaComponent(0.15)  // Dark mode - green with alpha for smooth blending
            : NSColor(hex: "6CBF43").withAlphaComponent(0.12)  // Light mode - ayu added with alpha
    })

    /// Diff editor removed line background
    static let diffEditorRemovedBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "FF7383").withAlphaComponent(0.15)  // Dark mode - red with alpha for smooth blending
            : NSColor(hex: "FF7383").withAlphaComponent(0.12)  // Light mode - ayu removed with alpha
    })

    /// Diff editor character-level highlight
    static let diffEditorHighlight = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "FFFF00").withAlphaComponent(0.3)  // Dark mode - yellow
            : NSColor(hex: "FFE294").withAlphaComponent(0.6)  // Light mode - ayu search highlight
    })

    /// Diff editor selection color
    static let diffEditorSelection = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "4D80CC").withAlphaComponent(0.4)  // Dark mode - blue
            : NSColor(hex: "035BD6").withAlphaComponent(0.15)  // Light mode - ayu selection
    })

    /// Diff editor fold indicator background
    static let diffEditorFold = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "4D4D66").withAlphaComponent(0.5)  // Dark mode
            : NSColor(hex: "828E9F").withAlphaComponent(0.15)  // Light mode - ayu muted
    })

    /// Diff editor file header background
    static let diffEditorFileHeaderBg = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1F1F1F")  // Dark mode
            : NSColor(hex: "F0F0F2")  // Light mode - slightly darker than bg
    })

    /// Diff editor file header text
    static let diffEditorFileHeaderText = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "D9D9D9")  // Dark mode
            : NSColor(hex: "24292E")  // Light mode - darker for better contrast
    })

    /// Diff section header background (SwiftUI header in TrajectoryView)
    static let diffSectionHeaderBg = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "26262E")  // Dark mode
            : NSColor(hex: "E8E8ED")  // Light mode
    }))

    /// Diff section background (SwiftUI section in TrajectoryView)
    static let diffSectionBg = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1A1A1C")  // Dark mode
            : NSColor(hex: "FFFFFF")  // Light mode
    }))

    /// Diff section border (SwiftUI border in TrajectoryView)
    static let diffSectionBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "333333")  // Dark mode
            : NSColor(hex: "D1D1D6")  // Light mode
    }))

    /// Diff section border for Metal rendering (NSColor version)
    static let diffEditorSectionBorder = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "333333")  // Dark mode
            : NSColor(hex: "D1D1D6")  // Light mode
    })

    /// Diff editor modified indicator (M)
    static let diffEditorModifiedIndicator = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "F2CC60")  // Dark mode - orange/yellow
            : NSColor(hex: "478ACC")  // Light mode - ayu modified (blue)
    })

    /// Diff editor added text color (for stats like +10)
    static let diffEditorAddedText = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "80f796")  // Dark mode - matches linesAdded
            : NSColor(hex: "129615")  // Light mode - matches linesAdded
    })

    /// Diff editor removed text color (for stats like -5)
    static let diffEditorRemovedText = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "ff6767")  // Dark mode - matches linesRemoved
            : NSColor(hex: "FF1008")  // Light mode - matches linesRemoved
    })

    // MARK: - Syntax Highlighting Colors (ayu-theme based, +35% saturation for light mode)

    /// Syntax: keyword color
    static let syntaxKeyword = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "A58FE8")  // Dark mode - purple
            : NSColor(hex: "F04D08")  // Light mode - ayu keyword +35% saturation
    })

    /// Syntax: string color
    static let syntaxString = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "6DDC7E")  // Dark mode - green
            : NSColor(hex: "729800")  // Light mode - ayu string (already max saturation)
    })

    /// Syntax: comment color
    static let syntaxComment = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "72C1F7")  // Dark mode - blue
            : NSColor(hex: "656A70")  // Light mode - ayu comment +15% saturation
    })

    /// Syntax: function color
    static let syntaxFunction = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "ED72F1")  // Dark mode - pink
            : NSColor(hex: "CE8B00")  // Light mode - ayu func (already max saturation)
    })

    /// Syntax: type color
    static let syntaxType = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "ED72F1")  // Dark mode - pink
            : NSColor(hex: "0B85E8")  // Light mode - ayu entity +35% saturation
    })

    /// Syntax: variable color
    static let syntaxVariable = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "FFE5E5")  // Dark mode - light pink/white
            : NSColor(hex: "424C58")  // Light mode - ayu fg +35% saturation
    })

    /// Syntax: number/boolean color
    static let syntaxNumber = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "F5C686")  // Dark mode - orange
            : NSColor(hex: "9050C8")  // Light mode - ayu constant +35% saturation
    })

    /// Syntax: operator color
    static let syntaxOperator = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "F5C686")  // Dark mode - orange
            : NSColor(hex: "E85E30")  // Light mode - ayu operator +35% saturation
    })

    /// Syntax: tag color (for HTML/XML)
    static let syntaxTag = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "72C1F7")  // Dark mode - blue
            : NSColor(hex: "28A0CC")  // Light mode - ayu tag +35% saturation
    })

    /// Syntax: regexp color
    static let syntaxRegexp = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "6DDC7E")  // Dark mode - green
            : NSColor(hex: "20B890")  // Light mode - ayu regexp +35% saturation
    })

    /// Syntax: special/markup color
    static let syntaxSpecial = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "F5C686")  // Dark mode - orange
            : NSColor(hex: "E83C3C")  // Light mode - ayu markup +35% saturation
    })

    // MARK: - Separator/Border Colors

    /// Separator line color - uses macOS semantic color that adapts to light/dark mode
    static let separator = Color(nsColor: .separatorColor)

    /// Border color for inputs and cards - uses macOS semantic color that adapts to light/dark mode
    static let border = Color(nsColor: .separatorColor)

    // MARK: - Conflict Badge Colors (Unified Yellow/Amber)

    /// Yellow/amber background for conflict badges and warnings
    static let conflictBadgeBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "F5A623")  // Dark mode - amber
            : NSColor(hex: "F5A623")  // Light mode - amber
    }))

    /// Text color for conflict badges (dark for contrast on yellow)
    static let conflictBadgeText = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "1A1A1A")  // Dark mode - dark text
            : NSColor(hex: "1A1A1A")  // Light mode - dark text
    }))

    /// Border color for conflict badges
    static let conflictBadgeBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "D4910E")  // Dark mode - darker amber
            : NSColor(hex: "D4910E")  // Light mode - darker amber
    }))
}

// MARK: - Helper Extensions

/// NSColor extension for hex color initialization
extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0) // Default black
        }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

/// SwiftUI Color extension for hex color initialization (kept for backward compatibility)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0) // Default black
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
