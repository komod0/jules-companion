import SwiftUI

/// A centered floating menu view designed for middle-of-screen positioning.
/// Features larger fonts and shows only 3 recent activities.
struct CenteredMenuView: View {
    @EnvironmentObject var dataManager: DataManager
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var flashManager = FlashMessageManager.shared
    @State private var selectedSessionIndex: Int? = nil

    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 16

    // Popover border colors adapt to light/dark mode
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

    private var shadowOpacity: Double {
        colorScheme == .dark ? 0.6 : 0.2
    }

    var body: some View {
        // Show splash view for new users without an API key
        if dataManager.apiKey.isEmpty {
            splashContent
        } else {
            mainMenuContent
        }
    }

    private var splashContent: some View {
        SplashView()
            .frame(width: AppConstants.CenteredMenu.width)
            .frame(maxHeight: AppConstants.CenteredMenu.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Inner light border (highlight effect)
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(innerBorderColor, lineWidth: 1)
                    .padding(1)
            )
            // Outer dark border
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(outerBorderColor, lineWidth: 1)
            )
            // Drop shadow
            .shadow(color: .black.opacity(shadowOpacity), radius: 10, x: 0, y: 8)
            .shadow(color: .black.opacity(shadowOpacity * 0.5), radius: 4, x: 0, y: 2)
    }

    private var mainMenuContent: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // --- Header with Logo and Title ---
                CenteredHeaderView()

                // --- Input Form Area ---
                CenteredTaskFormView(
                    onDownArrow: handleDownArrow,
                    onUpArrow: handleUpArrow,
                    onEnterOverride: handleEnterOverride,
                    onInputFocus: handleInputFocus
                )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, verticalPadding)

                // --- Recent Tasks (scrollable, showing 3 visible) ---
                CenteredRecentTasksListView(
                    selectedIndex: $selectedSessionIndex,
                    onNavigateUp: handleUpArrow,
                    onNavigateDown: handleDownArrow,
                    onSelect: handleSelectSession
                )
                .padding(.top, 8)
            }

            // Flash message overlay - no horizontal padding so it extends to container edges
            if flashManager.isShowing {
                Group {
                    if flashManager.style == .wave {
                        WaveFlashMessageView(
                            message: flashManager.message,
                            type: flashManager.type,
                            cornerRadius: 12,
                            waveConfiguration: flashManager.waveConfiguration,
                            showBoids: flashManager.showBoids,
                            onDismiss: { flashManager.hide() }
                        )
                    } else {
                        FlashMessageView(
                            message: flashManager.message,
                            type: flashManager.type,
                            onDismiss: { flashManager.hide() }
                        )
                        .cornerRadius(12)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: flashManager.isShowing)
                .zIndex(1)
            }
        }
        .frame(width: AppConstants.CenteredMenu.width)
        .frame(maxHeight: AppConstants.CenteredMenu.height, alignment: .top)
        .unifiedBackground(material: .popover, tintOverlayOpacity: 0.3, cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Inner light border (highlight effect)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(innerBorderColor, lineWidth: 1)
                .padding(1)
        )
        // Outer dark border
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(outerBorderColor, lineWidth: 1)
        )
        // Drop shadow (AppKit layer has masksToBounds=false to allow shadow to render)
        .shadow(color: .black.opacity(shadowOpacity), radius: 10, x: 0, y: 8)
        .shadow(color: .black.opacity(shadowOpacity * 0.5), radius: 4, x: 0, y: 2)
        .onAppear {
            NotificationCenter.default.post(name: .menuDidOpen, object: nil)
            selectedSessionIndex = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuDidOpen)) { _ in
            // Clear selection each time the menu opens (handles re-opening after close)
            selectedSessionIndex = nil
        }
    }

    private func handleDownArrow() {
        guard !dataManager.recentSessions.isEmpty else { return }
        if let current = selectedSessionIndex {
            if current < dataManager.recentSessions.count - 1 {
                selectedSessionIndex = current + 1
            }
        } else {
            selectedSessionIndex = 0
        }
    }

    private func handleUpArrow() {
        guard !dataManager.recentSessions.isEmpty else { return }
        if let current = selectedSessionIndex {
            if current > 0 {
                selectedSessionIndex = current - 1
            } else {
                // Exit list mode - will refocus text input via notification
                selectedSessionIndex = nil
                NotificationCenter.default.post(name: .menuDidOpen, object: nil)
            }
        }
    }

    private func handleEnterOverride() -> Bool {
        guard let index = selectedSessionIndex, index < dataManager.recentSessions.count else { return false }
        let session = dataManager.recentSessions[index]
        dataManager.markSessionAsViewed(session)
        dataManager.ensureActivities(for: session)
        NotificationCenter.default.post(name: .closeCenteredMenu, object: nil)
        NotificationCenter.default.post(name: .showChatWindow, object: session)
        return true
    }

    private func handleSelectSession() {
        _ = handleEnterOverride()
    }

    private func handleInputFocus() {
        // Clear row selection when user starts typing or clicks in the text area
        selectedSessionIndex = nil
    }
}

// MARK: - Centered Header View

struct CenteredHeaderView: View {
    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Image("jules-icon-purple")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(AppColors.accent)

            Text("Jules")
                .font(.headline)
                .foregroundColor(AppColors.accent)

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, verticalPadding)
        .padding(.bottom, verticalPadding)
    }
}

// MARK: - Centered Task Form

struct CenteredTaskFormView: View {
    @EnvironmentObject var dataManager: DataManager
    private let autocompleteManager = FilenameAutocompleteManager.shared
    // Navigation callbacks - called when arrow keys are pressed
    var onDownArrow: (() -> Void)? = nil
    var onUpArrow: (() -> Void)? = nil
    // Enter override - if returns true, enter was handled by navigation; else fall through to submit
    var onEnterOverride: (() -> Bool)? = nil
    // Input focus callback - called when user starts typing or clicks in the text area
    var onInputFocus: (() -> Void)? = nil

    @State private var localPromptText: String = ""
    @State private var localAttachmentContent: String? = nil
    @State private var localImageAttachment: NSImage? = nil
    @State private var sourcePickerDropdown: SourcePickerDropdown = .none

    private var hasTextContent: Bool {
        !localPromptText.isEmpty &&
        localPromptText.contains { !$0.isWhitespace && !$0.isNewline }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 5) {
                // Text input area with inline source picker in bottom row
                ZStack(alignment: .topLeading) {
                    PatternHighlightTextEditorContainer(
                        text: $localPromptText,
                        baseFont: .systemFont(ofSize: 15, weight: .regular),
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
                        minHeight: 120,
                        maxHeight: 300,
                        contentPadding: 15,
                        onAutocompleteRequest: { prefix in
                            autocompleteManager.updateSuggestions(for: prefix)
                        },
                        onTextChange: nil,
                        onDownArrow: onDownArrow,
                        onUpArrow: onUpArrow,
                        onEnterOverride: onEnterOverride,
                        onInputFocus: onInputFocus,
                        bottomLeadingContent: {
                            // Inline source picker buttons at bottom-left (same row as submit button)
                            InlineSourcePickerView(activeDropdown: $sourcePickerDropdown, fontSize: 14)
                        }
                    )

                    // Placeholder
                    if localPromptText.isEmpty && localAttachmentContent == nil && localImageAttachment == nil {
                        Text("Ask anything")
                            .foregroundColor(AppColors.textSecondary.opacity(0.5))
                            .padding(.leading, 26)
                            .padding(.top, 10 + 5)
                            .allowsHitTesting(false)
                            .font(.system(size: 15))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.4)))

                // Autocomplete menu
                FilenameAutocompleteMenuView(
                    autocompleteManager: autocompleteManager,
                    onSelect: { filename in
                        replaceCurrentWordWithFilename(filename)
                    },
                    positionAbove: false
                )

                // Attachment indicators
                if let content = localAttachmentContent {
                    AttachmentIndicatorView(
                        onRemove: { localAttachmentContent = nil },
                        lineCount: content.components(separatedBy: "\n").count
                    )
                }

                if let image = localImageAttachment {
                    ImageAttachmentIndicatorView(
                        image: image,
                        onRemove: { localImageAttachment = nil },
                        onEdit: { annotatedImage in
                            localImageAttachment = annotatedImage
                        }
                    )
                }
            }

            // Source picker dropdown overlay (positioned below text editor)
            if sourcePickerDropdown != .none {
                // Transparent backdrop to dismiss dropdown when clicking outside
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        sourcePickerDropdown = .none
                    }

                SourcePickerDropdownView(activeDropdown: $sourcePickerDropdown)
                    .padding(.top, 130) // Position below text editor (minHeight 120 + buffer)
            }
        }
        .onChange(of: dataManager.selectedSourceId) { newSourceId in
            if let sourceId = newSourceId {
                let localPath = getLocalPath(for: sourceId)
                autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
                autocompleteManager.setActiveRepository(sourceId)
            } else {
                autocompleteManager.setActiveRepository(nil)
            }
        }
        .onChange(of: dataManager.draftImageAttachment) { newImage in
            if let image = newImage, localImageAttachment == nil {
                localImageAttachment = image
                dataManager.clearDraftImageAttachment()
            }
        }
        .onAppear {
            if let sourceId = dataManager.selectedSourceId {
                let localPath = getLocalPath(for: sourceId)
                autocompleteManager.registerRepository(repositoryId: sourceId, localPath: localPath)
                autocompleteManager.setActiveRepository(sourceId)
            }
            if let image = dataManager.draftImageAttachment {
                localImageAttachment = image
                dataManager.clearDraftImageAttachment()
            }
        }
    }

    private func getLocalPath(for sourceId: String) -> String? {
        let paths = UserDefaults.standard.dictionary(forKey: "localRepoPathsKey") as? [String: String]
        return paths?[sourceId]
    }

    private func submitTask() {
        dataManager.promptText = localPromptText
        if let attachment = localAttachmentContent {
            dataManager.setDraftAttachment(content: attachment)
        }
        if let image = localImageAttachment {
            dataManager.setDraftImageAttachment(image: image)
        }

        dataManager.createSession()

        localPromptText = ""
        localAttachmentContent = nil
        localImageAttachment = nil
    }

    private func replaceCurrentWordWithFilename(_ filename: String) {
        let text = localPromptText
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

        let prefix = String(text[..<wordStart])
        let newText = prefix + filename
        localPromptText = newText
        autocompleteManager.pendingCursorPosition = newText.utf16.count
        autocompleteManager.clearSuggestions()
    }
}

// MARK: - Centered Recent Tasks List View

struct CenteredRecentTasksListView: View {
    @EnvironmentObject var dataManager: DataManager
    @Binding var selectedIndex: Int?
    var onNavigateUp: () -> Void
    var onNavigateDown: () -> Void
    var onSelect: () -> Void

    @State private var lastLoadTriggerTime: Date = .distantPast
    private let loadDebounceInterval: TimeInterval = 0.5

    private let visibleRowCount: Int = 3
    private let rowHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            if dataManager.isLoadingSessions && dataManager.recentSessions.isEmpty {
                loadingView
            } else if dataManager.recentSessions.isEmpty {
                emptyView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(dataManager.recentSessions.enumerated()), id: \.element.id) { index, session in
                                CenteredRecentTaskRow(
                                    session: session,
                                    isSelected: selectedIndex == index,
                                    onSelect: {
                                        selectedIndex = index
                                        onSelect()
                                    }
                                )
                                .id(session.id)
                                .onAppear {
                                    checkAndLoadMore(for: session)
                                }
                            }

                            if dataManager.isFetchingNextPage {
                                HStack {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                    Spacer()
                                }
                                .padding()
                            }
                        }
                    }
                    .frame(height: CGFloat(visibleRowCount) * rowHeight)
                    .onChange(of: selectedIndex) { newIndex in
                        if let index = newIndex, index < dataManager.recentSessions.count {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(dataManager.recentSessions[index].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func checkAndLoadMore(for session: Session) {
        guard !dataManager.isFetchingNextPage && dataManager.hasMoreSessions else { return }

        // Debounce: prevent triggering loads too frequently
        let now = Date()
        guard now.timeIntervalSince(lastLoadTriggerTime) >= loadDebounceInterval else { return }

        // Find the index of the current session
        guard let index = dataManager.recentSessions.firstIndex(where: { $0.id == session.id }) else { return }

        // Start loading when we're 20 items from the end
        let threshold = max(0, dataManager.recentSessions.count - 20)

        if index >= threshold {
            lastLoadTriggerTime = now
            Task(priority: .userInitiated) {
                await dataManager.fetchNextPageOfSessions()
            }
        }
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .frame(height: CGFloat(visibleRowCount) * rowHeight)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))
            Text("No recent tasks")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(height: CGFloat(visibleRowCount) * rowHeight)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Centered Recent Task Row (Bigger Text)

struct CenteredRecentTaskRow: View {
    @EnvironmentObject var dataManager: DataManager
    @Environment(\.openURL) var openURL
    let session: Session
    var isSelected: Bool = false
    var onSelect: () -> Void

    @State private var isHovering: Bool = false
    @State private var isHoveringDiffStats: Bool = false

    private var currentSession: Session {
        dataManager.sessionsById[session.id] ?? session
    }

    // Extract PR URL for linking diff stats
    private var prURL: URL? {
        guard let outputs = currentSession.outputs,
              let pr = outputs.first(where: { $0.pullRequest != nil })?.pullRequest,
              let url = URL(string: pr.url) else {
            return nil
        }
        return url
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // State icon - use state.color to match TaskSubtitleView styling
            Image(systemName: currentSession.state.iconName)
                .font(.system(size: 12))
                .foregroundColor(currentSession.state.color)
                .frame(width: 16)

            // Title
            Text(currentSession.title ?? currentSession.prompt)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Status text - hidden when completed/completedUnknown, matching TaskSubtitleView behavior
            if currentSession.state != .completed && currentSession.state != .completedUnknown {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
            }

            // Time ago
            Text((currentSession.updateTime ?? currentSession.createTime).flatMap { Date.parseAPIDate($0) }?.timeAgoDisplay() ?? "")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)

            Spacer()

            // Git stats - all the way on the right
            if let statsSummary = currentSession.gitStatsSummary {
                if let url = prURL {
                    Button(action: { openURL(url) }) {
                        DiffStatsBadges(statsSummary: statsSummary, fontSize: 12)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in isHoveringDiffStats = hovering }
                } else {
                    DiffStatsBadges(statsSummary: statsSummary, fontSize: 12)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            if isSelected {
                Rectangle()
                    .fill(AppColors.accent.opacity(0.15))
                    .overlay(
                        Rectangle()
                            .strokeBorder(AppColors.accent.opacity(0.3))
                    )
            } else if isHovering {
                Rectangle()
                    .fill(.ultraThickMaterial)
                    .overlay(
                        Rectangle()
                            .strokeBorder(.primary.opacity(0.08))
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .onTapGesture {
            onSelect()
        }
    }

    private var statusText: String {
        if currentSession.state == .inProgress, let progressTitle = currentSession.latestProgressTitle {
            return progressTitle
        }
        return currentSession.state.displayName
    }
}

