import SwiftUI

struct StatusIconView: View {
    let state: SessionState

    /// Whether to use animated pulsing circle for active states
    private var shouldShowPulsingCircle: Bool {
        state == .inProgress || state == .planning
    }

    var body: some View {
        if shouldShowPulsingCircle {
            PulsingCircleView(size: 16, color: AppColors.accent)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Status: \(state.displayName)")
        } else {
            Image(systemName: state.iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(state.color)
                .accessibilityLabel("Status: \(state.displayName)")
        }
    }
}
