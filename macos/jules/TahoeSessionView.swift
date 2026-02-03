import SwiftUI

// MARK: - Tahoe Glass Effect Helpers

// Environment key to disable opaque backgrounds for glass toolbar effect
private struct GlassToolbarEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var glassToolbarEnabled: Bool {
        get { self[GlassToolbarEnabledKey.self] }
        set { self[GlassToolbarEnabledKey.self] = newValue }
    }
}

/// A container that applies glass effect styling to its content.
/// On macOS 26+, uses NSGlassEffectView for the "Liquid Glass" look.
/// On earlier versions, falls back to NSVisualEffectView.
struct GlassEffectContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(6)
            .background(
                // Use adaptive glass effect with header style and rounded corners
                AdaptiveEffectView(effectType: .header, cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}

extension View {
    /// Applies a glass effect background.
    /// On macOS 26+: No background applied (system handles sidebar styling)
    /// On earlier versions: Uses NSVisualEffectView with HUD window material
    @ViewBuilder
    func glassEffect() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            self.background(
                AdaptiveEffectView(effectType: .sidebar)
            )
        }
    }

    func backgroundExtensionEffect() -> some View {
        // Simulating extending background to window bounds
        self.ignoresSafeArea()
    }
}

// MARK: - Toolbar Glass Effect Overlay

/// A view that creates a glass effect overlay for the toolbar area.
/// This sits at the top of the content and blurs content scrolling behind it.
struct ToolbarGlassOverlay: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 52) // Standard macOS toolbar height
            .overlay(alignment: .bottom) {
                // Add a subtle separator line at the bottom
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: [.top, .horizontal]) // Extend into toolbar area
            .allowsHitTesting(false) // Allow clicks to pass through to toolbar items
    }
}

// MARK: - Tahoe Session View

@available(macOS 13.0, *)
struct TahoeSessionView: View {
    @EnvironmentObject var dataManager: DataManager
    @ObservedObject var selectionState: SessionSelectionState
    let initialSession: Session?

    // Callbacks mirroring SessionController actions
    var onToggleSidebar: (() -> Void)?
    var onPreviousSession: (() -> Void)?
    var onNextSession: (() -> Void)?
    var onNewChat: (() -> Void)?

    // Use an ObservableObject for state to ensure updates from controller propagate
    @ObservedObject var tahoeState: TahoeState

    // MARK: - Computed Properties

    private var currentSession: Session? {
        if selectionState.isCreatingNewSession {
            return nil
        }
        guard let sessionId = selectionState.selectedSessionId else {
            return nil
        }
        // O(1) lookup via dictionary. Sessions are inserted into sessionsById
        // synchronously when created, so this should always find the session.
        return dataManager.sessionsById[sessionId]
    }

    private var currentSessionIndex: Int? {
        guard let sessionId = selectionState.selectedSessionId else {
            return nil
        }
        return dataManager.recentSessions.firstIndex(where: { $0.id == sessionId })
    }

    private var hasPreviousSession: Bool {
        // When creating new session, there's no "previous" - already at the start
        if selectionState.isCreatingNewSession {
            return false
        }
        guard let index = currentSessionIndex else { return false }
        return index > 0
    }

    private var hasNextSession: Bool {
        // When creating new session, allow going to first session via "next"
        if selectionState.isCreatingNewSession {
            return !dataManager.recentSessions.isEmpty
        }
        guard let index = currentSessionIndex else { return false }
        // Enable next button if there's a loaded session OR more sessions available from API
        return index < dataManager.recentSessions.count - 1 || dataManager.hasMoreSessions
    }

    private var repoName: String {
        guard let session = currentSession,
              let source = session.sourceContext?.source else { return "" }
        let name = source.replacingOccurrences(of: "sources/github/", with: "")
        return name.isEmpty ? "" : name
    }

    private var branchName: String? {
        currentSession?.sourceContext?.githubRepoContext?.startingBranch
    }

    private var toolbarSubtitle: String {
        guard currentSession != nil else { return "Create a new task for Jules" }
        var components = [repoName].filter { !$0.isEmpty }
        if let branch = branchName {
            components.append(branch)
        }
        return components.joined(separator: " · ")
    }

    private var navigationTitle: String {
        if let session = currentSession {
            return session.title ?? "Session"
        }
        return "New Session"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $tahoeState.columnVisibility) {
            SidebarView(
                selectedSessionId: $selectionState.selectedSessionId,
                onSessionSelected: { session in
                    selectionState.selectedSessionId = session.id
                    selectionState.isCreatingNewSession = false
                }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            .glassEffect()
            // Extend sidebar content under toolbar for glass effect
            .ignoresSafeArea(edges: .top)
        } detail: {
            // Use MainSessionView for both existing sessions and new session creation
            // NOTE: Intentionally NOT using .id(currentSession?.id) here!
            // MainSessionView -> TrajectoryView -> UnifiedDiffPanel handles session changes
            // via updateNSView with hash-based change detection. Using .id() would destroy
            // the entire view hierarchy including Metal views, causing expensive
            // texture/renderer recreation and visible blinking.
            ZStack {
                MainSessionView(session: currentSession)
                    .environment(\.glassToolbarEnabled, true) // Enable glass toolbar mode

                // Show loading overlay when rate limiting is causing a delay
                if dataManager.isThrottlingActivities, currentSession != nil {
                    VStack {
                        Spacer()
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("Loading activities...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.windowBackgroundColor).opacity(0.95))
                                .shadow(radius: 2)
                        )
                        .padding(.bottom, 20)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.2), value: dataManager.isThrottlingActivities)
                }
            }
            // Extend content under toolbar for glass effect (Mac Notes style)
            // Content will scroll behind the toolbar and be visible through the blur
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: {
                        withAnimation {
                            tahoeState.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                    }
                }

                // Split button - to the left of pagination
                // NOTE: Use currentSession instead of initialSession to ensure the toolbar
                // shows the correct session after creating a new one. initialSession is
                // captured at view creation time and becomes stale after navigation.
                if let session = currentSession, !selectionState.isCreatingNewSession {
                    ToolbarItem(placement: .primaryAction) {
                        SessionToolbarActionsView(
                            selectionState: selectionState,
                            initialSession: session
                        )
                    }
                }

                // Navigation - replaced with ProgressView while loading more sessions
                ToolbarItem(placement: .secondaryAction) {
                    if dataManager.isLoadingMoreForPagination {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        ControlGroup {
                            Button(action: { onPreviousSession?() }) {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(!hasPreviousSession)
                            Divider() // Vertical line
                                .frame(width: 1, height: 20)
                                .background(AppColors.background.opacity(0.5))
                            Button(action: { onNextSession?() }) {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(!hasNextSession)
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button(action: { onNewChat?() }) {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(selectionState.isCreatingNewSession)
                    }
                }
            }
            .navigationTitle(Text(navigationTitle))
            .navigationSubtitle(Text(toolbarSubtitle))
            .onAppear {
                // Set active session for polling
                if let session = currentSession {
                    dataManager.activeSessionId = session.id
                    dataManager.ensureActivities(for: session)
                }
            }
            .onChange(of: selectionState.selectedSessionId) { newSessionId in
                // Defer state updates to next run loop to prevent multiple updates per frame
                // when quickly paginating through sessions
                Task { @MainActor in
                    // Update active session for polling when selection changes
                    if let sessionId = newSessionId {
                        dataManager.activeSessionId = sessionId
                    }
                    // Ensure activities are loaded for the new session
                    if let session = currentSession {
                        dataManager.ensureActivities(for: session)
                    }
                }
            }
            // MARK: - Glass Toolbar Effect (Mac Notes style)
            // Add a glass overlay at the top to create the frosted glass toolbar effect
            // Content scrolls behind this overlay thanks to .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                ToolbarGlassOverlay()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
