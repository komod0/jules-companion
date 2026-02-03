import SwiftUI

struct TaskSubtitleView: View {
    @EnvironmentObject var dataManager: DataManager
    @Environment(\.openURL) var openURL

    let session: Session
    var showUnviewedIndicator: Bool = false
    var gitStatsSummary: String? = nil
    var isHighlighted: Bool = false

    @State private var isHoveringDiffStats: Bool = false

    // Extract PR URL for linking diff stats
    private var prURL: URL? {
        guard let outputs = session.outputs,
              let pr = outputs.first(where: { $0.pullRequest != nil })?.pullRequest,
              let url = URL(string: pr.url) else {
            return nil
        }
        return url
    }

    /// Whether to use animated pulsing circle for active states
    private var shouldShowPulsingCircle: Bool {
        session.state == .inProgress || session.state == .planning
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Inline Status Icon - use animated pulsing circle for active states,
            // or SF Symbol with accent color if unviewed, otherwise state color
            if shouldShowPulsingCircle {
                PulsingCircleView(size: 10, color: AppColors.accent)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: session.state.iconName)
                    .font(.system(size: 10))
                    .foregroundColor(showUnviewedIndicator ? AppColors.accent : session.state.color)
            }

            // Status Text - highlight in accent color if completed and unviewed
            Text(statusText)
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundColor((session.state == .completed || session.state == .completedUnknown) && showUnviewedIndicator ? AppColors.accent : AppColors.textSecondary)

            // Git stats - linked to PR if available
            if let statsSummary = gitStatsSummary {
                if let url = prURL {
                    Button(action: {
                        openURL(url)
                    }) {
                        DiffStatsBadges(statsSummary: statsSummary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in isHoveringDiffStats = hovering }
                    .animation(.easeIn(duration: 0.1), value: isHoveringDiffStats)
                } else {
                    DiffStatsBadges(statsSummary: statsSummary)
                }
            }
        }
        .font(.caption)
        .padding(.top, 1)
        .foregroundColor(AppColors.textSecondary)
    }

    private var statusText: String {
        if session.state == .inProgress, let progressTitle = session.latestProgressTitle {
            return progressTitle
        }
        return session.state.displayName
    }
}
