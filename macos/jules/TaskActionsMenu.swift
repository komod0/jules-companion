import SwiftUI

struct TaskActionsMenu: View {
    @EnvironmentObject var dataManager: DataManager
    let session: Session
    let isRowHovering: Bool

    // Helper to check if a PR exists
    private var hasPR: Bool {
        return session.outputs?.contains(where: { $0.pullRequest != nil }) ?? false
    }

    var body: some View {
        Menu {
            // --- Menu Actions ---
            Button("View Web Session") {
                if let url = session.url {
                    dataManager.openURL(url)
                }
            }
            .disabled(session.url == nil)


            // Check if PR exists
            if let outputs = session.outputs,
               let pr = outputs.first(where: { $0.pullRequest != nil })?.pullRequest {
                Button("View PR") {
                    dataManager.openURL(pr.url)
                }

                Divider()
            }

            Button("Merge Local") {
                dataManager.mergeLocal(session: session) { success in
                    if success {
                        FlashMessageManager.shared.show(message: "Merged", type: .success)
                    }
                }
            }
            .disabled(session.latestDiffs == nil)

        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundColor(AppColors.textSecondary)
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .contentShape(Rectangle())
        .opacity(isRowHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isRowHovering)
    }
}
