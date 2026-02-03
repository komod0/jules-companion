import SwiftUI

struct RecentTasksListView: View {
    @EnvironmentObject var dataManager: DataManager
    @Binding var selectedIndex: Int?
    var onNavigateUp: (() -> Void)?
    var onNavigateDown: (() -> Void)?
    var onSelect: ((Session) -> Void)?

    @State private var hasAttemptedSessionRefresh: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var lastLoadTriggerTime: Date = .distantPast
    @FocusState private var isSearchFocused: Bool
    @StateObject private var scrollerStyle = ScrollerStyleObserver()

    private let searchRevealThreshold: CGFloat = 30
    private let loadDebounceInterval: TimeInterval = 0.5  // Prevent rapid load triggers

    init(
        selectedIndex: Binding<Int?> = .constant(nil),
        onNavigateUp: (() -> Void)? = nil,
        onNavigateDown: (() -> Void)? = nil,
        onSelect: ((Session) -> Void)? = nil
    ) {
        self._selectedIndex = selectedIndex
        self.onNavigateUp = onNavigateUp
        self.onNavigateDown = onNavigateDown
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dataManager.isLoadingSessions && dataManager.recentSessions.isEmpty {
                loadingView
            } else if dataManager.recentSessions.isEmpty {
                emptyView
            } else {
                sessionListView
            }
        }
        .onAppear {
            // Safeguard: If sessions are empty when view appears, try to refresh
            if dataManager.recentSessions.isEmpty && !hasAttemptedSessionRefresh && !dataManager.apiKey.isEmpty {
                hasAttemptedSessionRefresh = true
                dataManager.ensureSessionsLoaded()
            }
        }
        .onChange(of: dataManager.recentSessions) { newSessions in
            // Reset the refresh attempt flag if sessions become available
            if !newSessions.isEmpty {
                hasAttemptedSessionRefresh = false
            }
        }
    }

    private var loadingView: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Text("No recent sessions.")
                .foregroundColor(AppColors.textSecondary)

            // Show retry button if we've already attempted and still empty
            if hasAttemptedSessionRefresh {
                Button(action: {
                    Task {
                        await dataManager.forceRefreshSessions()
                    }
                }) {
                    Text("Retry")
                        .foregroundColor(AppColors.accent)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }

    private var filteredSessions: [Session] {
        if searchText.isEmpty {
            return dataManager.recentSessions
        }
        let lowercasedSearch = searchText.lowercased()
        return dataManager.recentSessions.filter { session in
            let title = session.title ?? ""
            let prompt = session.prompt
            return title.lowercased().contains(lowercasedSearch) ||
                   prompt.lowercased().contains(lowercasedSearch)
        }
    }

    private var sessionListView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Search bar - shown when revealed
                if isSearchVisible {
                    searchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                            RecentTaskRow(
                                session: session,
                                isSelected: selectedIndex == index,
                                onSelect: {
                                    selectedIndex = index
                                    onSelect?(session)
                                }
                            )
                            .id(session.id)
                            .onAppear {
                                checkAndLoadMore(for: session)
                            }
                        }

                        // Show no results message when searching
                        if !searchText.isEmpty && filteredSessions.isEmpty {
                            Text("No matching sessions")
                                .foregroundColor(AppColors.textSecondary)
                                .font(.caption)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
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
                    .padding(.leading, 15)
                    .padding(.trailing, scrollerStyle.isLegacyScrollers ? 0 : 15)
                    .frame(maxWidth: .infinity)
                    // Track scroll offset using a background GeometryReader (no top spacer item)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geo.frame(in: .named("scrollView")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "scrollView")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    let offset = value

                    // Detect overscrolling at the top (scroll offset becomes positive)
                    if offset > searchRevealThreshold && !isSearchVisible {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isSearchVisible = true
                        }
                        // Focus the search field after a brief delay
                        // Use Task with MainActor to avoid NSHostingView reentrant layout warnings
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                            isSearchFocused = true
                        }
                    }

                    scrollOffset = offset
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            // Track drag offset - positive when pulling down
                            let newDragOffset = value.translation.height
                            // Only trigger if we're at the top and dragging down
                            if newDragOffset > searchRevealThreshold && scrollOffset <= 5 && !isSearchVisible {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    isSearchVisible = true
                                }
                                // Focus the search field after a brief delay
                                // Use Task with MainActor to avoid NSHostingView reentrant layout warnings
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                    isSearchFocused = true
                                }
                            }
                        }
                )
                .onChange(of: selectedIndex) { newIndex in
                    // Scroll to selected item
                    if let index = newIndex, index < filteredSessions.count {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(filteredSessions[index].id, anchor: .center)
                        }
                    }
                }
            }
            .onReceive(dataManager.sessionCreatedPublisher) { newSession in
                // Scroll to top when new session is created
                // Use the new session's ID if available, otherwise fall back to filtered list
                let targetId = newSession?.id ?? filteredSessions.first?.id
                withAnimation {
                    proxy.scrollTo(targetId, anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuDidOpen)) { _ in
                // Scroll to top when menu opens
                withAnimation {
                    proxy.scrollTo(filteredSessions.first?.id, anchor: .top)
                }
                // Reset search state when menu opens
                if isSearchVisible && searchText.isEmpty {
                    withAnimation {
                        isSearchVisible = false
                    }
                }
                // Reset selection when menu opens
                selectedIndex = nil
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColors.textSecondary)
                .font(.system(size: 12))

            TextField("Search tasks...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.textSecondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isSearchVisible = false
                    searchText = ""
                    isSearchFocused = false
                }
            }) {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.1))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

}

// PreferenceKey to track scroll offset
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

