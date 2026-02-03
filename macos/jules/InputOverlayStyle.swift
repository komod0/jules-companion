//
//  InputOverlayStyle.swift
//  jules
//
//  Unified styling for input overlays (autocomplete, attachments, etc.)
//

import SwiftUI

/// A view modifier that applies consistent overlay styling
struct InputOverlayStyleModifier: ViewModifier {
    let cornerRadius: CGFloat
    let useMaterial: Bool
    @Environment(\.colorScheme) private var colorScheme

    // Glass-style border colors
    private var outerBorderColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.5)
            : Color.black.opacity(0.2)
    }

    private var innerBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : Color.white.opacity(0.6)
    }

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(
                Group {
                    if useMaterial {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.thickMaterial)
                            .overlay(
                                AppColors.background
                                    .opacity(0.4)
                                    .blendMode(.overlay)
                                    .allowsHitTesting(false)
                                    .cornerRadius(cornerRadius)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(AppColors.backgroundSecondary.opacity(0.6))
                    }
                }
            )
            // Inner light border (highlight effect)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius - 1)
                    .strokeBorder(innerBorderColor, lineWidth: 1)
                    .padding(1)
            )
            // Outer dark border
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(outerBorderColor, lineWidth: 1)
            )
    }
}

extension View {
    /// Applies unified input overlay styling
    /// - Parameters:
    ///   - cornerRadius: Corner radius (default: 8)
    ///   - useMaterial: Whether to use material background for dropdowns (default: false)
    func inputOverlayStyle(cornerRadius: CGFloat = 8, useMaterial: Bool = false) -> some View {
        modifier(InputOverlayStyleModifier(cornerRadius: cornerRadius, useMaterial: useMaterial))
    }
}

// MARK: - Preview

#if DEBUG
struct InputOverlayStyle_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Material style (for dropdowns)
            HStack {
                Text("Material overlay style")
                    .padding()
            }
            .inputOverlayStyle(cornerRadius: 8, useMaterial: true)

            // Non-material style (for attachments)
            HStack {
                Text("Standard overlay style")
                    .padding()
            }
            .inputOverlayStyle(cornerRadius: 8, useMaterial: false)
        }
        .padding()
        .background(AppColors.background)
    }
}
#endif
