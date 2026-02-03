//
//  MergeConflictView.swift
//  jules
//
//  Metal-based merge conflict view for syntax-highlighted conflict display.
//  This replaces the old CodeEditSourceEditor-based implementation.
//

import SwiftUI
import AppKit

// MARK: - Main View

/// A Metal-based view for displaying and resolving merge conflicts.
/// Uses the same rendering infrastructure as the DiffView for consistent appearance.
struct MergeConflictView: View {
    @Binding var text: String
    var isEditable: Bool = false  // Note: editing is not supported in Metal view
    var language: String = "swift"

    @StateObject private var viewModel = MergeConflictViewModel()
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Layer 1: Metal view in NSScrollView
                MergeConflictMetalScrollViewWrapper(
                    viewModel: viewModel,
                    scrollOffset: $scrollOffset,
                    viewportHeight: $viewportHeight
                )

                // Layer 2: Interactive Actions Overlay for conflict resolution buttons
                MergeConflictActionsOverlay(
                    viewModel: viewModel,
                    scrollOffset: scrollOffset,
                    viewportHeight: viewportHeight,
                    onResolve: { conflictIndex, choice in
                        resolveConflict(at: conflictIndex, with: choice)
                    }
                )
            }
        }
        .onAppear {
            viewModel.language = language
            viewModel.updateContent(text)
        }
        .onChange(of: text) { newValue in
            viewModel.updateContent(newValue)
        }
    }

    /// Resolve a conflict at the given index with the specified choice
    private func resolveConflict(at index: Int, with choice: ConflictResolutionChoice) {
        guard index < viewModel.conflicts.count else { return }
        let conflict = viewModel.conflicts[index]

        // Get the content to use based on choice
        let resolvedContent: String
        switch choice {
        case .current:
            resolvedContent = conflict.currentContent
        case .incoming:
            resolvedContent = conflict.incomingContent
        case .both:
            resolvedContent = conflict.currentContent + "\n" + conflict.incomingContent
        }

        // Build the new text by replacing the conflict region
        let lines = text.components(separatedBy: "\n")
        var newLines: [String] = []

        var lineIndex = 0
        var skipUntilEnd = false
        var inConflict = false
        var currentConflictIndex = 0

        for line in lines {
            if line.hasPrefix("<<<<<<<") {
                if currentConflictIndex == index {
                    inConflict = true
                    skipUntilEnd = true
                    // Add the resolved content
                    newLines.append(contentsOf: resolvedContent.components(separatedBy: "\n"))
                } else {
                    newLines.append(line)
                }
                currentConflictIndex += 1
            } else if line.hasPrefix(">>>>>>>") && skipUntilEnd {
                skipUntilEnd = false
                inConflict = false
            } else if !skipUntilEnd {
                newLines.append(line)
            }
            lineIndex += 1
        }

        text = newLines.joined(separator: "\n")
    }
}

// MARK: - Metal ScrollView Wrapper

/// NSViewRepresentable wrapper for the Metal-based conflict view
struct MergeConflictMetalScrollViewWrapper: NSViewRepresentable {
    @ObservedObject var viewModel: MergeConflictViewModel
    @Binding var scrollOffset: CGFloat
    @Binding var viewportHeight: CGFloat

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
        metalView.translatesAutoresizingMaskIntoConstraints = false

        // Create flipped document view
        // Note: Keep translatesAutoresizingMaskIntoConstraints = true (default) for documentView
        // since we set its frame manually in updateDocumentSize()
        let documentView = MergeConflictFlippedView()
        documentView.addSubview(metalView)

        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: documentView.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.metalView = metalView
        context.coordinator.documentView = documentView

        context.coordinator.setupScrollObservation()

        let coordinator = context.coordinator
        metalView.onLayoutChanged = { [weak coordinator] _ in
            Task { @MainActor in
                coordinator?.updateDocumentSize()
            }
        }

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
        // Note: Do NOT update @Binding properties here - this is called during SwiftUI's
        // view update cycle and would cause "Publishing changes from within view updates" warning.
        // The scroll observer handles viewport updates safely via asyncAfter.
        context.coordinator.updateDocumentSize()
        context.coordinator.metalView?.renderUpdate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    class Coordinator: NSObject {
        var parent: MergeConflictMetalScrollViewWrapper
        weak var scrollView: NSScrollView?
        weak var metalView: MergeConflictMetalView?
        weak var documentView: MergeConflictFlippedView?
        private var boundsObserver: NSObjectProtocol?

        init(parent: MergeConflictMetalScrollViewWrapper) {
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
                MainActor.assumeIsolated {
                    self?.handleScrollChange()
                }
            }

            // Set initial viewport values after a brief delay to avoid updating during view setup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleScrollChange()
                }
            }
        }

        func handleScrollChange() {
            guard let scrollView = scrollView, let metalView = metalView else { return }

            let scrollY = scrollView.contentView.bounds.origin.y
            let height = scrollView.contentView.bounds.height

            // Update Metal view immediately for smooth scrolling
            metalView.updateScrollPosition(scrollY, viewportHeight: height)

            // Defer SwiftUI state updates to next run loop to avoid
            // "Publishing changes from within view updates" warning
            DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
                guard let self = self else { return }
                self.parent.scrollOffset = scrollY
                self.parent.viewportHeight = height
            }
        }

        func updateDocumentSize() {
            guard let documentView = documentView else { return }

            let contentHeight = parent.viewModel.totalContentHeight
            let width = scrollView?.contentView.bounds.width ?? 800

            documentView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
            metalView?.frame = documentView.bounds
        }

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - Flipped View

/// NSView with flipped coordinate system for proper scroll view behavior
class MergeConflictFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Actions Overlay

/// Overlay with floating action buttons for each conflict
struct MergeConflictActionsOverlay: View {
    @ObservedObject var viewModel: MergeConflictViewModel
    let scrollOffset: CGFloat
    let viewportHeight: CGFloat
    let onResolve: (Int, ConflictResolutionChoice) -> Void

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(viewModel.conflicts.enumerated()), id: \.element.id) { index, conflict in
                if !conflict.isResolved {
                    let lineHeight = viewModel.lineHeight
                    let yPosition = viewModel.verticalPadding + CGFloat(conflict.startLineIndex) * lineHeight - scrollOffset

                    // Only render if visible
                    if yPosition > -100 && yPosition < viewportHeight + 100 {
                        HStack {
                            Spacer()
                            MergeConflictActionButtonGroup(
                                onAcceptCurrent: {
                                    onResolve(index, .current)
                                },
                                onAcceptIncoming: {
                                    onResolve(index, .incoming)
                                }
                            )
                        }
                        .offset(y: yPosition)
                        .padding(.trailing, 20)
                    }
                }
            }
        }
    }
}

// MARK: - Action Button Group

/// Button group for accepting current or incoming changes
struct MergeConflictActionButtonGroup: View {
    let onAcceptCurrent: () -> Void
    let onAcceptIncoming: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Accept Current") { onAcceptCurrent() }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)

            Button("Accept Incoming") { onAcceptIncoming() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .cornerRadius(6)
        .shadow(radius: 2)
    }
}

// MARK: - Conflict Coordinator (Legacy - kept for compatibility)

/// Coordinator for parsing merge conflicts from text.
/// This is kept for backwards compatibility with existing code.
class MergeConflictCoordinator: ObservableObject {
    @Published var conflicts: [Conflict] = []
    private var parseTask: Task<Void, Never>?

    struct Conflict: Equatable {
        let range: NSRange
        let oursRange: NSRange
        let theirsRange: NSRange
        let oursContent: String
        let theirsContent: String
        let startLineIndex: Int
        let midLineIndex: Int
        let endLineIndex: Int
    }

    deinit {
        parseTask?.cancel()
    }

    @MainActor
    func update(text: String) {
        parseTask?.cancel()
        parseTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let newConflicts = await self.parseConflicts(in: text)
            if !Task.isCancelled {
                self.conflicts = newConflicts
            }
        }
    }

    private func parseConflicts(in text: String) async -> [Conflict] {
        return await Task.detached(priority: .userInitiated) {
            let pattern = "(<<<<<<<.*?\\n)(.*?)((=======).*?\\n)(.*?)((>>>>>>>).*?\\n)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

            var result: [Conflict] = []
            var currentLineIndex = 0
            var lastLocation = 0

            for match in matches {
                if match.numberOfRanges >= 7 {
                    let fullRange = match.range
                    let startMarker = match.range(at: 1)
                    let ours = match.range(at: 2)
                    let midMarker = match.range(at: 3)
                    let theirs = match.range(at: 5)
                    let endMarker = match.range(at: 6)

                    let oursContent = nsString.substring(with: ours)
                    let theirsContent = nsString.substring(with: theirs)

                    let toStart = nsString.substring(with: NSRange(location: lastLocation, length: startMarker.location - lastLocation))
                    let linesToStart = toStart.filter { $0 == "\n" }.count
                    currentLineIndex += linesToStart

                    let startLine = currentLineIndex

                    let currentBlockLen = midMarker.location - startMarker.location
                    let currentBlockStr = nsString.substring(with: NSRange(location: startMarker.location, length: currentBlockLen))
                    let linesInCurrent = currentBlockStr.filter { $0 == "\n" }.count
                    let midLine = startLine + linesInCurrent

                    let incomingBlockLen = endMarker.location + endMarker.length - midMarker.location
                    let incomingBlockStr = nsString.substring(with: NSRange(location: midMarker.location, length: incomingBlockLen))
                    let linesInIncoming = incomingBlockStr.filter { $0 == "\n" }.count
                    let endLine = midLine + linesInIncoming

                    currentLineIndex = endLine
                    lastLocation = match.range.location + match.range.length

                    result.append(Conflict(
                        range: fullRange,
                        oursRange: ours,
                        theirsRange: theirs,
                        oursContent: oursContent,
                        theirsContent: theirsContent,
                        startLineIndex: startLine,
                        midLineIndex: midLine,
                        endLineIndex: endLine
                    ))
                }
            }
            return result
        }.value
    }
}
