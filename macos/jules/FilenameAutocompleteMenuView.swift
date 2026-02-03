import SwiftUI
import Devicon

/// View displaying filename autocomplete suggestions.
/// Highlights the matched prefix in each suggestion.
struct FilenameAutocompleteMenuView: View {
    @ObservedObject var autocompleteManager: FilenameAutocompleteManager

    /// Callback when a suggestion is selected
    var onSelect: (String) -> Void

    /// Whether to position the menu above or below the text field
    let positionAbove: Bool

    /// Identifier for this view's owner - menu only shows when this matches the manager's currentViewOwnerId.
    /// If nil, the menu shows whenever autocomplete is active (legacy behavior).
    var viewOwnerId: String? = nil

    /// Whether this menu should show based on ownership
    private var shouldShow: Bool {
        guard autocompleteManager.isAutocompleteActive && !autocompleteManager.suggestions.isEmpty else {
            return false
        }
        // If viewOwnerId is set, only show if this view owns the autocomplete session
        if let ownerId = viewOwnerId {
            return autocompleteManager.isViewOwner(ownerId)
        }
        return true
    }

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(autocompleteManager.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        isSelected: index == autocompleteManager.selectedIndex,
                        onTap: {
                            onSelect(suggestion.filename)
                        }
                    )

                    if index < autocompleteManager.suggestions.count - 1 {
                        Rectangle()
                            .fill(AppColors.separator.opacity(0.3))
                            .frame(height: 1)
                    }
                }
            }
            .inputOverlayStyle(cornerRadius: 6, useMaterial: true)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A single suggestion row with highlighted match
struct SuggestionRow: View {
    let suggestion: FilenameAutocompleteManager.AutocompleteSuggestion
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // File icon
                fileIcon                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: 16)

                // Filename with highlighted prefix
                highlightedFilename
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .truncationMode(.tail)
                    .lineLimit(1)

                Spacer()

                // Tab hint for selected item
                if isSelected {
                    Text("Tab")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppColors.textPrimary.opacity(0.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppColors.accent .opacity(0.3))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppColors.accent.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false) // Prevent Tab from focusing suggestion buttons
    }

    /// Build the filename text with the matched prefix highlighted
    private var highlightedFilename: Text {
        let filename = suggestion.filename
        let prefix = suggestion.matchedPrefix

        // Find the actual matched portion (case-insensitive)
        let lowercasedFilename = filename.lowercased()
        let lowercasedPrefix = prefix.lowercased()

        guard lowercasedFilename.hasPrefix(lowercasedPrefix) else {
            // No match found, return plain text
            return Text(filename)
                .foregroundColor(AppColors.textPrimary)
        }

        // Split at the match boundary
        let matchEndIndex = filename.index(filename.startIndex, offsetBy: prefix.count)
        let matchedPart = String(filename[..<matchEndIndex])
        let remainingPart = String(filename[matchEndIndex...])

        // Build styled text
        return Text(matchedPart)
            .foregroundColor(AppColors.accent)
            .fontWeight(.semibold)
        + Text(remainingPart)
            .foregroundColor(AppColors.textPrimary)
    }

    @ViewBuilder
    private var fileIcon: some View {
        let ext = URL(fileURLWithPath: suggestion.filename).pathExtension
        if let image = Devicon.forExtension(".\(ext)") {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "doc")
        }
    }
}

// MARK: - Autocomplete Container

/// A container view that manages autocomplete menu positioning relative to a text editor.
/// Wraps content and shows the autocomplete menu in the specified position.
struct AutocompleteContainer<Content: View>: View {
    @ObservedObject var autocompleteManager: FilenameAutocompleteManager

    /// Whether to show the menu above the content
    let menuAbove: Bool

    /// Callback when a suggestion is selected
    var onSelect: (String) -> Void

    /// The content (typically the text editor)
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 4) {
            if menuAbove {
                autocompleteMenu
            }

            content()

            if !menuAbove {
                autocompleteMenu
            }
        }
    }

    @ViewBuilder
    private var autocompleteMenu: some View {
        FilenameAutocompleteMenuView(
            autocompleteManager: autocompleteManager,
            onSelect: onSelect,
            positionAbove: menuAbove
        )
        .transition(.opacity.combined(with: .move(edge: menuAbove ? .bottom : .top)))
        .animation(.easeInOut(duration: 0.15), value: autocompleteManager.isAutocompleteActive)
    }
}

// MARK: - Preview

#if DEBUG
struct FilenameAutocompleteMenuView_Previews: PreviewProvider {
    static var previews: some View {
        let manager = FilenameAutocompleteManager.shared

        VStack(spacing: 20) {
            Text("Autocomplete Preview")
                .font(.headline)

            // Simulate some suggestions
            FilenameAutocompleteMenuView(
                autocompleteManager: manager,
                onSelect: { filename in
                    print("Selected: \(filename)")
                },
                positionAbove: false
            )
            .frame(width: 300)
        }
        .padding()
        .onAppear {
            // Setup test data
            manager.registerRepository(repositoryId: "test-repo")
            manager.setActiveRepository("test-repo")
            if let cache = manager.getCache(for: "test-repo") {
                cache.addFromFileSystem([
                    "SettingsController.swift",
                    "SettingsView.swift",
                    "SettingsIcon.png",
                    "SessionManager.swift"
                ])
            }
            manager.updateSuggestions(for: "Sett")
        }
    }
}
#endif
