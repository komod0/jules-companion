import SwiftUI
import AppKit

struct AppHeaderView: View {
    @EnvironmentObject var dataManager: DataManager

    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            // Offline banner
            if !dataManager.isOnline {
                OfflineBannerView(pendingCount: dataManager.pendingSessionCount)
            }

            HStack(spacing: 8) {
                Image("jules-icon-purple")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(AppColors.accent)

                Text("Jules")
                    .font(.headline)
                    .foregroundColor(AppColors.accent)

                // Pending sessions badge (shown when online with pending items)
                if dataManager.isOnline && dataManager.pendingSessionCount > 0 {
                    PendingSessionsBadge(count: dataManager.pendingSessionCount, isSyncing: dataManager.isSyncingPendingSessions)
                }

                Spacer()

                Button(action: {
                    dataManager.isPopoverExpanded.toggle()
                    // Notify AppDelegate to resize
                    NotificationCenter.default.post(name: .togglePopoverSize, object: dataManager.isPopoverExpanded)
                }) {
                    Image(systemName: dataManager.isPopoverExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(AppColors.textSecondary)
                }
                .buttonStyle(.plain)

                SettingsLink {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, verticalPadding)
            .padding(.bottom, verticalPadding)
        }
    }
}

// MARK: - Offline Banner View

struct OfflineBannerView: View {
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12))

            if pendingCount > 0 {
                Text("Offline - \(pendingCount) task\(pendingCount == 1 ? "" : "s") pending")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text("Offline - Tasks will sync when connected")
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.9))
    }
}

// MARK: - Pending Sessions Badge

struct PendingSessionsBadge: View {
    let count: Int
    let isSyncing: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isSyncing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
            }

            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(isSyncing ? Color.blue : Color.orange)
        )
        .help(isSyncing ? "Syncing pending tasks..." : "\(count) task\(count == 1 ? "" : "s") waiting to sync")
    }
}
