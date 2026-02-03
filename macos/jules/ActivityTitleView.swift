import SwiftUI

/// A reusable title component for activity views with an icon and title text.
/// Supports both static titles and generated titles (with preference for generated).
struct ActivityTitleView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared

    let title: String
    let generatedTitle: String?

    /// Returns the title to display, preferring generatedTitle over the original title
    private var displayTitle: String {
        if let generated = generatedTitle, !generated.isEmpty {
            return generated
        }
        return title
    }

    init(title: String, generatedTitle: String? = nil) {
        self.title = title
        self.generatedTitle = generatedTitle
    }

    var body: some View {
        HStack(spacing: 6) {
            Image("dot-half")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 10, height: 10)
                .foregroundColor(AppColors.textSecondary)

            MarkdownTextView(displayTitle, textColor: AppColors.textSecondary, fontSize: fontSizeManager.activityFontSize - 1)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(4)
        .background(AppColors.backgroundDark)
    }
}
