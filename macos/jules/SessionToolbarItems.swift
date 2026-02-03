import SwiftUI

struct SessionToolbarActionsView: View {
    @EnvironmentObject var dataManager: DataManager
    @ObservedObject var selectionState: SessionSelectionState

    // We can also optionally take the initial session to fallback if selection is nil,
    // though selectionState should be initialized.
    let initialSession: Session

    @State private var selectedAction: SessionAction = .viewPR
    @State private var conflictCount: Int = 0
    @State private var conflictCheckTask: Task<Void, Never>?
    @State private var lastCheckedSessionId: String?

    enum SessionAction: String, CaseIterable, Identifiable {
        case viewPR = "View PR"
        case localMerge = "Local Merge"
        var id: String { rawValue }
    }

    /// Determines if the spark animation should be shown
    /// Only show for unviewed sessions with a PR when View PR is selected
    private func shouldShowSparkAnimation(for session: Session) -> Bool {
        return !session.isViewed &&
               selectedAction == .viewPR &&
               session.outputs?.compactMap({ $0.pullRequest }).first != nil
    }

    /// Determines if a PR is available for the session
    private func hasPullRequest(for session: Session) -> Bool {
        return session.outputs?.compactMap({ $0.pullRequest }).first != nil
    }

    /// Check for conflicts in the background and count them
    private func checkForConflicts(session: Session) {
        // Skip if we already checked this session
        guard lastCheckedSessionId != session.id else { return }

        conflictCheckTask?.cancel()
        conflictCheckTask = Task {
            // Run conflict check on background thread to avoid blocking UI
            let count = await Task.detached {
                return await MainActor.run {
                    dataManager.countConflicts(session: session)
                }
            }.value

            if !Task.isCancelled {
                lastCheckedSessionId = session.id
                conflictCount = count ?? 0
            }
        }
    }

    var body: some View {
        let currentSessionId = selectionState.selectedSessionId ?? initialSession.id
        // Try to find the session in recentSessions to get the latest state (like pullRequest, diffs, mergedLocallyAt)
        let session = dataManager.recentSessions.first(where: { $0.id == currentSessionId }) ?? initialSession
        let hasPR = hasPullRequest(for: session)

        // Only show when there's a PR link
        if hasPR {
            if session.isMergedLocally {
                MergedButton()
                    .transition(.asymmetric(
                        insertion: .scale.combined(with: .opacity),
                        removal: .scale.combined(with: .opacity)
                    ))
            } else {
                splitButtonView(for: session)
                    .transition(.asymmetric(
                        insertion: .scale.combined(with: .opacity),
                        removal: .scale.combined(with: .opacity)
                    ))
            }
        }
    }

    @ViewBuilder
    private func splitButtonView(for session: Session) -> some View {
        SplitButton(
            actions: SessionAction.allCases,
            selectedAction: $selectedAction,
            onTrigger: { action in
                switch action {
                case .viewPR:
                    if let pr = session.outputs?.compactMap({ $0.pullRequest }).first {
                        dataManager.openURL(pr.url)
                    }
                case .localMerge:
                    dataManager.mergeLocal(session: session) { _ in
                        // Session.mergedLocallyAt is updated by DataManager.mergeLocal on success
                        // The view will update via GRDB ValueObservation on recentSessions
                    }
                }
            },
            label: { action in action.rawValue },
            icon: { action in
                switch action {
                case .viewPR:
                    Image("github-mark")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                case .localMerge:
                    // Show conflict count badge or icon based on conflict status
                    if selectedAction == .localMerge && conflictCount > 0 {
                        // Replace icon with conflict count badge when there are conflicts
                        ConflictBadge(count: conflictCount, fontSize: 11)
                    } else {
                        // Show normal merge icon when no conflicts
                        Image(systemName: "arrow.down.circle")
                    }
                }
            },
            isEnabled: { action in
                switch action {
                case .viewPR:
                    return session.outputs?.compactMap({ $0.pullRequest }).first != nil
                case .localMerge:
                    return session.latestDiffs != nil && !session.latestDiffs!.isEmpty
                }
            }
        )
//        .sparkBorderCapsule(isActive: shouldShowSparkAnimation(for: session), lineWidth: 2)
        .onChange(of: selectedAction) { _, newAction in
            if newAction == .localMerge {
                checkForConflicts(session: session)
            }
        }
        .onChange(of: session.id) { _, _ in
            // Defer state updates to next run loop to prevent multiple updates per frame
            // when quickly paginating through sessions
            Task { @MainActor in
                // Reset state and re-check conflicts when session changes (pagination)
                lastCheckedSessionId = nil
                conflictCount = 0
                if selectedAction == .localMerge {
                    checkForConflicts(session: session)
                }
            }
        }
        .onAppear {
            if selectedAction == .localMerge {
                checkForConflicts(session: session)
            }
        }
    }
}

/// Yellow warning badge for conflicts (uses unified conflict badge colors)
struct ConflictWarningBadge: View {
    var body: some View {
        Circle()
            .fill(AppColors.conflictBadgeBackground)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(AppColors.conflictBadgeBorder, lineWidth: 1)
            )
    }
}

/// Animated "Merged" button shown after successful local merge
struct MergedButton: View {
    @Environment(\.colorScheme) private var colorScheme

    private var buttonHeight: CGFloat {
        if #available(macOS 26.0, *) {
            return colorScheme == .dark ? 32 : 38
        } else {
            return 30
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Merged")
                .fontWeight(.bold)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(AppColors.accent)
        }
        .foregroundColor(AppColors.buttonText)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppColors.buttonBackground)
        .clipShape(Capsule())
        .frame(height: buttonHeight)
    }
}

