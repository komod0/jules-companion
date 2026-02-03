import SwiftUI
import AppKit

/// A unified message input view that handles both:
/// - Creating new sessions (when session is nil)
/// - Sending messages to existing sessions (when session is provided)
struct UnifiedMessageInputView: View {
    @EnvironmentObject var dataManager: DataManager
    // PERFORMANCE: Don't observe FontSizeManager - font size changes are rare and we don't want
    // to trigger re-renders during typing. Read the value once when the view appears.
    @State private var cachedFontSize: CGFloat = FontSizeManager.defaultActivityFontSize
    // PERFORMANCE: Use @ObservedObject for singleton, not @StateObject (which creates wrapper overhead)
    @ObservedObject private var autocompleteManager = FilenameAutocompleteManager.shared

    /// The session to send messages to. If nil, operates in "create session" mode.
    let session: Session?

    /// Unique identifier for this view's autocomplete ownership.
    /// Uses session ID to differentiate between different session views.
    private var viewOwnerId: String {
        if let sessionId = session?.id {
            return "UnifiedMessageInputView-\(sessionId)"
        }
        return "UnifiedMessageInputView-create"
    }

    /// Binding for message text - allows parent to control the text
    @Binding var messageText: String

    /// Binding for attachment content
    @Binding var attachmentContent: String?

    /// Binding for image attachment
    @Binding var imageAttachment: NSImage?

    /// Callback when a session is successfully created (for create mode)
    var onSessionCreated: (() -> Void)?

    // State for source picker refresh
    @State private var hasAttemptedSourceRefresh: Bool = false
    @State private var sourcePickerDropdown: SourcePickerDropdown = .none

    /// Whether we're in "create session" mode
    private var isCreateMode: Bool {
        session == nil
    }

    /// Whether the submit button should be disabled
    private var isSubmitDisabled: Bool {
        // Fast path: check for attachments first (O(1))
        // Then use contains() instead of trimmingCharacters() to avoid string allocation
        // contains() short-circuits on first non-whitespace character
        let hasTextContent = !messageText.isEmpty && messageText.contains { !$0.isWhitespace && !$0.isNewline }
        let hasContent = hasTextContent || attachmentContent != nil || imageAttachment != nil

        if isCreateMode {
            // In create mode, also need source and branch selected
            let hasSource = dataManager.selectedSourceId != nil
            let hasBranch = dataManager.selectedBranchName != nil
            return !hasContent || !hasSource || !hasBranch
        } else {
            return !hasContent
        }
    }

    /// Placeholder text based on mode
    private var placeholderText: String {
        isCreateMode ? "What should Jules work on?" : "Enter your message"
    }

    /// Whether we're currently submitting
    private var isSubmitting: Bool {
        isCreateMode ? dataManager.isCreatingSession : dataManager.isSendingMessage
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                // Autocomplete menu (appears ABOVE the text editor in SessionsController)
                FilenameAutocompleteMenuView(
                    autocompleteManager: autocompleteManager,
                    onSelect: { filename in
                        replaceCurrentWordWithFilename(filename)
                    },
                    positionAbove: true,
                    viewOwnerId: viewOwnerId
                )

                // Text input area (with inline source picker in create mode)
                textInputView

                // Attachment indicators
                attachmentIndicatorsView
            }

            // Source picker dropdown overlays on top of content below (only in create mode)
            if isCreateMode && sourcePickerDropdown != .none {
                SourcePickerDropdownView(activeDropdown: $sourcePickerDropdown)
                    .padding(.top, 88) // Position below text editor
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: isCreateMode)
        .onChange(of: dataManager.selectedSourceId) { newSourceId in
            // Update autocomplete manager when source changes (picker selection in create mode)
            if let sourceId = newSourceId {
                let localPath = getLocalPath(for: sourceId)
                autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
                autocompleteManager.setActiveRepository(sourceId)
            } else {
                autocompleteManager.setActiveRepository(nil)
            }
        }
        .onChange(of: session?.sourceContext?.source) { newSource in
            // For existing sessions, use the session's source context
            if let sourceId = newSource {
                let localPath = getLocalPath(for: sourceId)
                autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
                autocompleteManager.setActiveRepository(sourceId)

                // Also populate cache from session's diffs if available
                if let diffs = session?.latestDiffs {
                    autocompleteManager.addFilenamesFromPatches(diffs, for: sourceId)
                }
            }
        }
        .onAppear {
            // PERFORMANCE: Cache font size once on appear - avoids reactive FontSizeManager observation
            cachedFontSize = FontSizeManager.shared.activityFontSize
            setupAutocomplete()
        }
        .onDisappear {
            // Close any open dropdown when view disappears
            sourcePickerDropdown = .none
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeCenteredMenu)) { _ in
            // Close dropdown when centered menu closes
            sourcePickerDropdown = .none
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuDidOpen)) { _ in
            // Close dropdown when menu reopens (ensures clean state)
            sourcePickerDropdown = .none
        }
    }

    // MARK: - Source Pickers

    private var sourcePickersView: some View {
        InlineSourcePickerView(activeDropdown: $sourcePickerDropdown)
            .onAppear {
                if dataManager.sources.isEmpty && !hasAttemptedSourceRefresh {
                    hasAttemptedSourceRefresh = true
                    dataManager.ensureSourcesLoaded()
                }
            }
            .onChange(of: dataManager.sources) { newSources in
                if !newSources.isEmpty {
                    hasAttemptedSourceRefresh = false
                }
            }
    }

    // MARK: - Text Input

    private var textInputView: some View {
        ZStack(alignment: .topLeading) {
            // PERFORMANCE: Using SimpleTextEditorContainer with TextKit 2
            // No pattern highlighting, decoupled from DataManager
            // Uses transparent background to support NSVisualEffectView vibrancy
            SimpleTextEditorContainer(
                text: $messageText,
                baseFont: .systemFont(ofSize: cachedFontSize, weight: .regular),
                baseTextColor: AppColors.textPrimary.toNSColor(),
                backgroundColor: .clear,
                onSubmit: {
                    guard !isSubmitDisabled else { return }
                    submitAction()
                },
                isSubmitting: isSubmitting,
                submitDisabled: isSubmitDisabled,
                onAttachment: { content in
                    attachmentContent = content
                },
                onImageAttachment: { image in
                    imageAttachment = image
                },
                autoExpand: true,
                minHeight: 80,
                maxHeight: 250,
                contentPadding: 11,
                onAutocompleteRequest: { prefix in
                    autocompleteManager.setViewOwner(viewOwnerId)
                    autocompleteManager.updateSuggestions(for: prefix)
                },
                onTextChange: { prefix in
                    autocompleteManager.setViewOwner(viewOwnerId)
                    autocompleteManager.updateSuggestions(for: prefix)
                },
                bottomLeadingContent: {
                    // Source picker at bottom-left (only in create mode)
                    if isCreateMode {
                        sourcePickersView
                    }
                }
            )

            if messageText.isEmpty && attachmentContent == nil && imageAttachment == nil {
                Text(placeholderText)
                    .foregroundColor(AppColors.textSecondary.opacity(0.6))
                    .padding(.leading, 6 + 8)
                    .padding(.top, 6 + 5)
                    .allowsHitTesting(false)
                    .font(.system(size: cachedFontSize))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
    }

    // MARK: - Attachment Indicators

    @ViewBuilder
    private var attachmentIndicatorsView: some View {
        if let content = attachmentContent {
            AttachmentIndicatorView(
                onRemove: {
                    attachmentContent = nil
                },
                lineCount: content.components(separatedBy: "\n").count
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.default, value: attachmentContent != nil)
        }

        if let image = imageAttachment {
            ImageAttachmentIndicatorView(
                image: image,
                onRemove: {
                    imageAttachment = nil
                },
                onEdit: { annotatedImage in
                    // Replace the image attachment with the annotated version
                    imageAttachment = annotatedImage
                }
            )
            .id(ObjectIdentifier(image)) // Force view recreation when image changes
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.default, value: imageAttachment != nil)
        }
    }

    // MARK: - Actions

    private func submitAction() {
        if isCreateMode {
            createSession()
        } else {
            sendMessage()
        }
    }

    private func createSession() {
        // Store current text in dataManager for session creation
        dataManager.promptText = messageText
        if let attachment = attachmentContent {
            dataManager.setDraftAttachment(content: attachment)
        }

        // Create the session
        dataManager.createSession()

        // Clear local state
        messageText = ""
        attachmentContent = nil
        imageAttachment = nil

        // Notify parent
        onSessionCreated?()
    }

    private func sendMessage() {
        guard let session = session else { return }

        var messageToSend = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attachment = attachmentContent {
            if !messageToSend.isEmpty {
                messageToSend += "\n\n---\n\n"
            }
            messageToSend += "```\n\(attachment)\n```"
        }

        guard !messageToSend.isEmpty else { return }

        dataManager.sendMessage(session: session, message: messageToSend)

        // Clear local state
        messageText = ""
        attachmentContent = nil
        imageAttachment = nil
    }

    // MARK: - Autocomplete

    /// Set up autocomplete for the current context
    private func setupAutocomplete() {
        if let session = session, let sourceId = session.sourceContext?.source {
            // For existing sessions, use the session's source context
            let localPath = getLocalPath(for: sourceId)
            autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
            autocompleteManager.setActiveRepository(sourceId)

            // Populate cache from session's diffs
            if let diffs = session.latestDiffs {
                autocompleteManager.addFilenamesFromPatches(diffs, for: sourceId)
            }
        } else if let sourceId = dataManager.selectedSourceId {
            // For create mode, use the selected source
            let localPath = getLocalPath(for: sourceId)
            autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
            autocompleteManager.setActiveRepository(sourceId)
        }
    }

    /// Get the local path for a source from UserDefaults
    private func getLocalPath(for sourceId: String) -> String? {
        let paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String]
        return paths?[sourceId]
    }

    /// Replace the current word in the text with the selected filename
    private func replaceCurrentWordWithFilename(_ filename: String) {
        let text = messageText

        // Use the stored word range from when autocomplete was triggered
        // This ensures we replace the correct word at the cursor position, not just the end of text
        if let pendingRange = autocompleteManager.pendingWordRange {
            let nsText = text as NSString

            // Validate the range is still valid for current text
            if pendingRange.location + pendingRange.length <= nsText.length {
                let beforeWord = nsText.substring(to: pendingRange.location)
                let afterWord = nsText.substring(from: pendingRange.location + pendingRange.length)
                let newText = beforeWord + filename + afterWord
                messageText = newText

                // Set cursor position to end of inserted filename
                autocompleteManager.pendingCursorPosition = pendingRange.location + filename.utf16.count
                autocompleteManager.pendingWordRange = nil
                autocompleteManager.clearSuggestions()
                return
            }
        }

        // Fallback: Find the last word-like sequence at the end of the text
        // This handles edge cases where the stored range is invalid
        var wordStart = text.endIndex
        let startIndex = text.startIndex

        while wordStart > startIndex {
            let prevIndex = text.index(before: wordStart)
            let char = text[prevIndex]

            if char.isLetter || char.isNumber || char == "_" {
                wordStart = prevIndex
            } else {
                break
            }
        }

        // Replace the word with the filename
        let prefix = String(text[..<wordStart])
        let newText = prefix + filename
        messageText = newText

        // Set pending cursor position to end of new text so SimpleTextEditor positions cursor correctly
        autocompleteManager.pendingCursorPosition = newText.utf16.count
        autocompleteManager.pendingWordRange = nil

        // Clear autocomplete
        autocompleteManager.clearSuggestions()
    }
}

// MARK: - Convenience initializer for ActivityView compatibility

extension UnifiedMessageInputView {
    /// Convenience initializer for use in ActivityView (message sending mode)
    init(
        session: Session,
        messageText: Binding<String>,
        attachmentContent: Binding<String?>,
        imageAttachment: Binding<NSImage?>
    ) {
        self.session = session
        self._messageText = messageText
        self._attachmentContent = attachmentContent
        self._imageAttachment = imageAttachment
        self.onSessionCreated = nil
    }

    /// Convenience initializer for create session mode
    init(
        messageText: Binding<String>,
        attachmentContent: Binding<String?>,
        imageAttachment: Binding<NSImage?>,
        onSessionCreated: (() -> Void)? = nil
    ) {
        self.session = nil
        self._messageText = messageText
        self._attachmentContent = attachmentContent
        self._imageAttachment = imageAttachment
        self.onSessionCreated = onSessionCreated
    }
}
