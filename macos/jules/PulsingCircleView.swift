import SwiftUI

/// An animated pulsing circle that grows in and out continuously.
/// Used as a status indicator for inProgress and planning states.
struct PulsingCircleView: View {
    let size: CGFloat
    let color: Color

    /// Animation state: controls the scale of the circle
    @State private var scale: CGFloat = 0
    /// Animation state: controls the opacity for fade out effect
    @State private var opacity: Double = 1
    /// Tracks whether the view is visible and should be animating
    @State private var isAnimating: Bool = false

    /// Duration of one complete pulse cycle
    private let animationDuration: Double = 1.2

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                isAnimating = true
                startAnimation()
            }
            .onDisappear {
                isAnimating = false
            }
    }

    private func startAnimation() {
        // Don't start if view is not visible
        guard isAnimating else { return }

        // Reset to initial state
        scale = 0
        opacity = 1

        // Phase 1: Grow in from 0 to 1 (first half of animation)
        withAnimation(.easeOut(duration: animationDuration * 0.5)) {
            scale = 1
        }

        // Phase 2: Grow out from 1 to 1.5 while fading out (second half)
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration * 0.5) {
            guard isAnimating else { return }
            withAnimation(.easeIn(duration: animationDuration * 0.5)) {
                scale = 1.2
                opacity = 0
            }
        }

        // Loop: restart the animation
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
            startAnimation()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        // Different sizes to match the app's usage
        HStack(spacing: 20) {
            VStack {
                PulsingCircleView(size: 16, color: AppColors.accent)
                Text("16pt")
                    .font(.caption)
            }
            VStack {
                PulsingCircleView(size: 12, color: AppColors.accent)
                Text("12pt")
                    .font(.caption)
            }
            VStack {
                PulsingCircleView(size: 10, color: AppColors.accent)
                Text("10pt")
                    .font(.caption)
            }
        }
    }
    .padding(40)
    .background(AppColors.background)
}
