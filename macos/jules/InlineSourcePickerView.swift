//
//  InlineSourcePickerView.swift
//  jules
//
//  Inline source (repo/branch) picker with searchable dropdowns
//

import SwiftUI

/// A reusable dropdown menu component with search capability
struct SearchableDropdownMenu<Item: Identifiable>: View where Item: Equatable {
    let items: [Item]
    let selectedItem: Item?
    let title: String
    let searchPlaceholder: String
    let displayName: (Item) -> String
    let onSelect: (Item) -> Void
    let onDismiss: () -> Void
    let footerAction: (() -> Void)?
    let footerTitle: String?
    var isLoading: Bool = false
    /// Optional closure that returns the text to search against (defaults to displayName if nil)
    var searchableText: ((Item) -> String)? = nil

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    /// Unique ID to force TextField recreation when dropdown reopens
    @State private var textFieldId: UUID = UUID()

    private var filteredItems: [Item] {
        if searchText.isEmpty {
            return items
        }
        // Use searchableText if provided, otherwise fall back to displayName
        let getSearchText = searchableText ?? displayName
        let searchTerms = searchText.lowercased().split(separator: " ").map { String($0) }
        return items.filter { item in
            let text = getSearchText(item).lowercased()
            // Match if all search terms are found anywhere in the text
            return searchTerms.allSatisfy { term in
                text.contains(term)
            }
        }
    }

    /// Safely clamp selectedIndex to valid range for current filtered items
    private var clampedSelectedIndex: Int {
        guard !filteredItems.isEmpty else { return 0 }
        return min(max(0, selectedIndex), filteredItems.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary.opacity(0.6))

                TextField(searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textPrimary)
                    .focused($isSearchFocused)
                    .id(textFieldId)
                    .onExitCommand {
                        // Handle escape key from within the TextField
                        onDismiss()
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial)

            Divider()
                .background(AppColors.separator.opacity(0.3))

            // Scrollable list with loader overlay
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        if filteredItems.isEmpty {
                            // Empty state when no items match search
                            VStack(spacing: 8) {
                                Text(searchText.isEmpty ? "No items available" : "No matching items")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    // When searching with a custom searchableText, show that text to explain why items match
                                    let showTitle = (!searchText.isEmpty && searchableText != nil) ? searchableText!(item) : displayName(item)
                                    DropdownItemRow(
                                        title: showTitle,
                                        isSelected: selectedItem?.id == item.id,
                                        isHighlighted: index == clampedSelectedIndex,
                                        action: {
                                            onSelect(item)
                                            onDismiss()
                                        }
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    .onChange(of: clampedSelectedIndex) { newIndex in
                        // Scroll to the item's ID (not index) to match the .id(item.id) on rows
                        if newIndex < filteredItems.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 200)

                // Loading indicator in bottom right corner
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                        .padding(8)
                }
            }

            // Footer action (e.g., "Add A repository")
            if let footerAction = footerAction, let footerTitle = footerTitle {
                Divider()
                    .background(AppColors.separator.opacity(0.3))

                Button(action: footerAction) {
                    Text(footerTitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .inputOverlayStyle(cornerRadius: 8, useMaterial: true)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .onAppear {
            // Reset state for fresh dropdown
            searchText = ""
            selectedIndex = 0
            textFieldId = UUID()

            // Set initial selected index to current selection
            if let selected = selectedItem,
               let index = items.firstIndex(where: { $0.id == selected.id }) {
                selectedIndex = index
            }

            // Delay focus to ensure view is fully rendered
            // Use Task with MainActor to avoid NSHostingView reentrant layout warnings
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                isSearchFocused = true
            }
        }
        .onKeyPress(.downArrow) {
            let maxIndex = filteredItems.count - 1
            if maxIndex >= 0 && selectedIndex < maxIndex {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.return) {
            if !filteredItems.isEmpty {
                onSelect(filteredItems[clampedSelectedIndex])
                onDismiss()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onChange(of: searchText) { _ in
            selectedIndex = 0
        }
    }
}

/// A single row in the dropdown menu
struct DropdownItemRow: View {
    let title: String
    let isSelected: Bool
    let isHighlighted: Bool
    let action: () -> Void
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppColors.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isHighlighted || isHovering) ? AppColors.accent.opacity(0.15) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            onHover?(hovering)
        }
    }
}

/// Inline source picker button that shows the selected value
struct InlinePickerButton: View {
    let icon: String?
    let title: String
    let isEnabled: Bool
    var useSecondaryTextColor: Bool = false
    var fontSize: CGFloat = 12
    let action: () -> Void

    @State private var isHovering = false

    private var chevronSize: CGFloat {
        // Scale chevron proportionally to font size
        fontSize * 0.75
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // Optional SF Symbol icon
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: fontSize))
                        .foregroundColor(isEnabled ? AppColors.textSecondary : AppColors.textSecondary.opacity(0.5))
                }

                // Title
                Text(title)
                    .font(.system(size: fontSize))
                    .foregroundColor(isEnabled ? (useSecondaryTextColor ? AppColors.textSecondary : AppColors.textPrimary) : AppColors.textSecondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Dropdown indicator
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundColor(isEnabled ? AppColors.textSecondary : AppColors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering && isEnabled ? AppColors.accent.opacity(0.2) : AppColors.accent.opacity(0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusable(false) // Prevent Tab key from focusing this button
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

/// Which dropdown is currently active
enum SourcePickerDropdown {
    case none
    case repo
    case branch
}

/// Main inline source picker view - just the buttons, no dropdown overlays
struct InlineSourcePickerView: View {
    @EnvironmentObject var dataManager: DataManager
    @Binding var activeDropdown: SourcePickerDropdown
    var fontSize: CGFloat = 12

    /// Extract just the repo name from display name (strips owner prefix)
    private func repoDisplayName(_ source: Source) -> String {
        // displayName is already "owner/repo", we want just "repo"
        let fullName = source.displayName
        if let slashIndex = fullName.lastIndex(of: "/") {
            return String(fullName[fullName.index(after: slashIndex)...])
        }
        return fullName
    }

    /// Get the currently selected source
    private var selectedSource: Source? {
        guard let sourceId = dataManager.selectedSourceId else { return nil }
        return dataManager.sources.first { $0.id == sourceId }
    }

    /// Get the currently selected branch
    private var selectedBranch: GitHubBranch? {
        guard let branchName = dataManager.selectedBranchName else { return nil }
        return dataManager.branchesForSelectedSource.first { $0.displayName == branchName }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Repository picker button
            InlinePickerButton(
                icon: nil,
                title: selectedSource.map { repoDisplayName($0) } ?? "Repository",
                isEnabled: true,
                fontSize: fontSize,
                action: {
                    if activeDropdown == .repo {
                        activeDropdown = .none
                    } else {
                        // Fetch fresh sources when opening dropdown
                        dataManager.fetchSources()
                        activeDropdown = .repo
                    }
                }
            )

            // Branch picker button
            InlinePickerButton(
                icon: nil,
                title: selectedBranch?.displayName ?? "main",
                isEnabled: dataManager.selectedSourceId != nil && !dataManager.branchesForSelectedSource.isEmpty,
                useSecondaryTextColor: true,
                fontSize: fontSize,
                action: {
                    if activeDropdown == .branch {
                        activeDropdown = .none
                    } else {
                        // Fetch fresh sources (which include branches) when opening dropdown
                        dataManager.fetchSources()
                        activeDropdown = .branch
                    }
                }
            )

            Spacer()
        }
    }
}

/// Dropdown menu view rendered below the text editor
struct SourcePickerDropdownView: View {
    @EnvironmentObject var dataManager: DataManager
    @Binding var activeDropdown: SourcePickerDropdown

    /// Extract just the repo name from display name (strips owner prefix)
    private func repoDisplayName(_ source: Source) -> String {
        let fullName = source.displayName
        if let slashIndex = fullName.lastIndex(of: "/") {
            return String(fullName[fullName.index(after: slashIndex)...])
        }
        return fullName
    }

    /// Get the currently selected source
    private var selectedSource: Source? {
        guard let sourceId = dataManager.selectedSourceId else { return nil }
        return dataManager.sources.first { $0.id == sourceId }
    }

    /// Get the currently selected branch
    private var selectedBranch: GitHubBranch? {
        guard let branchName = dataManager.selectedBranchName else { return nil }
        return dataManager.branchesForSelectedSource.first { $0.displayName == branchName }
    }

    var body: some View {
        Group {
            if activeDropdown == .repo {
                SearchableDropdownMenu(
                    items: dataManager.sources,
                    selectedItem: selectedSource,
                    title: "Repository",
                    searchPlaceholder: "Search Repositories",
                    displayName: { repoDisplayName($0) },
                    onSelect: { source in
                        dataManager.selectedSourceId = source.id
                    },
                    onDismiss: { activeDropdown = .none },
                    footerAction: nil,
                    footerTitle: nil,
                    isLoading: dataManager.isLoadingSources,
                    // Search against full "owner/repo" name so users can search by owner or repo name
                    searchableText: { $0.displayName }
                )
                .frame(maxWidth: .infinity)
            } else if activeDropdown == .branch {
                SearchableDropdownMenu(
                    items: dataManager.branchesForSelectedSource,
                    selectedItem: selectedBranch,
                    title: "Branch",
                    searchPlaceholder: "Search Branches",
                    displayName: { $0.displayName },
                    onSelect: { branch in
                        dataManager.selectedBranchName = branch.displayName
                    },
                    onDismiss: { activeDropdown = .none },
                    footerAction: nil,
                    footerTitle: nil,
                    isLoading: dataManager.isLoadingSources
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Make GitHubBranch Identifiable for dropdown

extension GitHubBranch: Identifiable {
    public var id: String { displayName }
}

// MARK: - Preview

#if DEBUG
struct InlineSourcePickerView_Previews: PreviewProvider {
    @State static var dropdown: SourcePickerDropdown = .none

    static var previews: some View {
        VStack {
            InlineSourcePickerView(activeDropdown: $dropdown)
                .environmentObject(DataManager())
            SourcePickerDropdownView(activeDropdown: $dropdown)
                .environmentObject(DataManager())
        }
        .padding()
        .frame(width: 400)
        .background(AppColors.background)
    }
}
#endif
