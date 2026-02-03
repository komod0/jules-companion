import SwiftUI

// NB: Assumes AppColors struct is defined elsewhere

enum FlashMessageType {
    case success
    case error
    case warning
    case info

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .success: return AppColors.accent // Use accent purple
        case .error: return Color(hex: "F4A4DB") // Use pink for errors
        case .warning: return Color(hex: "F4A4DB") // Use pink for warnings
        case .info: return AppColors.accent // Use accent purple
        }
    }

    var foregroundColor: Color {
        switch self {
        case .success, .info:
            return Color.white // White text on purple background
        case .error, .warning:
            return AppColors.backgroundDark // Dark text on pink background
        }
    }
}
