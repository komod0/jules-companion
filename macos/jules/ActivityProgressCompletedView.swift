import SwiftUI

struct ActivityProgressCompletedView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared
    let title: String
    let description: String
    let generatedDescription: String?
    let generatedTitle: String?

    /// Returns the description to display, preferring generatedDescription over the original description
    private var displayDescription: String? {
        if let generated = generatedDescription, !generated.isEmpty {
            return generated
        }
        if !description.isEmpty {
            return description
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActivityTitleView(title: title, generatedTitle: generatedTitle)
            if let descriptionText = displayDescription {
                MarkdownTextView(descriptionText, textColor: AppColors.textPrimary, fontSize: fontSizeManager.activityFontSize)
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
