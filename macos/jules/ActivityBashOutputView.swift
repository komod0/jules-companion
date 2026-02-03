import SwiftUI

struct ActivityBashOutputView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared
    @State private var isExpanded = false
    @State private var isHovered = false
    let bashOutput: BashOutput

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let command = bashOutput.command, !command.isEmpty {
                    Text("$ \(command)")
                        .font(.system(size: fontSizeManager.activityFontSize - 2, weight: .bold, design: .monospaced))
                        .foregroundColor(AppColors.textSecondary)
                }
                if isExpanded, let output = bashOutput.output, !output.isEmpty {
                    Text(output)
                        .font(.system(size: fontSizeManager.activityFontSize - 2, design: .monospaced))
                        .foregroundColor(AppColors.textPrimary)
                }
            }
            .padding(12)
            .background(
                ZStack {
                    AppColors.backgroundSecondary
                    if isHovered {
                        Color.white.opacity(0.05)
                    }
                }
            )
            .cornerRadius(8)
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            Spacer(minLength: 50)
        }
    }
}
