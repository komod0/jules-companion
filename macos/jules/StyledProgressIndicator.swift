import SwiftUI

/// A styled progress indicator that matches the StickyStatusView appearance.
/// Positioned in the top right corner with the same height and background material.
struct StyledProgressIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        .background(Rectangle().fill(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A container view that positions a styled progress indicator in the top right corner.
/// Use this as a safeAreaInset overlay similar to StickyStatusView.
struct TopRightProgressOverlay: View {
    var body: some View {
        HStack {
            Spacer()
            StyledProgressIndicator()
        }
        .padding(.trailing, 16)
        .padding(.top, 12)
    }
}
