import SwiftUI

// NB: Assumes AppColors is defined

struct AttachmentIndicatorView: View {
    // Action to remove the attachment and clear prompt text
    let onRemove: () -> Void
    let lineCount: Int

    @State private var isHoveringRemove = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.fill") // Generic attachment icon
                .foregroundColor(AppColors.textSecondary)

            Text("\(lineCount) lines attached") // Clear visual indicator
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary)

            Spacer() // Push remove button right

            // Remove Button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(isHoveringRemove ? AppColors.destructive.opacity(0.8) : AppColors.textSecondary.opacity(0.7))
                    .onHover { hovering in isHoveringRemove = hovering }
            }
            .buttonStyle(.plain)
            .help("Remove attached content")
            .animation(.easeIn(duration: 0.1), value: isHoveringRemove) // Animate remove button hover
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .inputOverlayStyle(cornerRadius: 8, useMaterial: false)
        .frame(maxWidth: .infinity, alignment: .leading) // Take available width
    }
}

// Preview Provider
struct AttachmentIndicatorView_Previews: PreviewProvider {
    static var previews: some View {
        AttachmentIndicatorView(onRemove: {}, lineCount: 120)
            .padding()
            .background(AppColors.background)
    }
}
