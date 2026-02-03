//
//  MergeConflictSidebar.swift
//  jules
//
//  Sidebar view showing list of files with conflicts
//

import SwiftUI
import Devicon

// MARK: - Merge Conflict Sidebar

struct MergeConflictSidebar: View {
    @ObservedObject var store: MergeConflictStore

    /// Top padding for the sidebar on macOS 26+ to account for content extending under toolbar
    private var tahoeTopPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 52 // Standard macOS toolbar height
        }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File list
            if store.files.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(AppColors.running)

                    Text("No conflicts found")
                        .font(.headline)
                        .foregroundColor(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, tahoeTopPadding)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(store.files.enumerated()), id: \.element.id) { index, file in
                            ConflictFileRow(
                                file: file,
                                isSelected: store.selectedFileIndex == index,
                                onTap: {
                                    store.selectFile(at: index)
                                }
                            )
                        }
                    }
                    .padding(.top, tahoeTopPadding)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 250)
        .background(Color.clear)
    }

}

// MARK: - Conflict File Row

struct ConflictFileRow: View {
    let file: ConflictFile
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // File type icon
                fileIcon
                    .frame(width: 16, height: 16)

                // File name
                Text(file.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Conflict count badge
                if file.unresolvedConflictCount > 0 {
                    ConflictBadge(count: file.unresolvedConflictCount, fontSize: 10)
                } else {
                    // Show checkmark when all resolved
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.running)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? AppColors.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Computed Properties

    private var backgroundColor: Color {
        if isSelected {
            return AppColors.accent.opacity(0.15)
        }
        if isHovering {
            return AppColors.backgroundSecondary.opacity(0.5)
        }
        return Color.clear
    }

    @ViewBuilder
    private var fileIcon: some View {
        let ext = URL(fileURLWithPath: file.name).pathExtension
        if let image = Devicon.forExtension(".\(ext)") {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(AppColors.textSecondary)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
        }
    }
}

// MARK: - Preview

#Preview {
    let store = MergeConflictStore()
    store.loadTestData()

    return MergeConflictSidebar(store: store)
        .frame(width: 250, height: 400)
        .background(AppColors.backgroundSecondary)
}
