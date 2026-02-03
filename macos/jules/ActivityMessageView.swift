import SwiftUI

struct ActivityMessageView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared
    let message: String
    let originator: String // "user" or "agent"

    @State private var isExpanded = false

    private var alignment: HorizontalAlignment {
        originator == "user" ? .trailing : .leading
    }

    private var bubbleAlignment: Alignment {
        originator == "user" ? .trailing : .leading
    }

    private var bubbleColor: Color {
        originator == "user" ? AppColors.accent : AppColors.backgroundSecondary
    }

    private var textColor: Color {
        originator == "user" ? .white : AppColors.textPrimary
    }

    // A simple heuristic for truncation.
    private var isTruncatable: Bool {
        // 5 lines * 45 chars/line = 225
        message.count > 225 || message.filter { $0.isNewline }.count >= 5
    }

    var body: some View {
        HStack {
            if originator == "user" { Spacer(minLength: 50) }

            VStack(alignment: alignment, spacing: 4) {
                MarkdownTextView(message, textColor: textColor, fontSize: fontSizeManager.activityFontSize)
                    .padding(12)
                    .background(bubbleColor)
                    .cornerRadius(18)
                    .lineLimit(isExpanded ? nil : 5)

                if isTruncatable && !isExpanded {
                    Button(action: {
                        isExpanded = true
                    }) {
                        Text("Read More")
                            .font(.system(size: fontSizeManager.activityFontSize - 2))
                            .foregroundColor(AppColors.accent)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: bubbleAlignment)

            if originator == "agent" { Spacer(minLength: 50) }
        }
    }
}
