import SwiftUI

struct SidebarRow: View {
    @EnvironmentObject var dataManager: DataManager
    let session: Session
    @Binding var isSelected: Bool
    @State private var isHovering = false

    /// Returns the most up-to-date session from DataManager, or falls back to the passed session
    /// Uses O(1) dictionary lookup instead of O(n) array search
    private var currentSession: Session {
        dataManager.sessionsById[session.id] ?? session
    }

    var body: some View {
        HStack(spacing: 8) {
            // Status icon - use accent color if unviewed, otherwise state color
            if (!currentSession.isViewed) {
                Circle()
                    .fill(AppColors.accent)
                    .frame(width: 4, height: 4)
            }
                

            Text(currentSession.title ?? "Untitled Session")
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 8)

            Spacer()
        }
        .padding(.leading, currentSession.isViewed ? 16 : 4)
        .padding(.trailing, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AppColors.accent.opacity(0.2) : (isHovering ? AppColors.backgroundSecondary.opacity(0.9) : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            dataManager.markSessionAsViewed(currentSession)
            isSelected = true
        }
    }
}
