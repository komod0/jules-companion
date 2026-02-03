//
//  ConflictBadge.swift
//  jules
//
//  Yellow badge component for showing conflict counts
//

import SwiftUI

// MARK: - Conflict Badge

/// A yellow badge that displays the number of conflicts
struct ConflictBadge: View {
    let count: Int
    var fontSize: CGFloat = 10
    var showZero: Bool = false

    private var shouldShow: Bool {
        count > 0 || showZero
    }

    private var formattedCount: String {
        if count >= 100 {
            return "99+"
        }
        return "\(count)"
    }

    var body: some View {
        if shouldShow {
            Text(formattedCount)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundColor(count > 0 ? AppColors.conflictBadgeText : AppColors.textSecondary)
                .padding(.horizontal, count >= 10 ? 5 : 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(count > 0 ? AppColors.conflictBadgeBackground : AppColors.backgroundSecondary)
                )
                .overlay(
                    Capsule()
                        .stroke(count > 0 ? AppColors.conflictBadgeBorder : Color.clear, lineWidth: 1)
                )
        }
    }
}

// MARK: - Merge Button Badge

/// A larger badge specifically for the merge button in the toolbar
struct MergeBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(count > 0 ? AppColors.conflictBadgeText : .white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(count > 0 ? AppColors.conflictBadgeBackground : AppColors.running)
        )
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            ConflictBadge(count: 0, showZero: true)
            ConflictBadge(count: 1)
            ConflictBadge(count: 5)
            ConflictBadge(count: 12)
            ConflictBadge(count: 99)
            ConflictBadge(count: 150)
        }

        HStack(spacing: 16) {
            MergeBadge(count: 3)
            MergeBadge(count: 0)
        }
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
