import SwiftUI
import AppKit

struct NewTaskFormView: View {
    @EnvironmentObject var dataManager: DataManager
    // Note: Using direct singleton access instead of @StateObject to avoid re-renders
    // when autocomplete state changes. Only FilenameAutocompleteMenuView observes the manager.
    private let autocompleteManager = FilenameAutocompleteManager.shared

    // Navigation callbacks - called when arrow keys are pressed
    var onDownArrow: (() -> Void)? = nil
    var onUpArrow: (() -> Void)? = nil
    // Enter override - if returns true, enter was handled by navigation; else fall through to submit
    var onEnterOverride: (() -> Bool)? = nil
    // Input focus callback - called when user starts typing or clicks in the text area
    var onInputFocus: (() -> Void)? = nil

    @State private var hasAttemptedSourceRefresh: Bool = false
    @State private var sourcePickerDropdown: SourcePickerDropdown = .none

    /// Unique identifier for this view's autocomplete ownership
    private let viewOwnerId = "NewTaskFormView"

    // MARK: - Local State for Text Editor
    // Using local state instead of direct DataManager binding dramatically reduces lag
    // because changes don't trigger objectWillChange.send() on DataManager,
    // avoiding cascade re-renders of all views observing DataManager
    @State private var localPromptText: String = ""
    @State private var localAttachmentContent: String? = nil
    @State private var localImageAttachment: NSImage? = nil

    private let horizontalPadding: CGFloat = 16
    private let interItemSpacing: CGFloat = 12

    /// Fast check for non-whitespace text content
    /// Uses contains() instead of trimmingCharacters() to avoid string allocation on every render
    private var hasTextContent: Bool {
        !localPromptText.isEmpty &&
        localPromptText.contains { !$0.isWhitespace && !$0.isNewline }
    }

    // MARK: - Body (broken up to help Swift type-checker)

    var body: some View {
        VStack(alignment: .leading, spacing: interItemSpacing) {
            textEditorStack
        }
        .padding(.horizontal, horizontalPadding)
        .onChange(of: dataManager.selectedSourceId) { newSourceId in
            handleSourceChange(newSourceId)
        }
        .onChange(of: dataManager.draftImageAttachment) { newImage in
            // Sync image attachment from DataManager (e.g., from screenshot hotkey)
            if let image = newImage, localImageAttachment == nil {
                localImageAttachment = image
                // Clear the DataManager's draft so it doesn't persist across sessions
                dataManager.clearDraftImageAttachment()
            }
        }
        .onAppear {
            #if DEBUG
            print("[NewTaskFormView] onAppear at \(CFAbsoluteTimeGetCurrent())")
            #endif
            setupAutocompleteOnAppear()
            // Check if there's a pending image attachment from DataManager
            if let image = dataManager.draftImageAttachment {
                localImageAttachment = image
                dataManager.clearDraftImageAttachment()
            }
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

    // MARK: - Extracted Subviews

    @ViewBuilder
    private var textEditorStack: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 5) {
                textEditorWithPlaceholder
                autocompleteMenu
                textAttachmentIndicator
                imageAttachmentIndicator
            }

            // Source picker dropdown overlays on top of content below
            if sourcePickerDropdown != .none {
                // Transparent backdrop to dismiss dropdown when clicking outside
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        sourcePickerDropdown = .none
                    }

                SourcePickerDropdownView(activeDropdown: $sourcePickerDropdown)
                    .padding(.top, 112) // Position below text editor
            }
        }
    }

    @ViewBuilder
    private var textEditorWithPlaceholder: some View {
        ZStack(alignment: .topLeading) {
            promptTextEditor
            placeholderText
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
    }

    @ViewBuilder
    private var promptTextEditor: some View {
        PatternHighlightTextEditorContainer(
            text: $localPromptText,
            baseFont: .systemFont(ofSize: 14, weight: .regular),
            baseTextColor: AppColors.textPrimary.toNSColor(),
            backgroundColor: .clear,
            onSubmit: {
                guard hasTextContent || localAttachmentContent != nil else { return }
                submitTask()
            },
            isSubmitting: dataManager.isCreatingSession,
            submitDisabled: !hasTextContent && localAttachmentContent == nil,
            onAttachment: { content in
                localAttachmentContent = content
            },
            onImageAttachment: { image in
                localImageAttachment = image
            },
            autoExpand: true,
            minHeight: 104,
            maxHeight: dataManager.isPopoverExpanded ? 224 : 184,
            contentPadding: 11,
            onAutocompleteRequest: { prefix in
                autocompleteManager.setViewOwner(viewOwnerId)
                autocompleteManager.updateSuggestions(for: prefix)
            },
            onTextChange: { prefix in
                autocompleteManager.setViewOwner(viewOwnerId)
                autocompleteManager.updateSuggestions(for: prefix)
            },
            onDownArrow: onDownArrow,
            onUpArrow: onUpArrow,
            onEnterOverride: onEnterOverride,
            onInputFocus: onInputFocus,
            bottomLeadingContent: {
                // Inline source picker buttons at bottom-left
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
        )
        .id("promptTextEditor")
    }

    @ViewBuilder
    private var placeholderText: some View {
        if localPromptText.isEmpty && localAttachmentContent == nil && localImageAttachment == nil {
            Text("What should Jules work on?")
                .foregroundColor(AppColors.textSecondary.opacity(0.6))
                .padding(.leading, 6 + 11)
                .padding(.top, 6 + 5)
                .allowsHitTesting(false)
                .font(.system(size: 14))
        }
    }

    @ViewBuilder
    private var autocompleteMenu: some View {
        FilenameAutocompleteMenuView(
            autocompleteManager: autocompleteManager,
            onSelect: { filename in
                replaceCurrentWordWithFilename(filename)
            },
            positionAbove: false,
            viewOwnerId: viewOwnerId
        )
    }

    @ViewBuilder
    private var textAttachmentIndicator: some View {
        if let content = localAttachmentContent {
            AttachmentIndicatorView(
                onRemove: {
                    localAttachmentContent = nil
                },
                lineCount: content.components(separatedBy: "\n").count
            )
            .padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.default, value: localAttachmentContent != nil)
        }
    }

    @ViewBuilder
    private var imageAttachmentIndicator: some View {
        if let image = localImageAttachment {
            ImageAttachmentIndicatorView(
                image: image,
                onRemove: {
                    localImageAttachment = nil
                },
                onEdit: { annotatedImage in
                    localImageAttachment = annotatedImage
                }
            )
            .id(ObjectIdentifier(image))
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

    // MARK: - Event Handlers

    private func handleSourceChange(_ newSourceId: String?) {
        #if DEBUG
        print("[NewTaskFormView] Source picker changed to: \(newSourceId ?? "nil")")
        #endif
        if let sourceId = newSourceId {
            let localPath = getLocalPath(for: sourceId)
            #if DEBUG
            print("[NewTaskFormView] Local path for \(sourceId): \(localPath ?? "nil")")
            #endif
            autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
            autocompleteManager.setActiveRepository(sourceId)
        } else {
            autocompleteManager.setActiveRepository(nil)
        }
    }

    private func setupAutocompleteOnAppear() {
        #if DEBUG
        print("[NewTaskFormView] onAppear - selectedSourceId: \(dataManager.selectedSourceId ?? "nil")")
        #endif
        if let sourceId = dataManager.selectedSourceId {
            let localPath = getLocalPath(for: sourceId)
            #if DEBUG
            print("[NewTaskFormView] Local path for \(sourceId): \(localPath ?? "nil")")
            #endif
            autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
            autocompleteManager.setActiveRepository(sourceId)
        }
    }

    // MARK: - Local Path Lookup

    /// Get the local path for a source from UserDefaults
    private func getLocalPath(for sourceId: String) -> String? {
        let paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String]
        return paths?[sourceId]
    }

    // MARK: - Actions

    /// Sync local state to DataManager and create session
    private func submitTask() {
        // Sync local state to DataManager
        dataManager.promptText = localPromptText
        if let attachment = localAttachmentContent {
            dataManager.setDraftAttachment(content: attachment)
        }
        if let image = localImageAttachment {
            dataManager.setDraftImageAttachment(image: image)
        }

        // Create the session
        dataManager.createSession()

        // Clear local state
        localPromptText = ""
        localAttachmentContent = nil
        localImageAttachment = nil
    }

    /// Replace the current word in the text with the selected filename
    private func replaceCurrentWordWithFilename(_ filename: String) {
        // Find the current word prefix and replace it
        let text = localPromptText

        // Find the last word-like sequence at the end of the text
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
        localPromptText = newText

        // Set pending cursor position to end of new text so SimpleTextEditor positions cursor correctly
        autocompleteManager.pendingCursorPosition = newText.utf16.count

        // Clear autocomplete
        autocompleteManager.clearSuggestions()
    }
}

extension Color {
    func toNSColor() -> NSColor {
        return NSColor(self)
    }
}
