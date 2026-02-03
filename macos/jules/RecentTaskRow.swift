import SwiftUI

struct RecentTaskRow: View {
    @EnvironmentObject var dataManager: DataManager
    let session: Session
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    @State private var isHoveringRow: Bool = false

    /// Returns the most up-to-date session from DataManager, or falls back to the passed session
    /// Uses O(1) dictionary lookup instead of O(n) array search
    private var currentSession: Session {
        dataManager.sessionsById[session.id] ?? session
    }

    private var timeAgoString: String {
        guard let timeString = currentSession.updateTime ?? currentSession.createTime else { return "" }
        return Date.parseAPIDate(timeString)?.timeAgoDisplay() ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {

            // Left side content: Prompt + Subtitle
            VStack(alignment: .leading, spacing: 5) {
                Text(currentSession.title ?? currentSession.prompt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(dataManager.isPopoverExpanded ? 1 : 2)
                    .truncationMode(.tail)

                TaskSubtitleView(
                    session: currentSession,
                    showUnviewedIndicator: !currentSession.isViewed,
                    gitStatsSummary: currentSession.gitStatsSummary,
                    isHighlighted: isHoveringRow || isSelected
                )

            }

            Spacer(minLength: 8)

            // Right side content: Time ago and menu (bottom-aligned)
            VStack(alignment: .trailing, spacing: 4) {
                // Time ago at top
                if !timeAgoString.isEmpty {
                    Text(timeAgoString)
                        .font(.caption)
                        .foregroundColor(AppColors.textSecondary)
                }

                Spacer(minLength: 0)

                // Menu trigger at bottom
                TaskActionsMenu(session: currentSession, isRowHovering: isHoveringRow || isSelected)

            }
            .padding(.vertical, 3)

        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7.5)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                Rectangle()
                    .fill(AppColors.accent.opacity(0.15))
                    .overlay(
                        Rectangle()
                            .strokeBorder(AppColors.accent.opacity(0.3))
                    )
            } else if isHoveringRow {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.accent.opacity(0.10))                 // <- key: material, not opaque color
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(AppColors.accent.opacity(0.15)) // subtle edge for contrast
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in isHoveringRow = hovering }
        .onTapGesture {
            #if DEBUG
            print("[RecentTaskRow] Tap detected on session: \(currentSession.id) at \(CFAbsoluteTimeGetCurrent())")
            #endif
            if let onSelect = onSelect {
                onSelect()
            } else {
                // Default behavior when no onSelect provided
                dataManager.markSessionAsViewed(currentSession)
                dataManager.ensureActivities(for: currentSession)
                NotificationCenter.default.post(name: .showChatWindow, object: currentSession)
            }
        }
    }
}
