import SwiftUI

struct ActivityTimestamp: View {
    let label: String
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundColor(AppColors.textSecondary)
            Text(date.activityTimestampDisplay())
                .foregroundColor(AppColors.textSecondary)
        }
        .font(.system(size: 11))
    }
}
