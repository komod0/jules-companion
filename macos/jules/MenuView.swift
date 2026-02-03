import SwiftUI

struct MenuView: View {
    @EnvironmentObject var dataManager: DataManager
    @StateObject private var flashManager = FlashMessageManager.shared

    // Progressive loading state - shows content incrementally for faster perceived performance
    @State private var showForm: Bool = false
    @State private var showList: Bool = false

    // Keyboard navigation state
    @State private var selectedSessionIndex: Int? = nil

    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 12
    private let flashMessageHeightEstimate: CGFloat = 55

    var body: some View {
        // Show splash view for new users without an API key
        if dataManager.apiKey.isEmpty {
            SplashView()
                .frame(width: dataManager.isPopoverExpanded ? AppConstants.Popover.expandedWidth : AppConstants.Popover.minimizedWidth)
                .frame(maxHeight: 545)
        } else {
            mainMenuContent
        }
    }

    private var mainMenuContent: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // --- Header (always visible immediately) ---
                AppHeaderView()

                VStack(alignment: .leading, spacing: 0) {
                    // --- New Task Form (loads first) ---
                    if showForm {
                        NewTaskFormView(
                            onDownArrow: handleDownArrow,
                            onUpArrow: handleUpArrow,
                            onEnterOverride: handleEnterOverride,
                            onInputFocus: handleInputFocus
                        )
                            .padding(.bottom, verticalPadding * 1.5)
                    } else {
                        // Lightweight placeholder while form loads
                        formPlaceholder
                    }

                    // --- Recent Tasks List (loads after form) ---
                    // Control visibility with opacity and disable hit testing when invisible
                    // to prevent the invisible view from swallowing clicks
                    ZStack {
                        RecentTasksListView(
                            selectedIndex: $selectedSessionIndex,
                            onNavigateUp: handleUpArrow,
                            onNavigateDown: handleDownArrow,
                            onSelect: handleSelectSession(_:)
                        )
                            .opacity(showList ? 1 : 0)
                            .allowsHitTesting(showList)

                        if showForm && !showList {
                            listPlaceholder
                        }
                    }
                }
            }
            // Note: Width is set on the outer ZStack; no need to duplicate here
            // to avoid redundant layout calculations

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
        .padding(.bottom, verticalPadding)
        .frame(width: dataManager.isPopoverExpanded ? AppConstants.Popover.expandedWidth : AppConstants.Popover.minimizedWidth)
        .frame(maxHeight: 545)
        .unifiedBackground(material: .popover, tintOverlayOpacity: 0.3, cornerRadius: 12)
        .edgesIgnoringSafeArea(.horizontal)
        .onAppear {
            #if DEBUG
            let appearTime = CFAbsoluteTimeGetCurrent()
            print("[MenuView] onAppear fired at \(appearTime)")
            #endif

            // Ensure the popover is correctly sized on first appearance
            NotificationCenter.default.post(name: .togglePopoverSize, object: dataManager.isPopoverExpanded)
            // Notify that menu opened so the list scrolls to top
            #if DEBUG
            print("[MenuView] Posting .menuDidOpen notification at \(CFAbsoluteTimeGetCurrent()) (showForm=\(showForm), showList=\(showList))")
            #endif
            NotificationCenter.default.post(name: .menuDidOpen, object: nil)

            // Reset selection when menu opens
            selectedSessionIndex = nil

            // Progressive loading: show form immediately, then list
            // Use Task with MainActor to schedule state changes outside the current SwiftUI layout pass.
            // This prevents NSHostingView reentrant layout warnings.
            if !showForm {
                Task { @MainActor in
                    #if DEBUG
                    print("[MenuView] Setting showForm=true at \(CFAbsoluteTimeGetCurrent())")
                    #endif
                    showForm = true

                    // Show list after form is visible
                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                    #if DEBUG
                    print("[MenuView] Setting showList=true at \(CFAbsoluteTimeGetCurrent())")
                    #endif
                    showList = true
                }
            }
        }
    }

    // MARK: - Keyboard Navigation

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
        NotificationCenter.default.post(name: .showChatWindow, object: session)
        return true
    }

    private func handleSelectSession(_ session: Session) {
        // Open session directly instead of relying on selectedSessionIndex binding
        // which may not have propagated yet due to SwiftUI's async binding updates
        dataManager.markSessionAsViewed(session)
        dataManager.ensureActivities(for: session)
        NotificationCenter.default.post(name: .showChatWindow, object: session)
    }

    private func handleInputFocus() {
        // Clear row selection when user starts typing or clicks in the text area
        selectedSessionIndex = nil
    }

    // MARK: - Placeholders

    private var formPlaceholder: some View {
        VStack(spacing: 12) {
            // Text editor placeholder (now includes inline source pickers)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.08))
                .frame(height: 80)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, verticalPadding * 1.5)
    }

    private var listPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(height: 60)
            }
        }
        .padding(.horizontal, horizontalPadding)
    }
}

extension NSNotification.Name {
    static let togglePopoverSize = NSNotification.Name("togglePopoverSize")
    static let showChatWindow = NSNotification.Name("showChatWindow")
    static let menuDidOpen = NSNotification.Name("menuDidOpen")
    static let closeCenteredMenu = NSNotification.Name("closeCenteredMenu")
}
// MARK: - Conditional Background Modifier

private struct ConditionalBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 16, *) {
            // macOS Sequoia and later - no unified background
            content
        } else {
            // Earlier versions - apply unified background
            content.unifiedBackground(material: .underWindowBackground, tintOverlayOpacity: 0.3)
        }
    }
}

