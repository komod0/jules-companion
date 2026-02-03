import SwiftUI
import AppKit

struct CustomToolbarView: View {
    @EnvironmentObject var dataManager: DataManager
    @ObservedObject var selectionState: SessionSelectionState
    let initialSession: Session?
    let onToggleSidebar: () -> Void
    let onPreviousSession: () -> Void
    let onNextSession: () -> Void
    let onNewSession: () -> Void

    // Hover states for toolbar buttons
    @State private var isSidebarToggleHovering = false
    @State private var isPreviousHovering = false
    @State private var isNextHovering = false
    @State private var isNewSessionHovering = false

    // Height for custom toolbar content (inside the unified toolbar)
    static let toolbarHeight: CGFloat = 52

    private var currentSession: Session? {
        if selectionState.isCreatingNewSession {
            return nil
        }
        guard let sessionId = selectionState.selectedSessionId ?? initialSession?.id else {
            return nil
        }
        return dataManager.recentSessions.first(where: { $0.id == sessionId }) ?? initialSession
    }

    private var currentSessionIndex: Int? {
        guard let sessionId = selectionState.selectedSessionId ?? initialSession?.id else {
            return nil
        }
        return dataManager.recentSessions.firstIndex(where: { $0.id == sessionId })
    }

    private var hasPreviousSession: Bool {
        guard let index = currentSessionIndex else { return false }
        return index > 0
    }

    private var hasNextSession: Bool {
        guard let index = currentSessionIndex else { return false }
        // Enable next button if there's a loaded session OR more sessions available from API
        return index < dataManager.recentSessions.count - 1 || dataManager.hasMoreSessions
    }

    private var titleText: String {
        guard let session = currentSession else {
            return "New Session"
        }
        let fullTitle = session.title ?? session.prompt
        if fullTitle.count > 100 {
            return String(fullTitle.prefix(100)) + "…"
        }
        return fullTitle
    }

    var body: some View {
        ZStack {
            // Background layer - allows window dragging
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Content layer
            HStack(spacing: 0) {
                // Left section: Sidebar toggle, new session, and navigation buttons
                HStack(spacing: 2) {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                            .opacity(isSidebarToggleHovering ? 1.0 : 0.8)
                            .padding(.top, 2) // visual adjustment
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isSidebarToggleHovering = hovering
                    }

                    // New Session button (moved next to sidebar toggle)
                    Button(action: onNewSession) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                            .opacity(isNewSessionHovering ? 1.0 : 0.8)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isNewSessionHovering = hovering
                    }

                    // Divider
                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 4)

                    // Session pagination buttons - replaced with ProgressView while loading more
                    if dataManager.isLoadingMoreForPagination {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 88, height: 44)
                    } else {
                        Button(action: onPreviousSession) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary)
                                .opacity(hasPreviousSession ? (isPreviousHovering ? 1.0 : 0.8) : 0.3)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isPreviousHovering = hovering
                        }
                        .disabled(!hasPreviousSession)

                        Button(action: onNextSession) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary)
                                .opacity(hasNextSession ? (isNextHovering ? 1.0 : 0.8) : 0.3)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isNextHovering = hovering
                        }
                        .disabled(!hasNextSession)
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 4)

                // Center section: Session header content
                VStack(alignment: .leading, spacing: 4) {
                    // Title (limited to 150 characters)
                    Text(titleText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                        .padding(.top, 10)
                        .truncationMode(.tail)

                    // Metadata Row - only show when we have a session
                    if let session = currentSession {
                        HStack(spacing: 6) {
                            // Source (Repo)
                            Text(repoName)

                            // Branch
                            if let branch = session.sourceContext?.githubRepoContext?.startingBranch {
                                Text("·")
                                    .foregroundColor(AppColors.textSecondary.opacity(0.5))
                                Text(branch)
                            }

                            // Stats
                            if let statsSummary = session.gitStatsSummary {
                                Text("·")
                                    .foregroundColor(AppColors.textSecondary.opacity(0.5))
                                Text(attributedGitStats(from: statsSummary))
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    } else {
                        // Show hint for new session
                        Text("Create a new task for Jules")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                .padding(.leading, 16)
                .allowsHitTesting(false) // Allow dragging through text

                Spacer()

                // Right section: Action buttons - only show when we have a session
                if let session = initialSession {
                    SessionToolbarActionsView(
                        selectionState: selectionState,
                        initialSession: session
                    )
                    .padding(.trailing, 20)
                    .padding(.top, 10)
                }
            }
        }
        .frame(height: Self.toolbarHeight)
        .ignoresSafeArea()
        .background(Color.clear)
    }

    // MARK: - Computed Properties

    private var repoName: String {
        guard let session = currentSession,
              let source = session.sourceContext?.source else { return "Unknown" }
        let name = source.replacingOccurrences(of: "sources/github/", with: "")
        return name
    }

    private func attributedGitStats(from statsSummary: String) -> AttributedString {
        var attributedString = AttributedString()
        let components = statsSummary.split(separator: " ")
        for (index, component) in components.enumerated() {
            var part = AttributedString(String(component))
            if component.starts(with: "+") {
                part.foregroundColor = AppColors.linesAdded
            } else if component.starts(with: "-") {
                part.foregroundColor = AppColors.linesRemoved
            }
            attributedString.append(part)
            if index < components.count - 1 {
                attributedString.append(AttributedString(" "))
            }
        }
        return attributedString
    }
}

// MARK: - Window Drag Area

/// A view that enables window dragging when clicked and dragged
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        return WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Start window drag
        window?.performDrag(with: event)
    }
}
