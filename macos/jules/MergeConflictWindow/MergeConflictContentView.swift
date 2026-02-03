//
//  MergeConflictContentView.swift
//  jules
//
//  Main content view for the merge conflict window with Metal-based rendering.
//

import SwiftUI
import AppKit
import CodeEditLanguages

// MARK: - Merge Conflict Content View

/// The main content area showing the file with conflict resolution UI
struct MergeConflictContentView: View {
    @ObservedObject var store: MergeConflictStore
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if let file = store.selectedFile {
                MergeConflictMetalEditorView(
                    file: file,
                    store: store,
                    onResolveConflict: { conflictId, choice in
                        // Defer state changes to avoid "Publishing changes from within view updates" warning
                        DispatchQueue.main.async {
                            store.resolveConflict(
                                fileIndex: store.selectedFileIndex,
                                conflictId: conflictId,
                                choice: choice
                            )
                        }
                    }
                )
                // Force view recreation when file changes to ensure viewModel updates
                .id(file.id)
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: AppColors.diffEditorBackground))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(AppColors.textSecondary)

            Text("No file selected")
                .font(.headline)
                .foregroundColor(AppColors.textSecondary)

            Text("Select a file from the sidebar to view conflicts")
                .font(.subheadline)
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Metal Editor View

/// SwiftUI wrapper for the Metal-based merge conflict editor
struct MergeConflictMetalEditorView: View {
    let file: ConflictFile
    @ObservedObject var store: MergeConflictStore
    let onResolveConflict: (UUID, ConflictResolutionChoice) -> Void

    @StateObject private var viewModel = MergeConflictViewModel()

    var body: some View {
        // Metal view with embedded buttons (no SwiftUI overlay needed)
        MergeConflictMetalScrollView(
            viewModel: viewModel,
            onResolveConflict: { [weak store] startLineIndex, choice in
                // IMPORTANT: Use store.selectedFile to get the CURRENT file data, not the
                // captured 'file' parameter which becomes stale after conflict resolution.
                // When a conflict is resolved, the file content changes and line indices shift,
                // so we need to look up against the current state.
                guard let currentFile = store?.selectedFile else { return }

                // Match conflict by start line index
                guard let conflict = currentFile.conflicts.first(where: { $0.startLineIndex == startLineIndex }) else {
                    // Fallback: try to find conflict near this line
                    guard let nearestConflict = currentFile.conflicts.min(by: {
                        abs($0.startLineIndex - startLineIndex) < abs($1.startLineIndex - startLineIndex)
                    }) else { return }
                    onResolveConflict(nearestConflict.id, choice)
                    return
                }
                onResolveConflict(conflict.id, choice)
            }
        )
        .onAppear {
            viewModel.language = languageString(from: file.language)
            viewModel.updateContent(file.content)
        }
        .onChange(of: file.content) { newContent in
            viewModel.updateContent(newContent)
        }
        .onChange(of: file.id) { _ in
            viewModel.language = languageString(from: file.language)
            viewModel.updateContent(file.content)
        }
    }

    private func languageString(from codeLanguage: CodeEditLanguages.CodeLanguage) -> String {
        // Map CodeLanguage to language string
        switch codeLanguage {
        case .swift: return "swift"
        case .python: return "python"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .java: return "java"
        case .go: return "go"
        case .rust: return "rust"
        case .ruby: return "ruby"
        case .json: return "json"
        case .c: return "c"
        case .cpp: return "cpp"
        default: return "text"
        }
    }
}

// MARK: - Metal ScrollView Representable

/// NSViewRepresentable that wraps MergeConflictMetalView in an NSScrollView
/// Buttons are embedded in the document view and scroll naturally with content
struct MergeConflictMetalScrollView: NSViewRepresentable {
    @ObservedObject var viewModel: MergeConflictViewModel
    /// Callback when user resolves a conflict (startLineIndex, choice)
    let onResolveConflict: (Int, ConflictResolutionChoice) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // Create Metal view
        guard let device = fluxSharedMetalDevice else {
            let placeholderView = NSView()
            scrollView.documentView = placeholderView
            return scrollView
        }

        let metalView = MergeConflictMetalView(device: device)
        metalView.viewModel = viewModel
        // Don't use auto layout - we'll manage frame manually to avoid Metal texture overflow
        metalView.translatesAutoresizingMaskIntoConstraints = true

        // Create flipped document view to host Metal view and buttons
        let documentView = FlippedDocumentView()
        documentView.metalView = metalView
        documentView.addSubview(metalView)

        // Set up embedded buttons container (scrolls with content)
        documentView.setupButtonsContainer()
        let coordinator = context.coordinator
        documentView.buttonsContainer?.onResolveConflict = { [weak coordinator] startLineIndex, choice in
            Task { @MainActor in
                coordinator?.parent.onResolveConflict(startLineIndex, choice)
            }
        }

        scrollView.documentView = documentView

        // Note: Metal view frame is managed manually via updateMetalViewFrame()
        // to keep texture size within Metal's 16384 pixel limit

        // Store references
        context.coordinator.scrollView = scrollView
        context.coordinator.metalView = metalView
        context.coordinator.documentView = documentView

        // Setup scroll observation
        context.coordinator.setupScrollObservation()

        // Setup layout callback
        metalView.onLayoutChanged = { [weak coordinator = context.coordinator] size in
            Task { @MainActor in
                coordinator?.updateDocumentSize()
                coordinator?.updateButtons()
            }
        }

        // Setup auto-scroll callback
        metalView.onVerticalAutoScroll = { [weak scrollView] delta in
            guard let scrollView = scrollView else { return }
            let clipView = scrollView.contentView
            var newOrigin = clipView.bounds.origin
            newOrigin.y = max(0, newOrigin.y + delta)
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clipView.bounds.height)
            newOrigin.y = min(maxY, newOrigin.y)
            clipView.setBoundsOrigin(newOrigin)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.updateDocumentSize()
        context.coordinator.updateButtons()
        context.coordinator.metalView?.renderUpdate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    class Coordinator: NSObject {
        var parent: MergeConflictMetalScrollView
        weak var scrollView: NSScrollView?
        weak var metalView: MergeConflictMetalView?
        weak var documentView: FlippedDocumentView?
        private var boundsObserver: NSObjectProtocol?

        init(parent: MergeConflictMetalScrollView) {
            self.parent = parent
            super.init()
        }

        func setupScrollObservation() {
            guard let scrollView = scrollView else { return }

            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleScrollChange()
            }

            // Set initial viewport values after a brief delay to avoid updating during view setup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.handleScrollChange()
                self?.updateButtons()
            }
        }

        func handleScrollChange() {
            guard let scrollView = scrollView,
                  let metalView = metalView,
                  let documentView = documentView else { return }

            let visibleRect = scrollView.documentVisibleRect
            let scrollY = visibleRect.origin.y
            let viewportHeight = visibleRect.height

            // CRITICAL: Update Metal view frame to track scroll position.
            // This keeps the Metal texture within 16384 pixel limit while scrolling.
            documentView.updateMetalViewFrame(visibleRect: visibleRect)

            // Update Metal view content
            metalView.updateScrollPosition(scrollY, viewportHeight: viewportHeight)
        }

        func updateDocumentSize() {
            guard let scrollView = scrollView, let documentView = documentView else { return }

            let contentHeight = parent.viewModel.totalContentHeight
            let width = scrollView.contentView.bounds.width

            // Document view gets full content height (drives scrollbar)
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

            // Metal view gets viewport size only (avoids texture overflow)
            let visibleRect = scrollView.documentVisibleRect
            documentView.updateMetalViewFrame(visibleRect: visibleRect)

            // Update Metal view content with current scroll position
            metalView?.updateScrollPosition(visibleRect.origin.y, viewportHeight: visibleRect.height)
        }

        /// Update embedded conflict buttons based on current conflicts
        func updateButtons() {
            guard let documentView = documentView else { return }

            let viewModel = parent.viewModel
            let conflicts = viewModel.conflicts
            let lineHeight = viewModel.lineHeight
            let verticalPadding = viewModel.verticalPadding
            let contentWidth = scrollView?.contentView.bounds.width ?? 800

            documentView.buttonsContainer?.updateButtons(
                conflicts: conflicts,
                lineHeight: lineHeight,
                verticalPadding: verticalPadding,
                contentWidth: contentWidth
            )
        }

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - Flipped Document View

/// NSView subclass with flipped coordinate system for scroll view
class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }

    /// Reference to the Metal view for frame updates
    weak var metalView: MergeConflictMetalView?

    /// Container for conflict action buttons (embedded, scrolls with content)
    var buttonsContainer: ConflictButtonsContainerView?

    func setupButtonsContainer() {
        guard buttonsContainer == nil else { return }
        let container = ConflictButtonsContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        buttonsContainer = container
    }

    /// Update Metal view frame to match the visible rect.
    /// This keeps the Metal texture within Metal's 16384 pixel limit while
    /// allowing the document to be any height for scrollbar purposes.
    func updateMetalViewFrame(visibleRect: NSRect) {
        guard let metalView = metalView else { return }

        let width = bounds.width
        let viewportHeight = visibleRect.height
        let scrollY = visibleRect.origin.y

        // Position the Metal view at the top of the visible area.
        // The Metal view will render content offset by scrollY internally.
        metalView.frame = NSRect(x: 0, y: scrollY, width: width, height: viewportHeight)
    }
}

// MARK: - Conflict Buttons Container View

/// NSView that manages conflict action buttons - embedded in document view to scroll with content
class ConflictButtonsContainerView: NSView {
    /// Callback when user resolves a conflict (startLineIndex, choice)
    var onResolveConflict: ((Int, ConflictResolutionChoice) -> Void)?

    /// Current button groups keyed by conflict start line
    private var buttonGroups: [Int: ConflictButtonGroup] = [:]

    override var isFlipped: Bool { true }

    /// Update buttons based on conflicts from view model
    func updateButtons(conflicts: [ConflictRegion], lineHeight: CGFloat, verticalPadding: CGFloat, contentWidth: CGFloat) {
        // Track which conflicts are still active
        var activeStartLines = Set<Int>()

        for conflict in conflicts where !conflict.isResolved {
            activeStartLines.insert(conflict.startLineIndex)

            // Create button group if needed
            if buttonGroups[conflict.startLineIndex] == nil {
                let group = ConflictButtonGroup()
                group.startLineIndex = conflict.startLineIndex
                group.onResolve = { [weak self] choice in
                    self?.onResolveConflict?(conflict.startLineIndex, choice)
                }
                addSubview(group)
                buttonGroups[conflict.startLineIndex] = group
            }

            // Position the button group (in document coordinates, not viewport-relative)
            if let group = buttonGroups[conflict.startLineIndex] {
                let yPosition = verticalPadding + CGFloat(conflict.startLineIndex) * lineHeight
                let groupWidth: CGFloat = 250  // Approximate width of button group
                let xPosition = max(contentWidth - groupWidth - 20, 200)
                group.frame = NSRect(
                    x: xPosition,
                    y: yPosition,
                    width: groupWidth,
                    height: lineHeight
                )
            }
        }

        // Remove button groups for resolved conflicts
        for (startLine, group) in buttonGroups {
            if !activeStartLines.contains(startLine) {
                group.removeFromSuperview()
                buttonGroups.removeValue(forKey: startLine)
            }
        }
    }

    /// Clear all buttons
    func clearButtons() {
        for (_, group) in buttonGroups {
            group.removeFromSuperview()
        }
        buttonGroups.removeAll()
    }
}

// MARK: - Conflict Button Group

/// A group of buttons for a single conflict (Current, Incoming, Both)
class ConflictButtonGroup: NSView {
    var startLineIndex: Int = 0
    var onResolve: ((ConflictResolutionChoice) -> Void)?

    private var currentButton: NSButton!
    private var incomingButton: NSButton!
    private var bothButton: NSButton!
    private var backgroundView: NSVisualEffectView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButtons()
    }

    private func setupButtons() {
        // Background with visual effect
        backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        addSubview(backgroundView)

        // Create buttons
        currentButton = createButton(title: "← Current", color: NSColor(hex: "4A90D9"), action: #selector(acceptCurrent))
        incomingButton = createButton(title: "Incoming →", color: NSColor(hex: "4CAF50"), action: #selector(acceptIncoming))
        bothButton = createButton(title: "⇄ Both", color: NSColor.systemGray, action: #selector(acceptBoth))

        addSubview(currentButton)
        addSubview(incomingButton)
        addSubview(bothButton)
    }

    private func createButton(title: String, color: NSColor, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = title
        button.bezelStyle = .inline
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 10
        button.contentTintColor = .white
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = action

        // Add tracking for hover effect
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: button,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)

        return button
    }

    override func layout() {
        super.layout()

        let buttonHeight: CGFloat = 22
        let buttonSpacing: CGFloat = 6
        let padding: CGFloat = 6

        // Calculate button widths
        let currentWidth: CGFloat = 70
        let incomingWidth: CGFloat = 78
        let bothWidth: CGFloat = 55

        let totalWidth = currentWidth + incomingWidth + bothWidth + buttonSpacing * 2 + padding * 2
        let startX = bounds.width - totalWidth
        let centerY = (bounds.height - buttonHeight) / 2

        // Position background
        backgroundView.frame = NSRect(
            x: startX,
            y: centerY - padding / 2,
            width: totalWidth,
            height: buttonHeight + padding
        )

        // Position buttons
        var x = startX + padding
        currentButton.frame = NSRect(x: x, y: centerY, width: currentWidth, height: buttonHeight)
        x += currentWidth + buttonSpacing
        incomingButton.frame = NSRect(x: x, y: centerY, width: incomingWidth, height: buttonHeight)
        x += incomingWidth + buttonSpacing
        bothButton.frame = NSRect(x: x, y: centerY, width: bothWidth, height: buttonHeight)
    }

    @objc private func acceptCurrent() {
        onResolve?(.current)
    }

    @objc private func acceptIncoming() {
        onResolve?(.incoming)
    }

    @objc private func acceptBoth() {
        onResolve?(.both)
    }

    // Allow clicks to pass through to Metal view in non-button areas
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        // Only handle hits on actual buttons
        if result === currentButton || result === incomingButton || result === bothButton {
            return result
        }
        return nil
    }
}

// MARK: - App Colors Extension for Conflict Buttons

extension AppColors {
    /// Button color for accepting current (ours) changes - blue
    static let conflictCurrentButton = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "4A90D9")  // Dark mode - blue
            : NSColor(hex: "2979FF")  // Light mode - blue
    }))

    /// Button color for accepting incoming (theirs) changes - green
    static let conflictIncomingButton = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(hex: "4CAF50")  // Dark mode - green
            : NSColor(hex: "43A047")  // Light mode - green
    }))
}

// MARK: - Preview

#Preview {
    let store = MergeConflictStore()
    store.loadTestData()

    return MergeConflictContentView(store: store)
        .frame(width: 800, height: 600)
}
