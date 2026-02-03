import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var dataManager: DataManager
    @Binding var selectedSessionId: String?
    var onSessionSelected: (Session) -> Void
    @State private var searchText = ""
    @FocusState private var isFocused: Bool
    @FocusState private var isListFocused: Bool

    // Pagination for "Older" section - starts at 20, increases by 20 on each "Load More"
    private let allSectionPageSize = 20
    @State private var allSectionLimit = 20

    // MARK: - Cached Session Categories (OPTIMIZATION)
    // These are cached to avoid recomputing expensive date parsing and filtering on every body evaluation
    @State private var cachedTodaySessions: [Session] = []
    @State private var cachedThisWeekSessions: [Session] = []
    @State private var cachedOlderSessions: [Session] = []
    @State private var lastCacheKey: String = ""

    // OPTIMIZATION: Defer "Older" section rendering to prioritize Today/This Week
    @State private var isOlderSectionLoaded = false

    // MARK: - Computed Properties for Session Categorization

    /// Generates a cache key based on session IDs and search text
    private var cacheKey: String {
        let sessionIds = dataManager.recentSessions.map { $0.id }.joined(separator: ",")
        return "\(sessionIds)-\(searchText)"
    }

    private var filteredSessions: [Session] {
        if searchText.isEmpty {
            return dataManager.recentSessions
        } else {
            return dataManager.recentSessions.filter { session in
                let title = session.title ?? ""
                let prompt = session.prompt
                return title.localizedCaseInsensitiveContains(searchText) || prompt.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    /// Sessions from today (uses cached value)
    private var todaySessions: [Session] {
        cachedTodaySessions
    }

    /// Sessions from this week excluding today (uses cached value)
    private var thisWeekSessions: [Session] {
        cachedThisWeekSessions
    }

    /// All other sessions before this week (uses cached value)
    private var allOtherSessions: [Session] {
        cachedOlderSessions
    }

    /// Limited view of allOtherSessions for display
    private var displayedAllSessions: [Session] {
        Array(allOtherSessions.prefix(allSectionLimit))
    }

    /// Whether there are more sessions to load in "Older" section
    /// Shows button if there are more local items OR more data available from API
    private var hasMoreAllSessions: Bool {
        allOtherSessions.count > allSectionLimit || dataManager.hasMoreSessions
    }

    /// All sessions currently displayed in order (Today + This Week + Older)
    /// Used for keyboard navigation
    private var allDisplayedSessions: [Session] {
        todaySessions + thisWeekSessions + displayedAllSessions
    }

    /// Recalculates cached session categories when data changes
    private func updateCachedSessions() {
        let filtered = filteredSessions

        cachedTodaySessions = filtered.filter { session in
            guard let timeString = session.updateTime ?? session.createTime,
                  let date = Date.parseAPIDate(timeString) else {
                return false
            }
            return date.isToday
        }

        cachedThisWeekSessions = filtered.filter { session in
            guard let timeString = session.updateTime ?? session.createTime,
                  let date = Date.parseAPIDate(timeString) else {
                return false
            }
            return date.isThisWeekButNotToday
        }

        cachedOlderSessions = filtered.filter { session in
            guard let timeString = session.updateTime ?? session.createTime,
                  let date = Date.parseAPIDate(timeString) else {
                // If we can't parse the date, include in "Older"
                return true
            }
            return date.isBeforeThisWeek
        }

        lastCacheKey = cacheKey
    }

    /// Navigate to the previous session in the list
    private func selectPreviousSession() {
        let sessions = allDisplayedSessions
        guard !sessions.isEmpty else { return }

        if let currentId = selectedSessionId,
           let currentIndex = sessions.firstIndex(where: { $0.id == currentId }),
           currentIndex > 0 {
            let previousSession = sessions[currentIndex - 1]
            selectedSessionId = previousSession.id
            onSessionSelected(previousSession)
        } else if selectedSessionId == nil, let first = sessions.first {
            // If nothing selected, select the first session
            selectedSessionId = first.id
            onSessionSelected(first)
        }
    }

    /// Navigate to the next session in the list
    private func selectNextSession() {
        let sessions = allDisplayedSessions
        guard !sessions.isEmpty else { return }

        if let currentId = selectedSessionId,
           let currentIndex = sessions.firstIndex(where: { $0.id == currentId }),
           currentIndex < sessions.count - 1 {
            let nextSession = sessions[currentIndex + 1]
            selectedSessionId = nextSession.id
            onSessionSelected(nextSession)
        } else if selectedSessionId == nil, let first = sessions.first {
            // If nothing selected, select the first session
            selectedSessionId = first.id
            onSessionSelected(first)
        }
    }

    /// Top padding for the sidebar on macOS 26+ to account for content extending under toolbar
    private var tahoeTopPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 52 // Standard macOS toolbar height
        }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.textSecondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.thinMaterial)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? AppColors.accent : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.top, tahoeTopPadding)
            .padding(.bottom, 8)

            if dataManager.isLoadingSessions && dataManager.recentSessions.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if dataManager.recentSessions.isEmpty {
                Text("No recent sessions.")
                    .foregroundColor(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List {
                    // Today Section
                    if !todaySessions.isEmpty {
                        Section {
                            ForEach(todaySessions) { session in
                                sessionRow(for: session)
                            }
                        } header: {
                            sectionHeader("Today")
                        }
                    }

                    // This Week Section
                    if !thisWeekSessions.isEmpty {
                        Section {
                            ForEach(thisWeekSessions) { session in
                                sessionRow(for: session)
                            }
                        } header: {
                            sectionHeader("This Week")
                        }
                    }

                    // Older Section (with pagination and deferred loading)
                    // OPTIMIZATION: Defer rendering to prioritize Today/This Week sections
                    if isOlderSectionLoaded && (!displayedAllSessions.isEmpty || dataManager.hasMoreSessions) {
                        Section {
                            ForEach(displayedAllSessions) { session in
                                sessionRow(for: session)
                            }

                            // Load More button - shows when there are more local items or more API data
                            if hasMoreAllSessions {
                                loadMoreButton
                            }
                        } header: {
                            sectionHeader("Older")
                        }
                    } else if !isOlderSectionLoaded && (!cachedOlderSessions.isEmpty || dataManager.hasMoreSessions) {
                        // Placeholder while older section loads
                        Section {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        } header: {
                            sectionHeader("Older")
                        }
                    }
                }
                .listStyle(SidebarListStyle())
                .scrollContentBackground(.hidden)
                .focusable()
                .focused($isListFocused)
                .onKeyPress(.upArrow) {
                    selectPreviousSession()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    selectNextSession()
                    return .handled
                }
            }
        }
        .background(Color.clear)
        .onChange(of: searchText) { _ in
            // Reset pagination when search changes
            allSectionLimit = allSectionPageSize
            updateCachedSessions()
        }
        .onChange(of: dataManager.recentSessions.count) { _ in
            // Update cache when sessions list changes
            if cacheKey != lastCacheKey {
                updateCachedSessions()
            }
        }
        .onAppear {
            // Initial cache population
            if cachedTodaySessions.isEmpty && cachedThisWeekSessions.isEmpty && cachedOlderSessions.isEmpty {
                updateCachedSessions()
            }

            // OPTIMIZATION: Defer "Older" section loading to prioritize Today/This Week
            if !isOlderSectionLoaded {
                DispatchQueue.main.async {
                    isOlderSectionLoaded = true
                }
            }
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func sessionRow(for session: Session) -> some View {
        SidebarRow(
            session: session,
            isSelected: Binding(
                get: { selectedSessionId == session.id },
                set: { isSelected in
                    if isSelected {
                        selectedSessionId = session.id
                        onSessionSelected(session)
                    }
                }
            )
        )
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 0))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(AppColors.textSecondary)
            .textCase(.uppercase)
    }

    private var loadMoreButton: some View {
        Button(action: {
            allSectionLimit += allSectionPageSize
            // Also trigger loading more sessions from the backend
            Task {
                await dataManager.loadMoreData()
            }
        }) {
            HStack {
                Spacer()
                if dataManager.isFetchingNextPage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Load More")
                        .font(.caption)
                        .foregroundColor(AppColors.accent)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(dataManager.isFetchingNextPage)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}
