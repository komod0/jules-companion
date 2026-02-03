import SwiftUI

struct ActivityPlanView: View {
    @ObservedObject private var fontSizeManager = FontSizeManager.shared
    let plan: Plan
    @State private var expandedStepIds: Set<String> = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActivityTitleView(title: "Created Plan")
            VStack(spacing: 5) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            // Number Circle
                            Circle()
                                .fill(AppColors.accent)
                                .frame(width: 4, height: 4)
                            
                            // Title
                            MarkdownTextView(step.title ?? "Untitled Step", textColor: AppColors.textPrimary, fontSize: fontSizeManager.activityFontSize)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            
                            Spacer()
                            
                            // Chevron
                            Image(systemName: expandedStepIds.contains(step.id) ? "chevron.up" : "chevron.down")
                                .foregroundColor(AppColors.separator)
                                .font(.system(size: fontSizeManager.activityFontSize - 1))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle()) // Make full row tappable
                        .onTapGesture {
                            withAnimation {
                                if expandedStepIds.contains(step.id) {
                                    expandedStepIds.remove(step.id)
                                } else {
                                    expandedStepIds.insert(step.id)
                                }
                            }
                        }
                        
                        // Expanded Description
                        if expandedStepIds.contains(step.id), let description = step.description {
                            MarkdownTextView(description, textColor: AppColors.textSecondary, fontSize: fontSizeManager.activityFontSize - 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .transition(.opacity)
                        }
                        
                    }
                }
                
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AppColors.backgroundSecondary, lineWidth: 1)
            )
        }
    }
}
