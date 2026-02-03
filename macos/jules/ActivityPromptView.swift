import SwiftUI

/// A view displaying the session prompt at the start of an activity list.
/// Similar to a user message bubble but with a border instead of a filled background.
struct ActivityPromptView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared
    let prompt: String

    @State private var isExpanded = false

    // A simple heuristic for truncation.
    private var isTruncatable: Bool {
        // 5 lines * 45 chars/line = 225
        prompt.count > 225 || prompt.filter { $0.isNewline }.count >= 5
    }

    var body: some View {
        HStack {
            Spacer(minLength: 50)

            VStack(alignment: .trailing, spacing: 4) {
                MarkdownTextView(prompt, textColor: .white, fontSize: fontSizeManager.activityFontSize)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(AppColors.accent)
                    )
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
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
