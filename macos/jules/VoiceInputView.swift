import SwiftUI
import Combine

/// Mode for the voice input panel
@available(macOS 26.0, *)
enum VoiceInputMode {
    /// Waiting for user to grant permissions
    case requestingPermissions
    /// Actively transcribing - will auto-post when speech ends
    case transcribing
    /// User clicked to edit - manual post required
    case editing
    /// Posted and closing
    case posting
}

/// View for voice input panel
@available(macOS 26.0, *)
struct VoiceInputView: View {
    @EnvironmentObject var dataManager: DataManager
    @ObservedObject var speechManager = SpeechTranscriptionManager.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Callback when the panel should close
    var onClose: () -> Void
    /// Callback when a session should be posted
    var onPost: (String, Source?) -> Void

    // State
    @State private var mode: VoiceInputMode = .requestingPermissions
    @State private var editableText: String = ""
    @State private var matchedSource: Source?
    @State private var sourceMatchConfidence: Double = 0.0
    @State private var extractedRepoMention: String?
    @State private var isHoveringMic: Bool = false
    @State private var isHoveringPost: Bool = false
    @State private var audioErrorMessage: String?
    @State private var sourceMatchAnimating: Bool = false
    @State private var hasTriggeredAutoSubmit: Bool = false
    @State private var textProcessingTask: Task<Void, Never>?

    /// Words that trigger automatic submission when spoken at the end
    private let autoSubmitTriggerWords = ["post", "submit", "send", "go"]

    // For editing text
    @FocusState private var isTextFieldFocused: Bool

    // UI Constants
    private let panelWidth: CGFloat = 500
    private let panelMinHeight: CGFloat = 120

    private var textColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.1, green: 0.1, blue: 0.15)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.6) : Color.gray
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            VStack(alignment: .leading, spacing: 12) {
                // Transcribed/editable text
                textContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                // Source indicator if matched
                if let source = matchedSource {
                    sourceIndicator(source: source)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 16)

                // Bottom controls
                HStack {
                    // Status indicator
                    statusIndicator

                    Spacer()

                    // Controls based on mode
                    bottomControls
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(width: panelWidth, alignment: .top)
        .frame(minHeight: panelMinHeight, maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true) // Allow vertical growth based on content
        .unifiedBackground(material: .popover, tintOverlayOpacity: 0.3, cornerRadius: 12)
        .onAppear {
            setupAnimations()
            startTranscribing()
        }
        .onDisappear {
            cleanup()
        }
        .onChange(of: speechManager.transcribedText) { _, newText in
            // Cancel any pending processing task and debounce
            textProcessingTask?.cancel()
            textProcessingTask = Task { @MainActor in
                // Small delay to coalesce rapid updates
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }

                // Update source match as transcription changes
                updateSourceMatch(for: newText)
                // Check for auto-submit trigger words
                checkForAutoSubmitTrigger(in: newText)
            }
        }
    }

    // MARK: - Text Content

    @ViewBuilder
    private var textContent: some View {
        if mode == .requestingPermissions {
            // Show permission request message
            VStack(alignment: .leading, spacing: 8) {
                Text("Grant permissions to use voice input")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                Text("Please allow microphone and speech recognition access when prompted.")
                    .font(.system(size: 13))
                    .foregroundColor(secondaryTextColor.opacity(0.7))
            }
        } else if mode == .editing {
            // Editable text field
            VStack(alignment: .leading, spacing: 8) {
                TextField("Type your request...", text: $editableText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(textColor)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        isTextFieldFocused = true
                    }
                    .onSubmit {
                        postSession()
                    }

                // Show error message if there was an audio issue
                if let errorMessage = audioErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(2)
                }
            }
        } else if speechManager.transcribedText.isEmpty {
            // Placeholder or error message
            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage = audioErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(3)
                } else {
                    Text("Listening...")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                switchToEditMode()
            }
        } else {
            // Display transcribed text (clickable to edit) - live updates as you speak
            // Text wraps and grows vertically as more text is added
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(speechManager.transcribedText)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("transcribedText")
                }
                .frame(maxHeight: 200) // Cap maximum height to prevent excessive growth
                .onChange(of: speechManager.transcribedText) { _, _ in
                    // Auto-scroll to bottom as text grows
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("transcribedText", anchor: .bottom)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                switchToEditMode()
            }
        }
    }

    // MARK: - Source Indicator

    @ViewBuilder
    private func sourceIndicator(source: Source) -> some View {
        let sourceName = SourceMatcher.shared.normalizeSourceName(source)
        HStack(spacing: 8) {
            // Animated checkmark icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
                .scaleEffect(sourceMatchAnimating ? 1.2 : 1.0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.accent)

                    Text(sourceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.accent)
                }

                // Show what was detected if different from source name
                if let mention = extractedRepoMention,
                   mention.lowercased() != sourceName.lowercased() {
                    Text("detected: \"\(mention)\"")
                        .font(.system(size: 10))
                        .foregroundColor(secondaryTextColor)
                }
            }

            if sourceMatchConfidence > 0 {
                Text("\(Int(sourceMatchConfidence * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppColors.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(AppColors.accent.opacity(0.3), lineWidth: 1)
                )
        )
        .scaleEffect(sourceMatchAnimating ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: sourceMatchAnimating)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        HStack(spacing: 8) {
            // Transcribing indicator dot
            if mode == .transcribing && speechManager.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(Color.red.opacity(0.5))
                            .frame(width: 16, height: 16)
                            .scaleEffect(isTranscribingPulse ? 1.5 : 1.0)
                            .opacity(isTranscribingPulse ? 0 : 0.5)
                    )

                Text("Transcribing")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
            } else if mode == .editing {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)

                Text("Editing")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
            } else if mode == .posting {
                ProgressView()
                    .controlSize(.small)

                Text("Posting...")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
            } else if mode == .requestingPermissions {
                ProgressView()
                    .controlSize(.small)

                Text("Waiting for permissions...")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
            }
        }
    }

    @State private var isTranscribingPulse = false

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        HStack(spacing: 12) {
            // Microphone toggle button
            Button(action: toggleTranscribing) {
                Image(systemName: speechManager.isRecording ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(speechManager.isRecording ? .white : secondaryTextColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(speechManager.isRecording ? Color.red : Color.clear)
                            .overlay(
                                Circle()
                                    .strokeBorder(secondaryTextColor.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringMic = $0 }
            .scaleEffect(isHoveringMic ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHoveringMic)

            // Post button (only in edit mode or when text is available)
            if mode == .editing || (!speechManager.transcribedText.isEmpty && mode != .posting) {
                Button(action: postSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                        Text("Post")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(AppColors.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringPost = $0 }
                .scaleEffect(isHoveringPost ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHoveringPost)
            }
        }
    }

    // MARK: - Actions

    private func setupAnimations() {
        // Start pulse animation for transcribing indicator
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            isTranscribingPulse = true
        }
    }

    private func startTranscribing() {
        // Reset state for fresh transcription
        speechManager.clearTranscription()
        matchedSource = nil
        sourceMatchConfidence = 0.0
        audioErrorMessage = nil
        hasTriggeredAutoSubmit = false

        Task {
            // First check if permissions are already granted
            let permissionStatus = speechManager.checkPermissionStatus()
            if !permissionStatus.microphone || !permissionStatus.speechRecognition {
                // Need to request permissions - show waiting state
                mode = .requestingPermissions

                // Request permissions and wait for user response
                let granted = await speechManager.requestPermissions()
                guard granted else {
                    // User denied permissions
                    audioErrorMessage = speechManager.currentError?.localizedDescription ?? "Permissions required"
                    switchToEditMode()
                    return
                }
            }

            // Permissions granted, start recording
            mode = .transcribing

            do {
                try await speechManager.startRecording()
            } catch {
                if let speechError = error as? SpeechTranscriptionError {
                    print("Speech error: \(speechError.localizedDescription)")

                    // Show user-friendly error for audio system issues
                    switch speechError {
                    case .audioEngineFailure, .audioSessionSetupFailed:
                        audioErrorMessage = speechError.localizedDescription
                        // Force reset to clean up any stale state
                        speechManager.forceReset()
                    case .alreadyRecording:
                        // Force reset and try again
                        speechManager.forceReset()
                        // Brief delay before retry
                        try? await Task.sleep(for: .milliseconds(100))
                        do {
                            try await speechManager.startRecording()
                            audioErrorMessage = nil
                            return
                        } catch {
                            audioErrorMessage = "Unable to start recording. Please try again."
                        }
                    default:
                        audioErrorMessage = speechError.localizedDescription
                    }
                }
                // If we can't transcribe, switch to edit mode
                switchToEditMode()
            }
        }
    }

    private func toggleTranscribing() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        } else {
            resumeTranscribing()
        }
    }

    /// Resume transcribing without clearing existing text
    private func resumeTranscribing() {
        // Don't clear transcription - we want to accumulate text across sessions
        audioErrorMessage = nil
        hasTriggeredAutoSubmit = false

        Task {
            // First check if permissions are already granted
            let permissionStatus = speechManager.checkPermissionStatus()
            if !permissionStatus.microphone || !permissionStatus.speechRecognition {
                // Need to request permissions - show waiting state
                mode = .requestingPermissions

                // Request permissions and wait for user response
                let granted = await speechManager.requestPermissions()
                guard granted else {
                    // User denied permissions
                    audioErrorMessage = speechManager.currentError?.localizedDescription ?? "Permissions required"
                    switchToEditMode()
                    return
                }
            }

            // Permissions granted, start recording
            mode = .transcribing

            do {
                try await speechManager.startRecording()
            } catch {
                if let speechError = error as? SpeechTranscriptionError {
                    print("Speech error: \(speechError.localizedDescription)")

                    // Show user-friendly error for audio system issues
                    switch speechError {
                    case .audioEngineFailure, .audioSessionSetupFailed:
                        audioErrorMessage = speechError.localizedDescription
                        // Force reset to clean up any stale state
                        speechManager.forceReset()
                    case .alreadyRecording:
                        // Force reset and try again
                        speechManager.forceReset()
                        // Brief delay before retry
                        try? await Task.sleep(for: .milliseconds(100))
                        do {
                            try await speechManager.startRecording()
                            audioErrorMessage = nil
                            return
                        } catch {
                            audioErrorMessage = "Unable to start recording. Please try again."
                        }
                    default:
                        audioErrorMessage = speechError.localizedDescription
                    }
                }
                // If we can't transcribe, switch to edit mode
                switchToEditMode()
            }
        }
    }

    private func switchToEditMode() {
        // Stop transcribing when switching to edit
        speechManager.stopRecording()
        editableText = speechManager.transcribedText
        mode = .editing
    }

    private func updateSourceMatch(for text: String) {
        let result = SourceMatcher.shared.matchSource(from: text, availableSources: dataManager.sources)
        let previousSource = matchedSource
        matchedSource = result.matchedSource
        sourceMatchConfidence = result.confidence
        extractedRepoMention = result.extractedRepoMention

        // Animate when a new source is matched
        if result.matchedSource != nil && previousSource?.id != result.matchedSource?.id {
            sourceMatchAnimating = true
            // Reset animation state after a brief delay using Task to avoid layout recursion
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                sourceMatchAnimating = false
            }
        }
    }

    /// Check if the transcribed text ends with a trigger word to auto-submit
    private func checkForAutoSubmitTrigger(in text: String) {
        guard mode == .transcribing, !hasTriggeredAutoSubmit else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedText.isEmpty else { return }

        // Check if text ends with a trigger word
        for trigger in autoSubmitTriggerWords {
            if trimmedText.hasSuffix(trigger) {
                // Make sure it's a whole word (preceded by space or is the entire text)
                let beforeTrigger = trimmedText.dropLast(trigger.count)
                if beforeTrigger.isEmpty || beforeTrigger.last?.isWhitespace == true {
                    // Found a trigger word - remove it and submit
                    hasTriggeredAutoSubmit = true

                    // Remove the trigger word from the transcription
                    let cleanedText = removeTrailingTriggerWord(from: speechManager.transcribedText, trigger: trigger)
                    speechManager.setTranscription(cleanedText)

                    // Small delay to let UI update, then submit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.postSession()
                    }
                    return
                }
            }
        }
    }

    /// Remove the trigger word from the end of the text
    private func removeTrailingTriggerWord(from text: String, trigger: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = result.lowercased()

        if lowercased.hasSuffix(trigger) {
            result = String(result.dropLast(trigger.count))
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // Also remove trailing punctuation that might be left
            while result.last == "," || result.last == "." {
                result = String(result.dropLast())
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private func postSession() {
        guard mode != .posting else { return }

        // Capture current mode before changing it
        let wasEditing = mode == .editing
        mode = .posting
        speechManager.stopRecording()

        // Get the final text - use editableText if was editing, otherwise use transcribed text
        let finalText = wasEditing ? editableText : speechManager.transcribedText

        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onClose()
            return
        }

        // Match source and clean prompt
        let matchResult = SourceMatcher.shared.matchSource(from: finalText, availableSources: dataManager.sources)

        // Determine which source to use with fallback chain:
        // 1. Matched source from speech (if repo was mentioned)
        // 2. Currently selected source
        // 3. Last used source from UserDefaults
        // 4. First available source
        let sourceToUse: Source?
        if let matchedSource = matchResult.matchedSource {
            sourceToUse = matchedSource
        } else if let selectedId = dataManager.selectedSourceId,
                  let selectedSource = dataManager.sources.first(where: { $0.id == selectedId }) {
            sourceToUse = selectedSource
        } else if let lastUsedId = UserDefaults.standard.string(forKey: "lastUsedSourceId"),
                  let lastUsedSource = dataManager.sources.first(where: { $0.id == lastUsedId }) {
            sourceToUse = lastUsedSource
        } else {
            sourceToUse = dataManager.sources.first
        }

        // Use cleaned prompt if we matched a source, otherwise use full text
        let promptToUse = matchResult.matchedSource != nil ? matchResult.cleanedPrompt : finalText

        // Post via callback
        onPost(promptToUse, sourceToUse)
    }

    private func cleanup() {
        // Cancel any pending text processing
        textProcessingTask?.cancel()
        textProcessingTask = nil
        // Use forceReset to ensure complete cleanup even if audio system had errors
        speechManager.forceReset()
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VoiceInputView(
        onClose: {},
        onPost: { _, _ in }
    )
    .environmentObject(DataManager())
}
