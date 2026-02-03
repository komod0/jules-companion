//
//  DiffStatsBadges.swift
//  jules
//

import SwiftUI

struct DiffStatsBadges: View {
    let statsSummary: String
    var fontSize: CGFloat = 9

    private var parsedStats: (added: Int?, removed: Int?) {
        let components = statsSummary.split(separator: " ")
        var added: Int? = nil
        var removed: Int? = nil

        for component in components {
            if component.starts(with: "+"), let value = Int(component.dropFirst()) {
                added = value
            } else if component.starts(with: "-"), let value = Int(component.dropFirst()) {
                removed = value
            }
        }
        return (added, removed)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let added = parsedStats.added {
                DiffBadge(value: added, type: .added, fontSize: fontSize)
            }
            if let removed = parsedStats.removed {
                DiffBadge(value: removed, type: .removed, fontSize: fontSize)
            }
        }
    }
}

struct DiffBadge: View {
    let value: Int
    let type: DiffType
    var fontSize: CGFloat = 9

    private var formattedValue: String {
        if value >= 10_000 {
            // 10k, 11k, etc. (no decimal)
            return "\(value / 1000)k"
        } else if value >= 1_000 {
            // 2K, 2.5K, etc. (decimal only if non-zero)
            let thousands = Double(value) / 1000.0
            if value % 1000 == 0 {
                return "\(value / 1000)K"
            } else {
                return String(format: "%.1fK", thousands)
            }
        } else {
            return "\(value)"
        }
    }

    enum DiffType {
        case added
        case removed

        var textColor: Color {
            switch self {
            case .added: return AppColors.linesAdded
            case .removed: return AppColors.linesRemoved
            }
        }

        var backgroundColor: Color {
            switch self {
            case .added: return AppColors.linesAdded.opacity(0.15)
            case .removed: return AppColors.linesRemoved.opacity(0.15)
            }
        }

        var prefix: String {
            switch self {
            case .added: return "+"
            case .removed: return "-"
            }
        }
    }

    var body: some View {
        Text("\(type.prefix)\(formattedValue)")
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(type.textColor)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(type.backgroundColor)
            )
    }
}
