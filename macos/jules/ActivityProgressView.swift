import SwiftUI

struct ActivityProgressView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared
    let session: Session

    // Phrases for different states
    private static let planningPhrases = [
        "Planning...",
        "Researching...",
        "Formulating...",
        "Exploring...",
        "Strategizing...",
        "Diving deep into your code...",
        "Adjusting the ballast tanks...",
        "Analyzing the strata...",
        "Illuminating the abyss...",
        "Checking the hermetic seals...",
        "Reviewing the ship's log...",
        "Investigating...",
        "Checking ink reserves...",
        "Dead reckoning...",
        "Triangulating...",
        "Waiting for the tide...",
        "Setting the course..."
    ]

    private static let inProgressPhrases = [
        "Working...",
        "Running...",
        "Darting...",
        "Writing...",
        "Coding...",
        "Debugging...",
        "Fixing...",
        "Propelling...",
        "Firing the harpoon...",
        "Scrubbing the deck...",
        "Pressurizing the hull...",
        "Inking the solution...",
        "Refilling the ink sacs...",
        "Scuttling bugs...",
        "Righting the ship...",
        "Grappling bugs...",
        "Navigating the depths...",
    ]

    // State for phrase rotation and typewriter animation
    @State private var currentPhraseIndex: Int = 0
    @State private var displayedCharacterCount: Int = 0
    @State private var targetPhrase: String = ""  // The phrase currently being typed
    @State private var phraseTimer: Timer?
    @State private var typewriterTimer: Timer?
    @State private var lastState: SessionState?

    /// The current phrase based on session state
    private var currentPhrase: String {
        let phrases = phrasesForCurrentState
        guard !phrases.isEmpty else { return "" }
        return phrases[currentPhraseIndex % phrases.count]
    }

    /// Get the appropriate phrases array for the current state
    private var phrasesForCurrentState: [String] {
        switch session.state {
        case .planning, .queued:
            return Self.planningPhrases
        case .inProgress, .awaitingPlanApproval, .awaitingUserFeedback, .paused:
            return Self.inProgressPhrases
        default:
            return []
        }
    }

    /// The text to display with typewriter effect
    private var displayedText: String {
        let endIndex = min(displayedCharacterCount, targetPhrase.count)
        return String(targetPhrase.prefix(endIndex))
    }

    /// Whether the loader should be animating (not completed/failed)
    private var isLoading: Bool {
        !session.state.isTerminal
    }

    /// Whether this is a completed state (includes completedUnknown)
    private var isCompletedState: Bool {
        session.state == .completed || session.state == .completedUnknown
    }

    /// Display text for the completion state
    private var completionText: String {
        switch session.state {
        case .completed: return "Completed"
        case .completedUnknown: return "Completed (Unknown)"
        case .failed: return "Failed"
        default: return session.state.displayName
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Animated loader (size scales with font)
            if isLoading {
                SquidLogoView()
                    .frame(width: 28, height: 28)
            } else {
                // Show a checkmark or X when completed/failed
                Image(systemName: isCompletedState ? session.state.iconName : "xmark.circle.fill")
                    .font(.system(size: fontSizeManager.activityFontSize + 1))
                    .foregroundColor(isCompletedState ? AppColors.accent : AppColors.linesRemoved)
                    .frame(width: fontSizeManager.activityFontSize + 5, height: fontSizeManager.activityFontSize + 5)
            }

            // Single line of bold text with typewriter animation
            Text(isLoading ? displayedText : completionText)
                .font(.system(size: fontSizeManager.activityFontSize, weight: .bold))
                .foregroundColor(isLoading ? AppColors.accent : (isCompletedState ? AppColors.accent : AppColors.linesRemoved))
                .frame(maxWidth: isLoading ? .infinity : nil, alignment: .leading)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, isCompletedState ? 12 : 0)
        .padding(.vertical, isCompletedState ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCompletedState ? AppColors.backgroundDark : Color.clear)
        )
        .onAppear {
            startAnimations()
        }
        .onDisappear {
            stopAllTimers()
        }
        .onChange(of: session.state) { newState in
            // Reset animations when state changes
            if newState != lastState {
                lastState = newState
                resetAndStartAnimations()
            }
        }
    }

    // MARK: - Animation Control

    private func startAnimations() {
        lastState = session.state
        guard isLoading else { return }

        // Pick a random starting phrase
        let phrases = phrasesForCurrentState
        guard !phrases.isEmpty else { return }
        currentPhraseIndex = Int.random(in: 0..<phrases.count)
        targetPhrase = phrases[currentPhraseIndex]
        // Start with 1 character visible immediately (not 0)
        displayedCharacterCount = 1

        startTypewriterAnimation()
        schedulePhraseChange()
    }

    private func resetAndStartAnimations() {
        stopAllTimers()

        guard isLoading else {
            displayedCharacterCount = 0
            targetPhrase = ""
            return
        }

        let phrases = phrasesForCurrentState
        guard !phrases.isEmpty else {
            displayedCharacterCount = 0
            targetPhrase = ""
            return
        }
        currentPhraseIndex = Int.random(in: 0..<phrases.count)
        targetPhrase = phrases[currentPhraseIndex]
        // Start with 1 character visible immediately (not 0)
        displayedCharacterCount = 1

        startTypewriterAnimation()
        schedulePhraseChange()
    }

    private func startTypewriterAnimation() {
        typewriterTimer?.invalidate()

        // Capture the target phrase for this animation cycle
        let phraseToType = targetPhrase
        guard !phraseToType.isEmpty else { return }

        // Type each character with a slight delay
        let typeInterval: TimeInterval = 0.04 // 40ms per character

        typewriterTimer = Timer.scheduledTimer(withTimeInterval: typeInterval, repeats: true) { timer in
            // Only continue if we're still typing the same phrase
            guard self.targetPhrase == phraseToType else {
                timer.invalidate()
                return
            }

            if self.displayedCharacterCount < phraseToType.count {
                withAnimation(.easeOut(duration: 0.05)) {
                    self.displayedCharacterCount += 1
                }
            } else {
                timer.invalidate()
            }
        }
    }

    private func schedulePhraseChange() {
        phraseTimer?.invalidate()

        // Random interval between 4-7 seconds
        let interval = Double.random(in: 4.0...7.0)

        phraseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            self.changeToNextPhrase()
        }
    }

    private func changeToNextPhrase() {
        // Stop the current typewriter timer first to prevent race conditions
        typewriterTimer?.invalidate()
        typewriterTimer = nil

        let phrases = phrasesForCurrentState
        guard phrases.count > 1 else { return }

        // Pick a different random phrase
        var newIndex: Int
        repeat {
            newIndex = Int.random(in: 0..<phrases.count)
        } while newIndex == currentPhraseIndex

        // Update state synchronously (no animation wrapper for state that timer depends on)
        currentPhraseIndex = newIndex
        targetPhrase = phrases[newIndex]
        displayedCharacterCount = 1

        // Start typewriter for new phrase
        startTypewriterAnimation()

        // Schedule next phrase change
        schedulePhraseChange()
    }

    private func stopAllTimers() {
        phraseTimer?.invalidate()
        phraseTimer = nil
        typewriterTimer?.invalidate()
        typewriterTimer = nil
    }
}
