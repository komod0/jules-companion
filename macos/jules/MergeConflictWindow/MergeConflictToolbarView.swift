//
//  MergeConflictToolbarView.swift
//  jules
//
//  Toolbar view for the merge conflict window with pagination and merge button
//

import SwiftUI

// MARK: - Preference Key for Merge Button Width

/// PreferenceKey to measure the merge button width for centering calculation
private struct MergeButtonWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Merge Conflict Toolbar View

struct MergeConflictToolbarView: View {
    @ObservedObject var store: MergeConflictStore
    let onClose: () -> Void

    // Hover states
    @State private var isMergeHovering = false

    // Track merge button width for centering calculation
    @State private var mergeButtonWidth: CGFloat = 0

    // Height for custom toolbar content
    static let toolbarHeight: CGFloat = 52

    // Traffic light buttons width (close/minimize/zoom)
    private static let trafficLightWidth: CGFloat = 70

    var body: some View {
        ZStack {
            // Background layer - allows window dragging
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Three-column layout for proper centering
            // The title should be centered in the WINDOW, not the toolbar view.
            // Since traffic lights (70px) are outside our frame on the left,
            // we need to balance: left spacer width = merge button width - traffic light width
            HStack(spacing: 0) {
                // Left spacer: sized to balance the right side content minus traffic light offset
                // This makes the center section appear centered relative to the window
                Spacer()
                    .frame(width: max(0, mergeButtonWidth + 16 - Self.trafficLightWidth))

                Spacer()

                // Center section: Title and conflict counter
                VStack(spacing: 2) {
                    Text("Merge Conflicts")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    if store.totalConflicts > 0 {
                        Text(conflictProgressText)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                .allowsHitTesting(false)

                Spacer()

                // Right section: Merge button with badge
                mergeButton
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: MergeButtonWidthKey.self,
                                value: geo.size.width
                            )
                        }
                    )
                    .padding(.trailing, 16)
            }
            .onPreferenceChange(MergeButtonWidthKey.self) { width in
                mergeButtonWidth = width
            }
        }
        .frame(height: Self.toolbarHeight)
    }

    // MARK: - Merge Button

    private var mergeButton: some View {
        Button(action: { store.completeMerge() }) {
            HStack(spacing: 8) {
                if store.isMerging {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 14, height: 14) // Fixed frame to avoid floating-point precision issues with scaleEffect
                } else {
                    Image(systemName: store.allConflictsResolved ? "checkmark.circle.fill" : "arrow.triangle.merge")
                        .font(.system(size: 14, weight: .medium))
                }

                Text("Merge")
                    .font(.system(size: 13, weight: .semibold))

                // Show badge with remaining conflicts
                if !store.allConflictsResolved {
                    MergeBadge(count: store.totalUnresolvedConflicts)
                }
            }
            .foregroundColor(mergeButtonTextColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(mergeButtonBackgroundColor)
            )
            .opacity(store.allConflictsResolved && !store.isMerging ? (isMergeHovering ? 1.0 : 0.9) : 1.0)
            .scaleEffect(isMergeHovering && store.allConflictsResolved ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!store.allConflictsResolved || store.isMerging)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isMergeHovering = hovering
            }
        }
        .help(store.allConflictsResolved ? "Complete merge" : "Resolve all conflicts to merge")
    }

    // MARK: - Computed Properties

    private var conflictProgressText: String {
        let resolved = store.totalConflicts - store.totalUnresolvedConflicts
        if resolved == store.totalConflicts {
            return "All conflicts resolved"
        }
        return "\(resolved) of \(store.totalConflicts) resolved"
    }

    private var mergeButtonTextColor: Color {
        if store.allConflictsResolved {
            // Match SplitButton: black text in dark mode, white text in light mode
            return AppColors.buttonText
        }
        return AppColors.textSecondary
    }

    private var mergeButtonBackgroundColor: Color {
        if store.allConflictsResolved {
            // Match SplitButton: white background in dark mode, dark background in light mode
            return AppColors.buttonBackground
        }
        return AppColors.backgroundSecondary
    }
}

// MARK: - Preview

#Preview {
    let store = MergeConflictStore()
    store.loadTestData()

    return VStack {
        MergeConflictToolbarView(store: store, onClose: {})
            .background(AppColors.background)
    }
    .frame(width: 800, height: 52)
}
