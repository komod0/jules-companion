import SwiftUI

/// A sticky status view that shows session state and last updated time.
/// Displays in expanded form for active sessions (icon + status + time),
/// or collapsed form for inactive sessions (icon + time only).
/// Also supports flash messages for transient status updates.
/// When session is nil, shows a "Waiting..." state for new session creation.
struct StickyStatusView: View {
    let session: Session?

    @StateObject private var flashManager = StickyStatusFlashManager.shared

    /// Timer to refresh the time display every second
    @State private var timeRefreshTrigger: Date = Date()

    /// Timer publisher for live time updates
    private let timer = Timer.publish(every: 1, on: .main, in: .default).autoconnect()

    /// Whether the session needs frequent (per-second) time updates
    /// Only sessions actively working (queued, planning, in progress) need this precision
    /// Other states (completed, failed, awaiting feedback, paused) rely on normal polling
    private var needsFrequentTimeUpdates: Bool {
        guard let session = session else { return false }

        // Skip timer updates when DiffLoader is showing (60fps Metal rendering)
        // This avoids main thread contention between SwiftUI updates and Metal
        if !session.hasDiffsAvailable {
            return false
        }

        // Only active working states need per-second updates
        switch session.state {
        case .queued, .planning, .inProgress:
            // Still skip if the session is old (> 1 hour since last update)
            if let updateTimeString = session.updateTime ?? session.createTime,
               let updateDate = Date.parseAPIDate(updateTimeString),
               Date().timeIntervalSince(updateDate) > 3600 {
                return false
            }
            return true
        default:
            return false
        }
    }

    /// Whether we're in waiting mode (no session yet)
    private var isWaitingMode: Bool {
        session == nil
    }

    /// The current flash message for this session (if any)
    /// Uses newSessionKey when session is nil (for the new session form)
    private var flashMessage: StickyFlashMessage? {
        let key = session?.id ?? StickyStatusFlashManager.newSessionKey
        return flashManager.flashMessage(for: key)
    }

    /// Whether we're currently showing a flash message
    private var isShowingFlash: Bool {
        flashMessage != nil && !(flashMessage?.text.isEmpty ?? true)
    }

    /// Whether the session is active (not in a terminal state)
    private var isActiveSession: Bool {
        guard let session = session else { return true }
        return !session.state.isTerminal
    }

    /// The time ago string based on updateTime (or createTime as fallback)
    /// Uses timeRefreshTrigger to force recalculation every second
    private var timeAgoString: String {
        // Reference timeRefreshTrigger to force recalculation
        _ = timeRefreshTrigger
        guard let session = session else { return "" }
        if let updateTimeString = session.updateTime ?? session.createTime,
           let updateDate = Date.parseAPIDate(updateTimeString) {
            return updateDate.timeAgoDisplay()
        }
        return ""
    }

    /// The state title to display for active sessions (e.g., "IN_PROGRESS" → "In Progress")
    private var stateTitle: String {
        guard let session = session else { return "Waiting" }
        return session.state.displayName
    }

    var body: some View {
        HStack(spacing: 8) {
            if isShowingFlash, let flash = flashMessage {
                // Flash message content
                flashContentView(flash: flash)
            } else {
                // Normal status content
                normalContentView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isShowingFlash)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: flashMessage?.isSuccess)
        .onReceive(timer) { _ in
            // Only update per-second for actively working sessions
            // Completed/failed/waiting sessions update via normal polling
            guard needsFrequentTimeUpdates else { return }
            timeRefreshTrigger = Date()
        }
        .onChange(of: session?.state) { _ in
            // When session state changes, refresh the time display
            // For completed sessions, this captures the final updateTime
            timeRefreshTrigger = Date()
        }
    }

    // MARK: - Flash Content View

    @ViewBuilder
    private func flashContentView(flash: StickyFlashMessage) -> some View {
        HStack(spacing: 8) {
            if flash.isSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .foregroundColor(AppColors.backgroundDark)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }

            Text(flash.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(flash.isSuccess ? AppColors.backgroundDark : AppColors.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Normal Content View

    private var normalContentView: some View {
        Group {
            if isWaitingMode {
                // Waiting mode: show ellipsis icon and "Waiting..." text
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundColor(AppColors.textSecondary)

                    Text("Waiting To Start...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                }
            } else if let session = session {
                // Left side: icon and optional status title
                HStack(spacing: 8) {
                    // Use animated pulsing circle for inProgress/planning states
                    if session.state == .inProgress || session.state == .planning {
                        PulsingCircleView(size: 12, color: AppColors.accent)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: session.state.iconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                            .foregroundColor(session.state.color)
                    }

                    if isActiveSession {
                        Text(stateTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                            .lineLimit(1)
                    }
                }

                // Separator line
                Divider()
                    .frame(height: 14)

                // Right side: time ago
                Text(timeAgoString)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }

    // MARK: - Background View

    @ViewBuilder
    private var backgroundView: some View {
        if isShowingFlash, let flash = flashMessage, flash.isSuccess {
            AppColors.running
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}
