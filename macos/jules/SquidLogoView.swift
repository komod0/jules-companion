import SwiftUI
import Lottie


struct SquidLogoView: NSViewRepresentable {
    let accent = LottieColor(r: 178.0/255.0, g: 163.0/255.0, b: 1.0, a: 1.0)
    var loopMode: LottieLoopMode = .loop
    var isPlaying: Bool = true

    func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        let lottieView = LottieAnimationView(name: "julesLottieLogo_V9")

        lottieView.loopMode = loopMode
        lottieView.contentMode = .scaleAspectFit
        lottieView.translatesAutoresizingMaskIntoConstraints = false
        
        lottieView.setValueProvider(
            ColorValueProvider(accent),
            keypath: AnimationKeypath(keypath: "**.Color")
        )

        containerView.addSubview(lottieView)

        // Add constraints to make the Lottie view fill the container while maintaining aspect ratio
        NSLayoutConstraint.activate([
            lottieView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            lottieView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            lottieView.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor),
            lottieView.heightAnchor.constraint(lessThanOrEqualTo: containerView.heightAnchor),
            lottieView.widthAnchor.constraint(equalTo: lottieView.heightAnchor, multiplier: 1.0)
        ])

        // Set priority to allow the view to shrink
        lottieView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lottieView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        if isPlaying {
            lottieView.play()
        }

        // Store the lottie view in the container's identifier for later access
        containerView.identifier = NSUserInterfaceItemIdentifier("SquidLogoContainer")
        context.coordinator.lottieView = lottieView

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let lottieView = context.coordinator.lottieView else { return }

        if isPlaying {
            if !lottieView.isAnimationPlaying {
                lottieView.play()
            }
        } else {
            lottieView.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lottieView: LottieAnimationView?
    }
}
