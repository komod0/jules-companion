import SwiftUI

struct SessionHeaderView: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(session.title ?? session.prompt)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Metadata Row
            HStack(spacing: 8) {
                // Date
                if let timeString = session.updateTime ?? session.createTime,
                   let date = Date.parseAPIDate(timeString) {
                    Text(dateFormatted(date))
                }

                Text("·")

                // Status (Added per review to ensure "current status" is covered)
                // Use a simplified status text if not implicit in the view.
                // The prompt asked for "current status", so we include it.
                // If the state is implied by other things, we might hide it, but explicit is safer.
                Text(statusText)

                Text("·")

                // Source (Repo)
                Text(repoName)

                // Branch
                if let branch = session.sourceContext?.githubRepoContext?.startingBranch {
                    Text("·")
                    Text(branch)
                }

                // Stats
                if let statsSummary = session.gitStatsSummary {
                    Text("·")
                    Text(attributedGitStats(from: statsSummary))
                }
            }
            .font(.system(size: 13))
            .foregroundColor(AppColors.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.background)
    }

    private var statusText: String {
        return session.state.displayName
    }

    private var repoName: String {
        guard let source = session.sourceContext?.source else { return "Unknown" }
        // Format: sources/github/owner/repo -> owner/repo
        let name = source.replacingOccurrences(of: "sources/github/", with: "")
        return name
    }

    private func dateFormatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func attributedGitStats(from statsSummary: String) -> AttributedString {
        var attributedString = AttributedString()
        let components = statsSummary.split(separator: " ")
        for (index, component) in components.enumerated() {
            var part = AttributedString(String(component))
            if component.starts(with: "+") {
                part.foregroundColor = AppColors.linesAdded
            } else if component.starts(with: "-") {
                part.foregroundColor = AppColors.linesRemoved
            }
            attributedString.append(part)
            if index < components.count - 1 {
                attributedString.append(AttributedString(" "))
            }
        }
        return attributedString
    }
}
